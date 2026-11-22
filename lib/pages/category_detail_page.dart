import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/search_filters.dart';
import '../widgets/search/search_media_tile.dart';
import 'detail_page.dart';

/// 分类二级页：从分类页点一颗标签进来，看这个标签下的书。
///
/// 数据源是官方分类落地页 `/reading/bookapi/new_category/landing/v`：它忽略
/// offset/limit（每次只回 10 条），但每次回的是该分类池子里的**轮换样本**，
/// 而 `sub_category_id` / `sort_by` / `book_status` / `word_number` 是真生效的。
/// 所以「加载更多」＝轮换「子分类 × 排序」反复采样，再按 book_id 去重累积；
/// 已经加载出来的条目全程保留在上面。
class CategoryDetailPage extends StatefulWidget {
  const CategoryDetailPage({
    super.key,
    required this.categoryId,
    required this.name,
    this.gender = 1,
  });

  final String categoryId;
  final String name;

  /// 1 = 男频套路，0 = 女频（官方 `categoy_tab_dic`）。
  final int gender;

  @override
  State<CategoryDetailPage> createState() => _CategoryDetailPageState();
}

class _CategoryDetailPageState extends State<CategoryDetailPage> {
  static const int _pageTarget = 18;

  final ApiClient _api = ApiClient.instance;
  final ScrollController _scroll = ScrollController();

  SearchFilters _filters = const SearchFilters();

  /// 0 = 小说，1 = 短剧/漫剧。搜索会把三种媒介混在一起返回，分类浏览必须
  /// 自己分开，否则「玄幻脑洞」底下会冒出短剧卡片。
  /// 已抓到的全部候选（只按媒介档过滤）。分类/状态/字数筛选一律在本地做，
  /// 这样点子分类、切完结状态都是瞬时的，不用再打一轮网络。
  final List<MediaItem> _items = [];

  List<MediaItem> get _visibleItems => [
    for (final item in _items)
      if (_matches(item)) item,
  ];
  final Set<String> _seen = {};
  final List<String> _tags = [];
  /// 子分类与排序的可选值，来自接口返回的 `options`。
  List<String> _subs = const ['0'];
  List<String> _sorts = const ['0', '24', '76', '12'];
  int _subIndex = 0;
  int _sortIndex = 0;

  /// 所有「子分类 × 排序」组合都轮完一遍算一轮；轮完两轮基本就挖干了。
  int _round = 0;

