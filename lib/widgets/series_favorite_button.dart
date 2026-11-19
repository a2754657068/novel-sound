import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../models/media_item.dart';
import '../services/shelf_store.dart';

/// 短剧播放页右栏的收藏按钮（评论按钮上方）。
///
/// 官方播放页把收藏放在剧集详情页里，得先进详情再点一次；这里直接放到播放
/// 页右栏，点一下就把整部剧收进本机书架，状态与书架/详情页共用
/// [ShelfStore]，所以三处永远同步。
class SeriesFavoriteButton extends StatefulWidget {
  const SeriesFavoriteButton({
    super.key,
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.episodeLabel = '',
  });

  final String seriesId;
  final String title;
  final String cover;
  final String episodeLabel;

  @override
  State<SeriesFavoriteButton> createState() => _SeriesFavoriteButtonState();
}

class _SeriesFavoriteButtonState extends State<SeriesFavoriteButton> {
  final ShelfStore _shelf = ShelfStore.instance;
  bool _busy = false;
  bool _favorited = false;
  late final ValueListenable<int> _revision;

  @override
  void initState() {
    super.initState();
    _revision = _shelf.listenable;
    _favorited = _readFavorited();
    _revision.addListener(_syncFromStore);
  }

  @override
  void didUpdateWidget(SeriesFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seriesId != widget.seriesId) {
      _favorited = _readFavorited();
    }
  }

  @override
  void dispose() {
    _revision.removeListener(_syncFromStore);
    super.dispose();
  }

  bool _readFavorited() =>
      widget.seriesId.isNotEmpty && _shelf.contains('video', widget.seriesId);

  void _syncFromStore() {
    if (!mounted) return;
    final next = _readFavorited();
    if (next != _favorited) setState(() => _favorited = next);
  }

  Future<void> _toggle() async {
    if (_busy || widget.seriesId.isEmpty) return;
    if (!_shelf.isReady) {
      _toast('本地收藏暂不可用，请稍后重试');
      return;
    }
    setState(() => _busy = true);
    try {
      final added = await _shelf.toggle(
        MediaItem(
          id: widget.seriesId,
          seriesId: widget.seriesId,
          title: widget.title,
          cover: widget.cover,
          author: '',
          badge: '短剧',
          ep: widget.episodeLabel,
          kind: 'video',
        ),
      );
      if (!mounted) return;
      setState(() => _favorited = added);
      _toast(added ? '已收藏到本机书架' : '已取消收藏');
    } catch (_) {
      if (!mounted) return;
      _toast('收藏失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final icon = _favorited
        ? Icons.star_rounded
        : Icons.star_border_rounded;
    return Semantics(
      button: true,
      label: _favorited ? '取消收藏' : '收藏',
      child: GestureDetector(
        key: const ValueKey('player-favorite-button'),
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 40,
                color: _favorited
                    ? const Color(0xFFFFC53D)
                    : const Color(0xCCFFFFFF),
                shadows: const [
                  Shadow(color: Color(0x66000000), blurRadius: 6),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _favorited ? '已收藏' : '收藏',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.1,
                  fontWeight: FontWeight.bold,
                  color: Color(0xCCFFFFFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
