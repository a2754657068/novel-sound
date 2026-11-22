import 'package:material_ui/material_ui.dart';

import '../../services/app_style_tokens.dart';
import 'classic_home_tab_bar.dart';
import 'home_design.dart';

class HomeCategory {
  final String label;

  /// 这个标签在 `HomeNotifier.tabs` 里的下标。
  ///
  /// 顶栏不再和内部频道表一一对应（「短剧」「漫剧」已从顶栏移除，入口只留
  /// 底部 dock），所以下标必须显式带出来，不能再拿顶栏位置当频道下标用。
  final int index;

  const HomeCategory(this.label, this.index);
}

const homeCategories = [
  HomeCategory('推荐', 0),
  HomeCategory('分类', -1),
  HomeCategory('听书', 5),
];

/// 六个媒介分类固定在顶部；保留名称和下划线，不再重复分区的编号层级。
class HomeTabBar extends StatelessWidget {
  static const double sidePadding = 16;
  static const double tabSpacing = 22;
  static const double selectedSize = 15;
  static const double unselectedSize = 15;

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<HomeCategory> categories;

  /// The live horizontal swipe progress: -1 is the previous tab, 0 the current
  /// one, 1 the next one. See [ClassicHomeTabBar.progress].
  ///
  /// **只有经典主题（[ClassicHomeTabBar]）会消费它**：档案风格的标签条是
  /// 每个标签自己带一条下划线，横滑时不做跟手位移，这里仅透传、不参与布局。
  final double? progress;

  const HomeTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    if (AppStyleTokens.of(context).isClassic) {
      return ClassicHomeTabBar(
        selectedIndex: selectedIndex,
        onSelect: onSelect,
        categories: categories,
        progress: progress,
      );
    }
    final palette = HomePalette.of(context);
    final duration = palette.eink || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.line, width: 1)),
      ),
      // 分类少（现在删到 4 项）时不需要横向滚动，让每个标签平分整行宽度，
      // 占满的那一段本身就是点击区，比挤在左边一坨好点。
      child: categories.length <= 4
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: sidePadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var index = 0; index < categories.length; index++)
                    Expanded(child: _tab(index, duration, palette, fill: true)),
                ],
              ),
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: sidePadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var index = 0; index < categories.length; index++) ...[
                    if (index > 0) const SizedBox(width: tabSpacing),
                    _tab(index, duration, palette),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _tab(
    int index,
    Duration duration,
    HomePalette palette, {
    bool fill = false,
  }) {
    final selected = index == selectedIndex;
    final category = categories[index];
    return Semantics(
      selected: selected,
      child: HomePressable(
        key: ValueKey('home_category_$index'),
        onTap: () => onSelect(index),
        borderRadius: BorderRadius.zero,
        // 平分模式下由外层 Expanded 决定宽度，文字居中、下划线铺满这一格；
        // 滚动模式保持原来的「宽度跟随文字」。
        child: SizedBox(
          width: fill ? double.infinity : null,
          child: Stack(
            alignment: fill ? Alignment.topCenter : AlignmentDirectional.topStart,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    fontSize: selected ? selectedSize : unselectedSize,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? palette.ink : palette.muted,
                  ),
                  child: Text(category.label, maxLines: 1),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 2,
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  color: selected ? palette.mark : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
