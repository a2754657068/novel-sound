import 'dart:async';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'ios_platform.dart';

/// 锁屏 / 控制中心 / 耳机键的播放能力。
///
/// 安卓侧由 `ListenKeepAliveService` 的前台服务 + MediaSession 提供，iOS 没有
/// 等价物，因此由 `ios/Runner/AppDelegate.swift` 里的 `AudioSessionBridge`
/// 直接驱动 `AVAudioSession` / `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`。
///
/// Dart 只在播放状态变化时推一次元数据（[update]），收到的按钮事件原样转给
/// 播放控制器的 `_handleRemoteAction`，两端行为因此保持一致。
class IosAudioSession {
  IosAudioSession._();

  static const MethodChannel _channel = MethodChannel('fqapp/audio_session');
  static const EventChannel _events = EventChannel(
    'fqapp/audio_session/events',
  );

  /// 远端命令回调。`positionMs` 只在 `seek` 时有值。
  static void Function(String action, int? positionMs)? onAction;

  static bool _installed = false;

  /// 订阅事件通道。重复调用是安全的，非 iOS 平台直接返回。
  static void install() {
    if (!isIOSDevice || _installed) return;
    _installed = true;
    _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map) return;
        final action = event['action']?.toString() ?? '';
        if (action.isEmpty) return;
        final raw = event['positionMs'];
        onAction?.call(action, raw is int ? raw : null);
      },
      onError: (Object error) {
        AppLog.w('audio-session', 'iOS 媒体事件通道异常: $error');
      },
    );
  }

  /// 换章的空档里音频是停的，iOS 会立刻挂起进程。这里向系统借一段额度
  /// （`UIApplication.beginBackgroundTask`，通常约 30 秒），让取流与初始化
  /// 播放器跑完，否则整章播完就停在原地，要等用户切回前台才继续。
  static Future<void> beginBackgroundWindow() async {
    if (!isIOSDevice) return;
    try {
      await _channel.invokeMethod<void>('beginBackgroundWindow');
    } catch (error) {
      AppLog.w('audio-session', '申请后台额度失败: $error');
    }
  }

  /// 结束上面借的额度。重复调用无副作用。
  static Future<void> endBackgroundWindow() async {
    if (!isIOSDevice) return;
    try {
      await _channel.invokeMethod<void>('endBackgroundWindow');
    } catch (error) {
      AppLog.w('audio-session', '释放后台额度失败: $error');
    }
  }

  /// 推送当前的媒体元数据。锁屏卡片、控制中心、CarPlay 与蓝牙都会读这里。
  static Future<void> update({
    required String title,
    required String episode,
    String cover = '',
    required bool playing,
    required int positionMs,
    required int durationMs,
    required double rate,
    required bool hasPrev,
    required bool hasNext,
    /// `audio`（听书，长语音）或 `video`（影视）。原生侧据此切换
    /// AVAudioSession 的 mode：影视走 `.moviePlayback`，避免语音优化压音轨。
    String mode = 'audio',
  }) async {
    if (!isIOSDevice) return;
    try {
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        'title': title,
        'episode': episode,
        'cover': cover,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'rate': rate,
        'hasPrev': hasPrev,
        'hasNext': hasNext,
        'mode': mode,
      });
    } on PlatformException catch (error) {
      // 媒体卡片是增强项：失败只记日志，不该影响播放本身。
      AppLog.w('audio-session', '更新媒体卡片失败: ${error.message ?? error.code}');
    } on MissingPluginException {
      // 旧版本包或未链接桥接时静默降级。
    }
  }

  /// 停止播放后清掉卡片。
  static Future<void> stop() async {
    if (!isIOSDevice) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      AppLog.w('audio-session', '清理媒体卡片失败: ${error.message ?? error.code}');
    } on MissingPluginException {
      // 同上。
    }
  }
}
