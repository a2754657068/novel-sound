import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/home_cell.dart';
import '../models/search_discovery.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/app_log.dart';
import '../services/app_style_tokens.dart';
import '../services/app_theme_style.dart';
import '../services/book_open_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/desktop_platform.dart';
import '../services/frame_stats.dart';
import '../services/shell_visibility.dart';
import '../services/home_continue_preferences.dart';
import '../services/home_page_affinity.dart';
import '../services/library_store.dart';
import '../services/reading_preference.dart';
import '../widgets/home/classic_home_feed_states.dart';
import '../widgets/home/classic_home_skeleton.dart';
import '../widgets/home/classic_home_stream_footer.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_archive.dart';
import '../widgets/home/home_cell_blocks.dart';
import '../widgets/home/home_cell_renderers.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_masthead.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_reading_row.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/home/home_skeleton.dart';
import '../widgets/home/home_tab_bar.dart';
import '../widgets/tab_swipe_area.dart';
import 'cached_book_reader.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'home_provider.dart';

/// 书城首页：以书为主的书架。
///
/// 版式（用户 2026-10-26 起的设计方向）：
///
/// ```
/// 搜索行（固定）
/// 分类条（固定，仅下方内容横滑）
/// 继续阅读          ← 只有「推荐」且有阅读史：一行字，无封面无卡面
/// 排行榜            ← 上游 RankCellV3，横滑大封面 + 名次
/// 为你推荐 / 分类名  ← 统一的书籍网格
/// 流尾 / 加载中 / 重试
/// ```
///
/// 「推荐」只画书：上游的卡片流是混排（短剧、漫剧、听书都夹在里面），这里按
/// 当前分类的种类过滤，其余媒介留在各自分类里。上游的其余区块仍然按
/// `show_type` 分发（见 [HomeCellRenderers]），没登记的类型不会让页面变空。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    this.cacheStore,
    this.readerStore,
    this.scrollController,
    this.cueLoader,
    this.shellIndex = 0,
  });

  /// 本页在壳层里的下标，用来判断 [shellVisibleTab] 是否指向自己。
  final int shellIndex;

  /// Classic search suggestions. Null keeps tests and standalone pages offline.
  /// The application shell supplies ApiClient.searchCue.
  final Future<SearchCue> Function()? cueLoader;

  final ChapterCache? cacheStore;
  final ReaderStore? readerStore;

  /// 首页 feed 的滚动控制器，由壳层持有。
  ///
  /// 官方「重复点击底部书城 tab 回顶部」发生在底部栏
  /// （`onBottomTabRepeatClick` → `scrollToPosition(0)`），不在首页内部，
  /// 所以控制器要能被外面拿到。为 null 时首页自建并自行释放，测试与独立
  /// 使用不受影响。
  final ScrollController? scrollController;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final Map<int, ScrollController> _tabScrolls = {};
  final Map<int, HomeState> _tabStates = {};
  ScrollPosition? _externalPosition;
  ScrollController get _scroll => _scrollFor(ref.read(homeProvider).tabIndex);

  ScrollController _scrollFor(int tab) => _tabScrolls.putIfAbsent(tab, () {
    return ScrollController()..addListener(() {
      if (mounted && ref.read(homeProvider).tabIndex == tab) _onScroll();
    });
  });

  // 壳层的「再次点击回顶部」仅代理当前页的 position，不把多个保活页接到同一控制器。
  bool _externalSyncScheduled = false;

  void _scheduleExternalSync() {
    if (_externalSyncScheduled) return;
    _externalSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _externalSyncScheduled = false;
      _syncExternalScroll();
    });
  }

  void _syncExternalScroll() {
    if (!mounted) return;
    final external = widget.scrollController;
    final position = _scroll.hasClients ? _scroll.position : null;
    if (external == null || identical(position, _externalPosition)) return;
    if (_externalPosition != null) external.detach(_externalPosition!);
    _externalPosition = position;
    if (position != null) external.attach(position);
  }

  bool _hadContent = false;
  final Map<int, List<Widget>> _tabBodies = {};

  /// 每个分类的 body 是按哪份状态建出来的。
  ///
  /// 切回一个已经建过的分类时，只要数据实例和分页标志都没变，就复用同一份
  /// sliver 列表：保活页里那份子树的 widget 完全 identical，`updateChild`
  /// 会直接短路，提交那一帧不再重建整页。
  final Map<int, Object> _tabBodyKeys = {};
  final Set<int> _markedBuiltTabs = <int>{};
  int _localRevision = 0;
  Timer? _loadMoreTimer;
  bool _visible = false;

  /// Cached slivers capture geometry/props as well as data. Include the
  /// interpolated radius so AnimatedTheme cannot leave a halfway value cached.
  (AppThemeStyle, bool, double)? _presentationKey;

  /// Item keys whose entrance animation already played. A sliver disposes the
  /// children that leave its cache extent, so without this each scroll back up
  /// the feed replays a fade layer for every card it re-mounts.
  final _entered = <String>{};

  /// The live horizontal swipe progress, handed from the swipe area to the
  /// header so the underline and the selection block follow the finger.
  ///
  /// A notifier rather than a plain field: the header is rebuilt on every
  /// frame of the drag, and rebuilding the whole page for that would throw
  /// away the cached sliver trees the home feed depends on. Only the header
  /// listens.
  final ValueNotifier<double> _tabProgress = ValueNotifier<double>(0);

  /// The fallback grid, reused while it still describes the same feed.
  Widget? _gridSliver;
  List<MediaItem>? _gridItems;
  int? _gridTabIndex;
  double? _gridWidth;
  double? _gridTitleScale;
  double? _gridMetaScale;

  /// The block pipeline's content slivers, given the same reuse contract.
  ///
  /// Without this cache, every state publish during pagination — `isLoadMore`
  /// turning on and back off — rebuilt the whole block list with fresh grid
  /// slivers and child delegates, and `SliverChildBuilderDelegate
  /// .shouldRebuild` is always true, so every mounted card rebuilt twice per
  /// page load. `cellsForView()` mints a new list whenever a page appends, so
  /// the identity check below is also exactly the invalidation signal.
  List<Widget>? _blocksBody;

  /// 随机推荐段的洗牌种子：同一批数据保持固定顺序，避免重建时跳动。
  final int _bookRandomSeed = DateTime.now().microsecondsSinceEpoch;
  List<HomeCell>? _blocksCells;
  int? _blocksTabIndex;
  String? _blocksLeadKey;
  double? _blocksWidth;
  double? _blocksTitleScale;
  double? _blocksMetaScale;
  int? _blocksFeedRevision;

  /// Last logged render shape; keeps the diagnostic to one line per change.
  String? _loggedShape;

  /// 阅读史存在 Hive 里，不经过 provider；「继续阅读」那一行要跟着阅读
  /// 进度换书，所以页面自己订阅盒子的变更。
  Listenable? _historyListenable;

  /// 首页小说推荐流：完结 10 / 连载 10 / 更多（分页采样）。
  final List<MediaItem> _feedFinished = [];
  final List<MediaItem> _feedSerial = [];
  final List<MediaItem> _feedMore = [];
  final Set<String> _feedIds = {};
  bool _feedLoading = false;
  bool _feedLoaded = false;
  bool _feedMoreLoading = false;
  bool _feedHasMore = true;
  String? _feedError;
  int _feedPage = 0;
  /// 每次冷启动换一个种子；下拉刷新也会换。同一会话内保持稳定，
  /// 「加载更多」才不会把刚看过的书又推一遍。
  int _feedSeedBase = 0;
  /// 推荐数据版本号：进 `_blockBodySlivers` 的缓存键，否则追加的数据画不出来。
  int _feedRevision = 0;

  @override
  void initState() {
    super.initState();
    _feedSeedBase = Random().nextInt(1 << 22);
    // 和首页数据并行拉：别等首屏画完再要推荐，否则第一眼只能是兜底网格。
    unawaited(_ensureBookFeed());
    final store = LibraryStore.instance;
    if (store.isInitialized) {
      _historyListenable = store.historyListenable
        ..addListener(_onLocalDataChanged);
    }
    // 关闭「继续阅读」是个持久化开关，加载完成后要重画这一行。
    HomeContinuePreferences.instance.dismissedId.addListener(
      _onLocalDataChanged,
    );
    unawaited(HomeContinuePreferences.instance.load());
    shellVisibleTab.addListener(_onShellVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeProvider.notifier).load();
    });
  }

  void _onLocalDataChanged() {
    if (!mounted) return;
    // 阅读史/开关变了：继续阅读那一行要跟着换，「复用旧 body」的判据也失效。
    _localRevision++;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tokens = AppStyleTokens.of(context);
    final presentationKey = (
      tokens.style,
      tokens.showDecorativeCodes,
      tokens.coverRadius,
    );
    if (_presentationKey != presentationKey) {
      _presentationKey = presentationKey;
      _gridSliver = null;
      _blocksBody = null;
      _tabBodies.clear();
      _tabBodyKeys.clear();
    }
    final visible =
        shellVisibleTab.value == null ||
        shellVisibleTab.value == widget.shellIndex;
    if (_visible == visible) return;
    _visible = visible;
    // Muting tickers does not stop this page's pagination timer.
    // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
    if (!_visible) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer = null;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  /// 壳层切走/切回：只处理定时器与续页，不做任何 `setState`。
  ///
  /// 旧写法读 `TickerMode` 这个 InheritedWidget，可见性一变整页就要重建一次
  /// （真机每次切底部 tab 都跟着一帧 50–280ms 的 UI 耗时）。
  void _onShellVisibility() {
    if (!mounted) return;
    final visible =
        shellVisibleTab.value == null ||
        shellVisibleTab.value == widget.shellIndex;
    if (_visible == visible) return;
    _visible = visible;
    if (!_visible) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer = null;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onScroll();
      });
    }
  }

  @override
  void dispose() {
    _loadMoreTimer?.cancel();
    shellVisibleTab.removeListener(_onShellVisibility);
    _historyListenable?.removeListener(_onLocalDataChanged);
    HomeContinuePreferences.instance.dismissedId.removeListener(
      _onLocalDataChanged,
    );
    if (_externalPosition != null) {
      widget.scrollController?.detach(_externalPosition!);
    }
    for (final controller in _tabScrolls.values) {
      controller.dispose();
    }
    _tabProgress.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_visible) return;
    if (!_scroll.hasClients) {
      final state = ref.read(homeProvider);
      if (state.error == null && _visibleItems(state).isEmpty) _maybeLoadMore();
      return;
    }
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 600) _maybeLoadMore();
  }

  /// Short and empty pages must continue even without a user scroll event.
  void _maybeLoadMore() {
    if (!mounted || !_visible || _loadMoreTimer != null) return;
    final state = ref.read(homeProvider);
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    _loadMoreTimer = Timer(const Duration(milliseconds: 500), () {
      _loadMoreTimer = null;
      if (mounted) _onScroll();
    });
    ref.read(homeProvider.notifier).loadMore();
  }

  void _selectTab(int index) {
    if (index == ref.read(homeProvider).tabIndex) return;
    FrameStats.mark('selectTab $index');
    // 上一个分类的续页轮询不该跟着新分类继续跑。
    _loadMoreTimer?.cancel();
    _loadMoreTimer = null;
    // 每个分类有自己的 ScrollController，不需要在这里回顶。
    ref.read(homeProvider.notifier).selectTab(index);
    _scheduleExternalSync();
  }

  /// 下拉与冷启动错误里的「重试」都走手动刷新：手动刷新会跳过续接快照，
  /// 用服务端的第一页整体替换列表（官方 `SaasClientReqType.Refresh`）。
  Future<void> _refresh() async {
    _resetFeed();
    if (mounted) setState(() {});
    unawaited(_ensureBookFeed());
    await ref.read(homeProvider.notifier).load(manualRefresh: true);
  }

  /// 追加失败后 footer 的重试：`loadMore` 失败会把 `hasMore` 置 false，必须
  /// 让 notifier 先把游标恢复，否则重试会被「已经没有下一页」挡住。
  Future<void> _retryLoadMore() =>
      ref.read(homeProvider.notifier).retryLoadMore();

  /// 当前分类的种类：「推荐」与「全部」都会落到 `book`。
  String _kindOf(HomeState state) =>
      ref.read(homeProvider.notifier).identityOf(state.tabIndex).kind;

  List<MediaItem> _visibleItems(HomeState state) {
    final kind = _kindOf(state);
    return [
      for (final item in state.items)
        if (item.kind == kind) item,
    ];
  }

  /// 当前分类的区块，或空表示这份 `cells` 不属于这里。
  ///
  /// 归属由数据自己声明（[HomeState.cellsTabIndex]），不再靠页面猜：上游曾把
  /// `tab_index` 写死成 0 返回推荐流，于是「听书」里画出了推荐榜。请求侧已经
  /// 修好，这里再兜一道——不属于当前分类的区块一律不画，别把别人的内容
  /// 当成自己这份。
  List<HomeCell> _cellsOfCurrentTab(HomeState state) {
    final cells = state.cells;
    if (cells.isEmpty) return const [];
    final owner = state.cellsTabIndex;
    if (owner == null) return cells;
    return owner == state.tabIndex ? cells : const [];
  }

  /// 顶栏分类：固定用本地六分类（推荐/小说/短剧/漫剧/漫画/听书）。
  ///
  /// 2026-10-24 用户决定回退服务端 11 项方案——服务端表没有「短剧/漫剧」，
  /// 跨媒介入口只能本地给；点击身份由 `homeProvider` 的 `usesLocalTabs`
  /// 本地表驱动，与这里的下标一一对应。
  List<HomeCategory> _categoriesOf(HomeState state) => homeCategories;

  /// 频道下标 → 顶栏位置。找不到（比如从底部短剧入口深链过来）就停在「推荐」。
  int _barIndexFor(int tabIndex) {
    final index = homeCategories.indexWhere(
      (category) => category.index == tabIndex,
    );
    return index < 0 ? 0 : index;
  }

  /// 顶栏位置 → 频道下标。
  int _tabIndexOf(int barIndex) => barIndex >= 0 && barIndex < homeCategories.length
      ? homeCategories[barIndex].index
      : 0;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    _tabStates[state.tabIndex] = state;
    _scheduleExternalSync();
    final palette = HomePalette.of(context);
    final categories = _categoriesOf(state);
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: Align(
        alignment: Alignment.topCenter,
        // 阅读宽度：手机/平板压 840（一屏三到五列，再宽眼睛就散）。
        //
        // 桌面不吃固定 1440：2560 的窗口里只占一半多，两侧各空 560dp。
        // 宽度交给窗口后，列数由 homeShelfColumns 按「一格 190dp，钳 6–9 列」
        // 反推（见 `widgets/home/home_shelf.dart`）：默认六列、全屏九列，
        // 窗口再宽只把卡片放大，不会往格子里塞更多小封面。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth:
                isWindowsDesktop || MediaQuery.sizeOf(context).width >= 840
                ? double.infinity
                : 840,
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (AppStyleTokens.of(context).isClassic)
                  HomeHero(
                    onSearch: _openSearch,
                    onCategory: _openCategory,
                    cueLoader: widget.cueLoader,
                  )
                else
                  HomeMasthead(
                    onSearch: _openSearch,
                    onCategory: _openCategory,
                  ),
                ValueListenableBuilder<double>(
                  valueListenable: _tabProgress,
                  builder: (context, progress, _) => HomeTabBar(
                    selectedIndex: _barIndexFor(state.tabIndex),
                    onSelect: (bar) => _selectTab(_tabIndexOf(bar)),
                    categories: categories,
                    progress: progress,
                  ),
                ),
                Expanded(
                  // Headers stay outside both the horizontal transform and
                  // the vertical viewport, including loading/error states.
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final gridWidth = constraints.maxWidth - homeGutter * 2;
                      // 短页要能自己续上：没有滚动事件时，也让页面在布局后
                      // 检查一次是否已经到底。
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _onScroll();
                      });
                      return ClipRect(
                        child: TabSwipeArea.pages(
                          index: _barIndexFor(state.tabIndex),
                          count: categories.length,
                          onSelect: (bar) => _selectTab(_tabIndexOf(bar)),
                          // The header lives outside the swipe area, so it
                          // cannot see the drag offset; this is how the
                          // underline learns to follow the finger.
                          onProgress: (value) {
                            if (_tabProgress.value != value) {
                              _tabProgress.value = value;
                            }
                          },
                          pageBuilder: (context, target) => _buildTabPage(
                            _tabIndexOf(target),
                            gridWidth,
                            textScale,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 每个分类的 body：数据没变就直接复用上一次那份 sliver 列表。
  ///
  /// 切回一个建过的分类时，`selectTab` 发布的是同一份 `items` / `cells`
  /// 实例；复用同一份 widget 列表后，保活页里的子树拿到的是 identical 的
  /// 配置，Flutter 会跳过重建——提交那一帧不再重排整页。
  List<Widget> _bodyFor(
    int tab,
    HomeState state,
    double gridWidth,
    double textScale,
  ) {
    final key = (
      state.items,
      state.cells,
      state.cellsTabIndex,
      state.tabIndex,
      state.isLoading,
      state.isLoadMore,
      state.hasMore,
      state.error,
      _localRevision,
      // 推荐流是异步后到的：不带版本号的话，首帧建出来的竖向兜底网格会被
      // 一直复用，变成「冷启动竖着排、滑到底才变横滑」。
      _feedRevision,
      gridWidth,
      textScale,
    );
    final cached = _tabBodies[tab];
    if (cached != null && _tabBodyKeys[tab] == key) return cached;
    FrameStats.mark('body build tab=$tab items=${state.items.length}');
    final body = _contentSlivers(state, gridWidth);
    _tabBodies[tab] = body;
    _tabBodyKeys[tab] = key;
    return body;
  }

  Widget _buildTabPage(int target, double gridWidth, double textScale) {
    final palette = HomePalette.of(context);
    final saved = _tabStates[target];
    // 只记每个分类「第一次被建出来」的时刻：和 stall 行对齐就能看出
    // 那一下停顿是不是花在建页上。
    if (_markedBuiltTabs.add(target)) {
      FrameStats.mark('page first build tab=$target');
    }
    final body = saved == null
        ? _tabBodies[target] ??= [SliverToBoxAdapter(child: _skeleton())]
        : _bodyFor(target, saved, gridWidth, textScale);
    return ColoredBox(
      color: palette.canvas,
      child: RefreshIndicator(
        color: HomePalette.accent,
        backgroundColor: palette.surface,
        onRefresh: _refresh,
        child: CustomScrollView(
          key: const Key('home_feed'),
          controller: _scrollFor(target),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: body,
        ),
      ),
    );
  }

  Widget _skeleton() => AppStyleTokens.of(context).isClassic
      ? const ClassicHomeSkeleton()
      : const HomeSkeleton();

  List<Widget> _contentSlivers(HomeState state, double gridWidth) {
    final classic = AppStyleTokens.of(context).isClassic;
    if (state.error != null &&
        state.items.isEmpty &&
        _cellsOfCurrentTab(state).isEmpty) {
      return [
        SliverToBoxAdapter(
          child: classic
              ? ClassicHomeFeedError(
                  headline: '故事还在路上',
                  message: '暂时无法加载推荐，稍后再试一次。',
                  detail: state.error!,
                  onRetry: _refresh,
                )
              : HomeFeedError(
                  headline: '故事还在路上',
                  message: '暂时无法加载推荐，稍后再试一次。',
                  detail: state.error!,
                  onRetry: _refresh,
                ),
        ),
      ];
    }

    final items = _visibleItems(state);
    if (items.isNotEmpty) _hadContent = true;
    final now = _readingNow(state);
    final lead = now?.item;
    final blockBody = _blockBodySlivers(
      state,
      gridWidth,
      kind: _kindOf(state),
      lead: lead,
    );
    _logShape(state, blockBody != null);

    if (blockBody != null) {
      final feedActive = _feedFinished.isNotEmpty || _feedSerial.isNotEmpty;
      return [
        if (now != null) _continueRow(now),
        ...blockBody,
        if (!feedActive) _footer(state),
        _bottomSpacer(context),
      ];
    }
    if (items.isNotEmpty) {
      return [
        if (now != null) _continueRow(now),
        ..._fallbackGrid(state, items, gridWidth, lead: lead),
        _footer(state),
        _bottomSpacer(context),
      ];
    }
    if (state.isLoading || state.hasMore) {
      if (!state.isLoading &&
          state.tabIndex == ref.read(homeProvider).tabIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
      }
      // `alx.xml` points its `SkeletonLayout` at `cmc`, so a cold first load
      // paints the skeleton rather than a spinner.
      if (_hadContent) {
        return [
          SliverToBoxAdapter(
            child: classic
                ? const ClassicHomeFeedLoading()
                : const HomeFeedLoading(),
          ),
        ];
      }
      return [SliverToBoxAdapter(child: _skeleton())];
    }
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: classic
            ? ClassicHomeFeedEmpty(
                title: '暂无内容',
                message: '换个分类，或刷新发现新故事',
                actionLabel: '刷新推荐',
                onRefresh: _refresh,
              )
            : HomeFeedEmpty(
                title: '暂无内容',
                message: '换个分类，或刷新发现新故事',
                actionLabel: '刷新推荐',
                onRefresh: _refresh,
              ),
      ),
    ];
  }

  /// 「继续阅读」显示哪一本：只在推荐页、有阅读史、且这一本没被关掉时出现。
  ReadingNow? _readingNow(HomeState state) {
    if (state.tabIndex != 0) return null;
    final now = latestReadingNow();
    if (now == null) return null;
    return HomeContinuePreferences.instance.isDismissed(now.item) ? null : now;
  }

  Widget _continueRow(ReadingNow now) => SliverToBoxAdapter(
    child: HomeContinueRow(
      now: now,
      onOpen: () => _resumeItem(now.item),
      onDismiss: () => HomeContinuePreferences.instance.dismiss(now.item),
    ),
  );

  void _logShape(HomeState state, bool blocks) {
    // 设备日志：分类页到底画的是区块还是卡片网格、画了多少张。听书出问题时
    // 这一行直接说明它被画成了哪一种版式。
    final shape = blocks
        ? 'blocks tab=${state.tabIndex} '
              'cells=${describeHomeCells(_cellsOfCurrentTab(state))}'
        : 'grid tab=${state.tabIndex} items=${_visibleItems(state).length}';
    if (shape == _loggedShape) return;
    _loggedShape = shape;
    AppLog.d('home', '渲染 $shape');
  }

  /// The block pipeline's content slivers, reused verbatim while they still
  /// describe the same cells, width, text scale and lead book.
  List<Widget>? _blockBodySlivers(
    HomeState state,
    double gridWidth, {
    required String kind,
    required MediaItem? lead,
  }) {
    // 每个书城分类都渲染自己那份 `cell_data`（官方 `m0` 对 `tab_type` 一视
    // 同仁地建区块），所以这里不再只放行「推荐」。没带区块的分类照旧落到
    // 下面的兜底网格，不会被空掉。
    final cells = _cellsOfCurrentTab(state);
    if (cells.isEmpty) return null;
    registerDefaultHomeCells(
      onOpenRankBoard: _openRanks,
      loadBoard: _loadRankPreview,
    );

    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(11);
    final leadKey = lead == null ? null : '${lead.kind}:${lead.id}';
    final cached = _blocksBody;
    if (cached != null &&
        identical(_blocksCells, cells) &&
        _blocksTabIndex == state.tabIndex &&
        _blocksLeadKey == leadKey &&
        _blocksWidth == gridWidth &&
        _blocksTitleScale == titleScale &&
        _blocksMetaScale == metaScale &&
        _blocksFeedRevision == _feedRevision) {
      return cached;
    }
    _blocksCells = cells;
    _blocksTabIndex = state.tabIndex;
    _blocksLeadKey = leadKey;
    _blocksWidth = gridWidth;
    _blocksTitleScale = titleScale;
    _blocksMetaScale = metaScale;
    _blocksFeedRevision = _feedRevision;

    final slivers = <Widget>[];
    final entries = <MediaItem>[];
    final seen = <String>{};
    var rendered = false;
    for (final cell in cells) {
      // 只有真拿到 widget 才算处理过。handles() 为真但 build() 返回 null 时
      // 要落到 card 分支，否则这个块会被静默跳过。
      final custom = HomeCellRenderers.handles(cell.showType)
          ? HomeCellRenderers.build(context, cell, onOpen: _openItem)
          : null;
      if (custom != null) {
        slivers.add(SliverToBoxAdapter(child: custom));
        rendered = true;
        continue;
      }
      if (!isHomeGridBlock(cell)) continue;
      for (final item in homeCellEntries(cell)) {
        // 以书为主：推荐页的卡片流里混着短剧、漫画和听书，这里只留当前
        // 分类的书；其余媒介在自己的分类里出现。
        if (item.kind != kind) continue;
        final key = '${item.kind}:${item.id}';
        // 主视觉已经在上面独占一张卡，网格里不再重复。
        if (key == leadKey || !seen.add(key)) continue;
        entries.add(item);
      }
    }
    if (entries.isNotEmpty) {
      // 多个卡片流合并成一个网格：首页只保留一个「为你推荐」段落，块与块
      // 之间的边界对读书的人没有意义。
      //
      // 只有网格前面还有别的块时才加分区头：短剧/漫剧/漫画/听书这些分类
      // 没有排行榜，网格就是第一段，再顶着分类名（「短剧」）当标题，等于把
      // 顶栏已经选中的标签又念了一遍。推荐页（tab 0）保留「为你推荐」。
      if (kind == 'book') {
        // 小说改成三段：完结推荐 / 连载推荐 / 随机推荐（前面的排行榜原样保留）。
        slivers.addAll(_bookSectionSlivers(entries, gridWidth, slivers.isEmpty));
      } else {
        if (slivers.isNotEmpty || state.tabIndex == 0) {
          slivers.add(SliverToBoxAdapter(child: _gridHeader(state)));
        } else {
          // 没有分区头时网格直接顶在标签条下面：选中背景块的底边会和第一行
          // 封面贴在一起。用一段留白替掉被去掉的分区头位置（与短剧页同一档）。
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
        }
        slivers.add(_gridBody(entries, gridWidth));
      }
      rendered = true;
    }
    if (!rendered) {
      // 这份 `cells` 一个块都没画出来（听书的 337、老后端的未知类型…）：
      // **必须把缓存清掉**。`_blocksCells` 已经在上面改成了这份列表，
      // 若把 `_blocksBody`（上上个分类建的那套 widget）留着，下一次带着
      // **同一份列表实例**的重建就会命中缓存、把上一个分类的排行榜画到
      // 当前分类上——真机上「听书第二次加载变成推荐」就是这么来的。
      _blocksBody = null;
      _blocksCells = null;
      _blocksTabIndex = null;
      _blocksLeadKey = null;
      _blocksWidth = null;
      _blocksTitleScale = null;
      _blocksMetaScale = null;
      return null;
    }
    return _blocksBody = slivers;
  }

  /// 兜底：上游没给区块时，把当前分类的条目排成同一个书架网格。
  List<Widget> _fallbackGrid(
    HomeState state,
    List<MediaItem> items,
    double gridWidth, {
    required MediaItem? lead,
  }) {
    final leadKey = lead == null ? null : '${lead.kind}:${lead.id}';
    final entries = [
      for (final item in items)
        if ('${item.kind}:${item.id}' != leadKey) item,
    ];
    if (entries.isEmpty) return const [];
    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(11);
    // 兜底网格只有在「前面还有继续阅读那一行」或者是推荐页时才带分区头；
    // 其余分类的网格就在标签条下面，标题会重复已选中的分类名。
    final withHeader = lead != null || state.tabIndex == 0;
    var sliver = _gridSliver;
    if (sliver == null ||
        !identical(_gridItems, state.items) ||
        _gridTabIndex != state.tabIndex ||
        _gridWidth != gridWidth ||
        _gridTitleScale != titleScale ||
        _gridMetaScale != metaScale) {
      _gridItems = state.items;
      _gridTabIndex = state.tabIndex;
      _gridWidth = gridWidth;
      _gridTitleScale = titleScale;
      _gridMetaScale = metaScale;
      sliver = _gridSliver = _gridBody(entries, gridWidth);
    }
    return [
      if (withHeader)
        SliverToBoxAdapter(child: _gridHeader(state))
      else
        // 无分区头时留一段空白，别让选中标签的背景块贴着第一行封面。
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      sliver,
    ];
  }

  int get _feedSeed => _feedSeedBase;

  void _resetFeed() {
    _feedFinished.clear();
    _feedSerial.clear();
    _feedMore.clear();
    _feedIds.clear();
    _feedPage = 0;
    _feedHasMore = true;
    _feedLoaded = false;
    _feedMoreLoading = false;
    _feedError = null;
    _feedSeedBase = Random().nextInt(1 << 22);
    _feedRevision++;
  }

  Future<List<MediaItem>> _fetchFeed(
    String status,
    int seed,
    int page, {
    bool usePreference = false,
  }) async {
    // 只有「更多推荐」吃阅读偏好；完结/连载两栏保持中性，否则首页会越用越窄。
    final prefer = usePreference
        ? ReadingPreference.encode(ReadingPreference.topTags())
        : '';
    final payload = await ApiClient.instance.bookFeed(
      status: status,
      limit: 10,
      exclude: _feedIds.join(','),
      seed: seed,
      page: page,
      prefer: prefer,
    );
    final raw = payload['items'];
    final items = <MediaItem>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        try {
          items.add(MediaItem.fromRaw(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
    }
    return items;
  }

  /// 三块推荐都从服务端采样来：完结 10 本、连载 10 本，然后「更多推荐」。
  /// 三块共用一个 `_feedIds` 做跨栏去重。
  Future<void> _ensureBookFeed() async {
    if (_feedLoaded || _feedLoading) return;
    _feedLoading = true;
    if (mounted) setState(() => _feedError = null);
    try {
      final seed = _feedSeed;
      // 完结和连载互不相干，并发取，省一轮往返（首次约 2s，之后命中分类缓存更快）。
      final both = await Future.wait([
        _fetchFeed('finished', seed, 0),
        _fetchFeed('serial', seed + 1, 0),
      ]);
      final finished = both[0];
      for (final item in finished) {
        _feedIds.add(item.id);
      }
      _feedFinished
        ..clear()
        ..addAll(finished);

      var serial = both[1].where((item) => !_feedIds.contains(item.id)).toList();
      for (final item in serial) {
        _feedIds.add(item.id);
      }
      // 并发取的时候没带对方的 exclude，撞车了补一次。
      if (serial.length < 8) {
        final refill = await _fetchFeed('serial', seed + 1, 1);
        for (final item in refill) {
          if (_feedIds.add(item.id)) serial.add(item);
        }
      }
      _feedSerial
        ..clear()
        ..addAll(serial.take(10));

      final more = await _fetchFeed('any', seed + 2, 0, usePreference: true);
      for (final item in more) {
        _feedIds.add(item.id);
      }
      _feedMore
        ..clear()
        ..addAll(more);
      _feedHasMore = more.isNotEmpty;
      _feedLoaded = true;
      _feedRevision++;
    } catch (error) {
      _feedError = error is ApiException ? error.message : '推荐加载失败';
    } finally {
      _feedLoading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadMoreFeed() async {
    if (_feedMoreLoading || !_feedHasMore) return;
    _feedMoreLoading = true;
    if (mounted) setState(() {});
    try {
      _feedPage++;
      final more = await _fetchFeed(
        'any',
        _feedSeed + 2,
        _feedPage,
        usePreference: true,
      );
      for (final item in more) {
        _feedIds.add(item.id);
      }
      _feedMore.addAll(more);
      if (more.isEmpty) _feedHasMore = false;
      _feedRevision++;
    } catch (_) {
      _feedPage--;
    } finally {
      _feedMoreLoading = false;
      if (mounted) setState(() {});
    }
  }

  /// 横滑行：完结 / 连载各 10 本，排版与排行榜一致。
  Widget _feedRail(List<MediaItem> items) {
    final classic = AppStyleTokens.of(context).isClassic;
    final tokens = AppStyleTokens.of(context);
    const cardWidth = 104.0;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 218,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final item = items[index];
            return SizedBox(
              width: cardWidth,
              child: HomeMediaCard(
                item: item,
                coverWidth: cardWidth,
                radius: classic ? 12.0 : tokens.coverRadius,
                titleSize: classic ? 15 : homeCardTitleSize,
                archiveCode: classic ? null : homeFileCode(item),
                onTap: () => _openItem(item),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 横滑骨架：尺寸和真实封面卡对齐，数据到了原地替换，不会跳版。
  Widget _feedRailSkeleton() {
    final tokens = AppStyleTokens.of(context);
    final base = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 218,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          itemCount: 4,
          separatorBuilder: (context, index) => const SizedBox(width: 12),
          itemBuilder: (context, index) => SizedBox(
            width: 104,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: base,
                      borderRadius: BorderRadius.circular(
                        tokens.isClassic ? 12 : tokens.coverRadius,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(height: 12, width: 84, color: base),
                const SizedBox(height: 6),
                Container(height: 10, width: 60, color: base),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 小说三段推荐：完结 / 连载 / 随机。排行榜等自定义块由调用方先塞进 slivers。
  List<Widget> _bookSectionSlivers(
    List<MediaItem> entries,
    double gridWidth,
    bool isFirstBlock,
  ) {
    if (!_feedLoaded && !_feedLoading) {
      unawaited(_ensureBookFeed());
    }
    final finished = <MediaItem>[];
    final serial = <MediaItem>[];
    final others = <MediaItem>[];
    for (final item in entries) {
      switch (item.creationStatus) {
        case 0:
          finished.add(item);
        case 1:
          serial.add(item);
        default:
          others.add(item);
      }
    }
    if (others.length > 1) {
      final random = Random(_bookRandomSeed);
      for (var i = others.length - 1; i > 0; i--) {
        final j = random.nextInt(i + 1);
        final tmp = others[i];
        others[i] = others[j];
        others[j] = tmp;
      }
    }

    final slivers = <Widget>[];
    void addSection(String code, String title, List<MediaItem> items) {
      if (items.isEmpty) return;
      slivers.add(SliverToBoxAdapter(child: _sectionHeader(code, title)));
      slivers.add(_gridBody(items, gridWidth));
    }

    // 服务端推荐流可用时优先生效：完结/连载各 10 本横滑，后面接「更多推荐」。
    if (_feedFinished.isNotEmpty || _feedSerial.isNotEmpty) {
      if (_feedFinished.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: _sectionHeader('01 / FOR YOU', '完结推荐'),
          ),
        );
        slivers.add(_feedRail(_feedFinished));
      }
      if (_feedSerial.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: _sectionHeader('02 / FOR YOU', '连载推荐'),
          ),
        );
        slivers.add(_feedRail(_feedSerial));
      }
      if (_feedMore.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: _sectionHeader('03 / FOR YOU', '更多推荐'),
          ),
        );
        slivers.add(_gridBody(_feedMore, gridWidth));
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 20),
              child: Center(
                child: _feedHasMore
                    ? TextButton(
                        key: const ValueKey('home-feed-more'),
                        onPressed: _feedMoreLoading ? null : _loadMoreFeed,
                        child: Text(
                          _feedMoreLoading ? '正在加载…' : '加载更多推荐',
                        ),
                      )
                    : Text(
                        '没有更多了',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
            ),
          ),
        );
      }
      return slivers;
    }

    // 推荐还没到：画骨架，不画竖向兜底网格。冷启动第一眼必须是横向。
    if (!_feedLoaded && _feedError == null) {
      slivers.add(
        SliverToBoxAdapter(child: _sectionHeader('01 / FOR YOU', '完结推荐')),
      );
      slivers.add(_feedRailSkeleton());
      slivers.add(
        SliverToBoxAdapter(child: _sectionHeader('02 / FOR YOU', '连载推荐')),
      );
      slivers.add(_feedRailSkeleton());
      return slivers;
    }

    if (_feedError != null && _feedFinished.isEmpty && _feedSerial.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(homeGutter, 0, homeGutter, 8),
            child: Text(_feedError!, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      );
    }

    if (finished.isEmpty && serial.isEmpty) {
      // 上游没给完结状态时退回单一网格，别让首页整段空掉。
      slivers.add(
        SliverToBoxAdapter(
          child: isFirstBlock
              ? _sectionHeader('01 / FOR YOU', '为你推荐')
              : _sectionHeader('01 / FOR YOU', '随机推荐'),
        ),
      );
      slivers.add(_gridBody(others.isEmpty ? entries : others, gridWidth));
      return slivers;
    }
    addSection('01 / FOR YOU', '完结推荐', finished);
    addSection('02 / FOR YOU', '连载推荐', serial);
    addSection('03 / FOR YOU', '随机推荐', others);
    if (slivers.isEmpty) {
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    }
    return slivers;
  }

  Widget _sectionHeader(String code, String title) =>
      AppStyleTokens.of(context).isClassic
      ? HomeSectionHeader(title: title)
      : HomeSectionLabel(code: code, title: title);

  Widget _gridHeader(HomeState state) => AppStyleTokens.of(context).isClassic
      ? HomeSectionHeader(title: _gridTitle(state))
      : HomeSectionLabel(code: _gridCode(state), title: _gridTitle(state));

  /// 分区编号：排行榜占了 01，网格就是 02；没有排行榜时网格自己从 01 起。
  String _gridCode(HomeState state) {
    final hasRank = _cellsOfCurrentTab(
      state,
    ).any((cell) => cell.showType == kHomeCellRank);
    return hasRank ? '02 / FOR YOU' : '01 / FOR YOU';
  }

  /// One book grid: cover, title, one meta line, nothing else.
  Widget _gridBody(List<MediaItem> entries, double gridWidth) {
    final cardWidth = homeShelfCardWidth(context, gridWidth);
    final tokens = AppStyleTokens.of(context);
    final classic = tokens.isClassic;
    final radius = classic ? 12.0 : tokens.coverRadius;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      sliver: SliverGrid(
        gridDelegate: homeShelfDelegate(context, gridWidth),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = entries[index];
          final key = '${item.kind}:${item.id}';
          return HomeEntrance(
            key: ValueKey(key),
            index: index,
            // Only the first appearance of an item animates; see HomeEntrance.
            animate: _entered.add(key),
            child: HomeMediaCard(
              item: item,
              coverWidth: cardWidth,
              radius: radius,
              titleSize: classic ? 15 : homeCardTitleSize,
              archiveCode: classic ? null : homeFileCode(item),
              onTap: () => _openItem(item),
            ),
          );
        }, childCount: entries.length),
      ),
    );
  }

  String _gridTitle(HomeState state) {
    if (state.tabIndex == 0) return '为你推荐';
    return ref.read(homeProvider.notifier).identityOf(state.tabIndex).name;
  }

  /// 流尾三态：加载中 / 追加失败可重试 / 已到底。
  Widget _footer(HomeState state) {
    if (AppStyleTokens.of(context).isClassic) {
      if (state.isLoadMore) {
        return const SliverToBoxAdapter(
          child: ClassicHomeStreamFooter.loading(),
        );
      }
      if (state.error != null) {
        return SliverToBoxAdapter(
          child: ClassicHomeStreamFooter.retry(onRetry: _retryLoadMore),
        );
      }
      if (!state.hasMore) {
        return const SliverToBoxAdapter(child: ClassicHomeStreamFooter.done());
      }
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    if (state.isLoadMore) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.loading(onRetry: _retryLoadMore),
      );
    }
    if (state.error != null) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.retry(onRetry: _retryLoadMore),
      );
    }
    if (!state.hasMore) {
      return const SliverToBoxAdapter(child: HomeStreamFooter.done());
    }
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }

  SliverToBoxAdapter _bottomSpacer(BuildContext context) =>
      SliverToBoxAdapter(child: SizedBox(height: homeBottomClearance(context)));

  void _openSearch() {
    Navigator.push(
      context,
      SearchRoute.open<void>(context, builder: (_) => const SearchPage()),
    );
  }

  /// 官方搜索行右上角的「分类」入口（`alx.xml` `i_y`）。官方点它走
  /// `turnToCategoryTab` → `//category` 路由（`BookCategoryActivity` →
  /// `KmpCategoryFragment`）；这里打开同结构的分类页。
  void _openCategory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CategoryPage()),
    );
  }

  /// The rank board. Its catalogue (and the rank id the entries endpoint needs)
  /// only exist inside the novel homepage response the app already fetches.
  ///
  /// Note: 榜单目录与 rank_id 的来源 — 见
  /// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
  void _openRanks() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RankPage()),
    );
  }

  /// Reloads the homepage rank preview for one board.
  ///
  /// Official flow: `RankMixContentHolder.K7` fetches the picked board through
  /// the same rank endpoint and swaps the preview in place, so the page stays
  /// put. Only the first page is needed — the rail scrolls the rest.
  Future<List<MediaItem>> _loadRankPreview(String rankId, int algo) async {
    final board = await ApiClient.instance.rankBoard(
      rankId: rankId,
      algo: algo,
    );
    return [
      for (final entry in board.entries)
        if (entry.id.isNotEmpty) entry.toMediaItem(),
    ];
  }

  void _openItem(MediaItem item) {
    openBookDetail(context, item);
  }

  Future<void> _resumeItem(MediaItem item) async {
    if (await openRecentBook(
      context,
      item,
      cache: widget.cacheStore,
      readerStore: widget.readerStore,
    )) {
      return;
    }
    if (!mounted) return;
    await openBookDetail(context, item, entry: BookOpenEntry.shelf);
  }
}
