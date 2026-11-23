part of '../pages/audio_page.dart';

/// 章末提前预取：上一章还在播的时候，先把下一章的音源（地址 + 密钥）拿到。
///
/// 只预取音源，**不预建播放器**：真机日志显示同一进程里同时存在两个 mpv 时，
/// 后建的那个实例虽然报 `playing=true`，实际没有声音。换章本身改成在原播放器
/// 上 `reopen`，冷启 mpv 的 1.5～2 秒也就省掉了。
class _AudioPrefetch {
  _AudioPrefetch(this.itemId, this.toneId);

  final String itemId;
  final String toneId;

  /// 预取到的音源；`null` 表示还在取。
  AudioSource? source;

  /// 已被丢弃（换章、切后台、出错），任何后续回调都要停手。
  bool cancelled = false;
}

extension _AudioPrefetchOps on _AudioPlaybackController {
  /// 提前多少秒开始预取（0 = 关闭）。
  int get _preloadLeadSeconds =>
      AudioPreferences.instance.preloadLeadSeconds.value;

  /// 在每次位置回调里判断：章末只剩「提前量」秒时准备下一章的音源。
  ///
  /// 幂等——已经为下一章准备好（或正在准备）就直接返回，所以每秒数次的位置
  /// 回调不会重复打上游。
  void _prepareNextAudio() {
    if (_closed ||
        _loading ||
        _completed ||
        !_wantPlay ||
        !_autoAdvance ||
        _sleepAtChapterEnd ||
        _switchingVersion) {
      return;
    }
    // 注入 loader / playerFactory 的是测试或特殊宿主，别替它们多打请求。
    if (request.sourceLoader != null || request.playerFactory != null) return;
    final lead = _preloadLeadSeconds;
    if (lead <= 0) return;
    final player = _player;
    if (player == null || !player.playing || player.buffering) return;
    if (_duration <= Duration.zero) return;
    if (_index + 1 >= _chapters.length) return;
    final next = _chapters[_index + 1];
    final existing = _audioPrefetch;
    if (existing != null) {
      if (existing.itemId == next.itemId && existing.toneId == _toneId) return;
      unawaited(_dropAudioPreload());
    }
    // 剩余时长按倍速折算成「听得完的墙钟时间」：快进时提前量也要按比例缩短，
    // 否则 2x 下章末只剩 10 秒音频，实际只剩 5 秒就会播完。
    final remaining =
        _duration -
        _position.value -
        Duration(seconds: _skipPoints.outroSeconds);
    final threshold = Duration(
      milliseconds: (lead * 1000 * (_rate <= 0 ? 1 : _rate)).round(),
    );
    if (remaining > threshold) return;
    final prefetch = _AudioPrefetch(next.itemId, _toneId);
    _audioPrefetch = prefetch;
    unawaited(_runAudioPrefetch(prefetch));
  }

  Future<void> _runAudioPrefetch(_AudioPrefetch prefetch) async {
    try {
      final source = await _loadSourceWithRetry(prefetch.itemId);
      if (prefetch.cancelled || !identical(_audioPrefetch, prefetch)) return;
      prefetch.source = source;
      AppLog.d('audio', 'event=prefetch ready item=${prefetch.itemId}');
    } catch (error) {
      AppLog.d('audio', 'event=prefetch failed error=$error');
      if (identical(_audioPrefetch, prefetch)) _audioPrefetch = null;
    }
  }

  /// 换章时取走预取到的音源：章节和音色都对得上才用，否则丢弃。
  AudioSource? _takeAudioPrefetch(String itemId, String? toneId) {
    final prefetch = _audioPrefetch;
    if (prefetch == null) return null;
    _audioPrefetch = null;
    prefetch.cancelled = true;
    final tone = toneId ?? _toneId;
    final source = prefetch.source;
    if (prefetch.itemId != itemId ||
        prefetch.toneId != tone ||
        source == null) {
      return null;
    }
    AppLog.d('audio', 'event=prefetch adopted item=$itemId');
    return source;
  }

  Future<void> _dropAudioPreload() async {
    final prefetch = _audioPrefetch;
    _audioPrefetch = null;
    if (prefetch == null) return;
    prefetch.cancelled = true;
  }
}