  /// 短剧/漫剧没有分类落地页，退回搜索取候选（按 kind 过滤）。
  bool _hasMore = true;
  bool _loading = false;
  bool _loadedOnce = false;
  int _emptyBatches = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 480) {
      unawaited(_load());
    }
  }

  /// 完结状态 → 官方 `book_status`（2 全部 / 0 完结 / 1 连载 / 3 今日更新）。
  String get _statusParam => switch (_filters.status) {
    0 => '0',
    1 => '1',
    4 => '3',
    _ => '2',
  };

  /// 字数档位 → 官方 `word_number`（0 全部 / 1 100万以下 / 2 100-300万 / 3 300万以上）。
  String get _wordsParam => switch (_filters.wordCount) {
    1 || 2 => '1',
    3 => '2',
    4 => '3',
    _ => '0',
  };

  bool _mediaKindMatches(MediaItem item) => item.kind == 'book';

  bool _matches(MediaItem item) {
    if (!_mediaKindMatches(item)) return false;
    if (!_filters.matches(item)) return false;
    final tag = _filters.tag;
    if (tag == null || tag.isEmpty) return true;
    if (item.categories.any((value) => value == tag)) return true;
    return item.title.contains(tag);
  }

  void _advanceCursor() {
    _sortIndex++;
    if (_sortIndex < _sorts.length) return;
    _sortIndex = 0;
    _subIndex++;
    if (_subIndex < _subs.length) return;
    _subIndex = 0;
    _round++;
  }

  void _resetCursor() {
    _subIndex = 0;
    _sortIndex = 0;
    _round = 0;
  }

  /// 同一组筛选条件的上一份结果：切筛选切回来时先把它画出来，不用再等网络。
  static final Map<String, List<MediaItem>> _sessionCache = {};

  String get _cacheKey =>
      '${widget.categoryId}|${widget.gender}|$_statusParam|'
      '$_wordsParam|${_filters.tag ?? ''}';

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _seen.clear();
        _tags.clear();
        _resetCursor();
        _hasMore = true;
        _loadedOnce = false;
        _emptyBatches = 0;
        final cached = _sessionCache[_cacheKey];
        if (cached != null && cached.isNotEmpty) {
          _items.addAll(cached);
          for (final item in cached) {
            _seen.add(item.id);
            for (final tag in item.categories) {
              if (tag.isEmpty || _tags.contains(tag)) continue;
              _tags.add(tag);
            }
          }
          if (_tags.length > 14) _tags.removeRange(14, _tags.length);
          _loadedOnce = true;
        }
      }
    });

    final found = <MediaItem>[];
    var attempts = 0;
    var stagnant = 0;
    try {
      // 一轮采样只有 10 本，还要过本地筛选，所以要连着轮换好几个组合。
      // 服务端 `batch` 会并发打 6 个轮换组合并合并去重，一次就能拿到一屏
      // （实测 ~1.7s / 30–42 本），所以这里最多再补 2 轮，不再串行 14 圈。
      const maxRounds = 3;
      while (attempts < maxRounds && found.length < _pageTarget && _hasMore) {
        final payload = await _api.categoryFeed(
          id: widget.categoryId,
          gender: widget.gender,
          sub: _subIndex < _subs.length ? _subs[_subIndex] : '0',
          status: _statusParam,
          words: _wordsParam,
          sort: _sortIndex < _sorts.length ? _sorts[_sortIndex] : '0',
          batch: 6,
        );

        final options = payload['options'];
        if (options is Map) {
          final subs = (options['subCategories'] as List?)
              ?.map((e) => (e is Map ? '${e['value'] ?? '0'}' : '0'))
              .where((v) => v.isNotEmpty)
              .toList();
          final sorts = (options['sortBy'] as List?)
              ?.map((e) => (e is Map ? '${e['value'] ?? '0'}' : '0'))
              .where((v) => v.isNotEmpty)
              .toList();
          if (subs != null && subs.isNotEmpty && subs.length != _subs.length) {
            _subs = subs;
          }
          if (sorts != null && sorts.isNotEmpty) _sorts = sorts;
        }

        final raw = payload['items'];
        final page = <MediaItem>[];
        if (raw is List) {
          for (final entry in raw) {
            if (entry is! Map) continue;
            try {
              page.add(MediaItem.fromRaw(Map<String, dynamic>.from(entry)));
            } catch (_) {
              // 单条解析失败不该拖垮整页。
            }
          }
        }
        attempts++;

        var fresh = 0;
        for (final item in page) {
          if (_seen.contains(item.id)) continue;
          fresh++;
          if (!_mediaKindMatches(item)) continue;
          if (!_seen.add(item.id)) continue;
          found.add(item);
        }
        if (fresh == 0) {
          stagnant++;
        } else {
          stagnant = 0;
        }

        _advanceCursor();
        // 轮完两轮、且连续两次采样全是旧书：这个分类基本挖干了。
        if (_round >= 2 && stagnant >= 2) {
          _hasMore = false;
        }
      }
      if (!mounted) return;
      setState(() {
        _items.addAll(found);
        for (final item in found) {
          for (final tag in item.categories) {
            if (tag.isEmpty || _tags.contains(tag)) continue;
            _tags.add(tag);
          }
        }
        if (_tags.length > 14) _tags.removeRange(14, _tags.length);
        _loadedOnce = true;
        _loading = false;
        if (_items.isNotEmpty) {
          _sessionCache[_cacheKey] = List<MediaItem>.of(_items);
        }
        if (found.isEmpty) {
          _emptyBatches++;
          if (_emptyBatches >= 2) _hasMore = false;
        } else {
          _emptyBatches = 0;
        }
      });
      // 这一批不够一屏、或者用户还停在底部：补一次，否则滚动事件已经用
      // 完了，界面会「明明还有书却不动」。
      if (_hasMore && (found.isEmpty || _nearBottom())) {
        await _load();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '加载失败，请重试';
      });
    }
  }

  void _applyFilters(SearchFilters next) {
    // 纯本地筛选：候选池已经拉到内存里，切标签/状态/字数不该再走网络。
    setState(() => _filters = next);
    if (_visibleItems.length < 8 && _hasMore && !_loading) {
      unawaited(_load());
    }
  }

  /// 换一批：换一组起点重新采样，已加载的内容清掉。
  void _shuffle() {
    unawaited(_load(reset: true));
  }

  bool _nearBottom() {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    return position.pixels >= position.maxScrollExtent - 320;
  }

  Future<void> _openItem(MediaItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DetailPage(item: item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          IconButton(
            tooltip: '换一批',
            onPressed: _loading ? null : _shuffle,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(theme),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => unawaited(_load(reset: true)),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          Expanded(child: _body(theme)),
          if (_loading && _items.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterBar(ThemeData theme) {
    final tags = <String>['全部', ..._tags];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill(
                theme,
                label: _statusLabel(_filters.status),
                onTap: () => _showStatusSheet(theme),
              ),
              _pill(
                theme,
                label: _wordLabel(_filters.wordCount),
                onTap: () => _showWordSheet(theme),
              ),
            ],
          ),
          if (tags.length > 1) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: tags.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final tag = tags[index];
                  final selected =
                      (tag == '全部' && _filters.tag == null) ||
                      tag == _filters.tag;
                  return ChoiceChip(
                    label: Text(tag),
                    selected: selected,
                    onSelected: (_) => _applyFilters(
                      tag == '全部'
                          ? _filters.copyWith(clearTag: true)
                          : _filters.copyWith(tag: tag),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(
    ThemeData theme, {
    required String label,
    required VoidCallback onTap,
  }) => Material(
    color: theme.colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down_rounded, size: 18),
          ],
        ),
      ),
    ),
  );

  String _statusLabel(int status) => switch (status) {
    0 => '已完结',
    1 => '连载中',
    4 => '已停更',
    _ => '状态不限',
  };

  String _wordLabel(int bucket) => switch (bucket) {
    1 => '30 万字以下',
    2 => '30–100 万字',
    3 => '100–300 万字',
    4 => '300 万字以上',
    _ => '字数不限',
  };

  Future<void> _showStatusSheet(ThemeData theme) async {
    final picked = await _showSheet(
      title: '完结状态',
      values: const [-1, 0, 1, 4],
      labelOf: _statusLabel,
      current: _filters.status,
    );
    if (picked == null) return;
    _applyFilters(_filters.copyWith(status: picked));
  }

  Future<void> _showWordSheet(ThemeData theme) async {
    final picked = await _showSheet(
      title: '字数',
      values: const [0, 1, 2, 3, 4],
      labelOf: _wordLabel,
      current: _filters.wordCount,
    );
    if (picked == null) return;
    _applyFilters(_filters.copyWith(wordCount: picked));
  }

  Future<int?> _showSheet({
    required String title,
    required List<int> values,
    required String Function(int value) labelOf,
    required int current,
  }) => showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final value in values)
            ListTile(
              title: Text(labelOf(value)),
              trailing: value == current
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.of(context).pop(value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _body(ThemeData theme) {
    if (!_loadedOnce && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final visible = _visibleItems;
    if (visible.isEmpty) {
      if (_error != null) return const SizedBox.shrink();
      return Center(
        child: Text(
          _loading ? '正在加载…' : '这个分类下暂时没有符合筛选条件的小说',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: visible.length + 1,
      itemBuilder: (context, index) {
        if (index == visible.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                _loading
                    ? '正在加载更多…'
                    : (_hasMore ? '继续下滑加载更多' : '没有更多了'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          );
        }
        final item = visible[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SearchNovelRow(item: item, onTap: () => _openItem(item)),
        );
      },
    );
  }
}
