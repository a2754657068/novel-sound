import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../pages/audio_page.dart';
import 'api_client.dart';
import 'app_log.dart';
import 'app_navigation.dart';

/// 通知栏 / 系统媒体卡片点击后回到正在播放的那一章。
///
/// 安卓侧的 [ListenKeepAliveService] 把当前书名与章节 id 写进启动 Intent，
/// `MainActivity` 收到后经 `fqapp/listen_open` 转到这里：先查目录，再按
/// `chapterId` 定位起始集，然后用根 Navigator 打开听书页。冷启动时 Dart 还没
/// 挂上监听，原生会把那次意图暂存起来，等 [install] 之后用 `consumePending`
/// 取回，因此从杀进程状态点通知同样能落到正确的章节。
class ListenOpenChannel {
  ListenOpenChannel._();

  static const MethodChannel _channel = MethodChannel('fqapp/listen_open');

  static bool _installed = false;
  static bool _opening = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'open') return null;
      final args = call.arguments;
      if (args is Map) _handle(args);
      return null;
    });
    // 冷启动：原生已经把意图存下了，这里主动取一次。
    unawaited(_consumePending());
  }

  static Future<void> _consumePending() async {
    try {
      final pending = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'consumePending',
      );
      if (pending != null) _handle(pending);
    } on PlatformException catch (error) {
      AppLog.w('listen-open', '读取待处理的通知意图失败: ${error.message ?? error.code}');
    } on MissingPluginException {
      // 非安卓平台没有这个通道。
    }
  }

  static void _handle(Map<dynamic, dynamic> args) {
    final bookId = args['bookId']?.toString() ?? '';
    if (bookId.isEmpty) return;
    unawaited(
      _open(
        bookId: bookId,
        chapterId: args['chapterId']?.toString() ?? '',
        title: args['title']?.toString() ?? '',
        cover: args['cover']?.toString() ?? '',
      ),
    );
  }

  static Future<void> _open({
    required String bookId,
    required String chapterId,
    required String title,
    required String cover,
  }) async {
    final navigator = AppNavigation.navigator;
    if (navigator == null || _opening) return;
    _opening = true;
    try {
      final volumes = await ApiClient.instance.directoryChapters(
        bookId,
        tab: '听书',
      );
      final chapters = [for (final volume in volumes) ...volume];
      if (chapters.isEmpty) return;
      var startIndex = 0;
      if (chapterId.isNotEmpty) {
        final index = chapters.indexWhere(
          (chapter) => chapter.itemId == chapterId,
        );
        if (index >= 0) startIndex = index;
      }
      if (!navigator.mounted) return;
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AudioPage(
              bookId: bookId,
              title: title,
              cover: cover,
              chapters: chapters,
              startIndex: startIndex,
              // 通知点击进来是「接着听」，不用再问用户要从哪一集开始。
              autoplay: true,
            ),
          ),
        ),
      );
    } on FormatException catch (error) {
      AppLog.w('listen-open', '听书目录不可用: ${error.message}');
    } catch (error) {
      AppLog.w('listen-open', '打开听书页失败: $error');
    } finally {
      _opening = false;
    }
  }
}
