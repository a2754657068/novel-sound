# iOS 锁屏媒体卡片、耳机键与中断恢复

这个分支只做一件事：把 iOS 的「正在播放」接到系统媒体中心，并处理音频中断与路由变化。
不包含播放器改造，也不依赖其他分支，可以单独评审。

## 链路

```
Dart                          Swift (ios/Runner/AppDelegate.swift)
──────────────────────────    ─────────────────────────────────────────────
IosAudioSession.update(…)  →  MethodChannel fqapp/audio_session  "update"
                                 · AVAudioSession.setCategory(.playback, mode: .spokenAudio/.moviePlayback)
                                 · MPNowPlayingInfoCenter（标题 / 章节 / 封面 / 进度 / 倍速 / 播放态）
                                 · MPRemoteCommandCenter 开关（上一章 / 下一章按 hasPrev/hasNext）

IosAudioSession.stop()     →  MethodChannel fqapp/audio_session  "stop"
                                 · 清空 nowPlayingInfo，playbackState = .stopped，关闭命令

（事件）                       EventChannel fqapp/audio_session/events
                               ← play / pause / playPause / next / prev / stop
                               ← seek（带 positionMs）

（后台额度）                  "beginBackgroundWindow" / "endBackgroundWindow"
                                 UIApplication.beginBackgroundTask，用来盖住换章时的静音空档
```

远端命令在 Dart 侧统一由 `IosAudioSession.onAction` 派发：听书走
`AudioPlaybackController._handleIosRemoteAction`，播放页走
`VideoPlayerChrome._handleIosMediaAction`。两处按「谁最后接入谁接管」协作，
离开时只在自己仍是接管方的情况下清理。

## 中断与路由

- `AVAudioSession.interruptionNotification`
  - `.began` 且正在播放 → 发 `pause`
  - `.ended` 且 `options.contains(.shouldResume)` → 重新激活会话并发 `play`
- `AVAudioSession.routeChangeNotification`
  - `.oldDeviceUnavailable`（拔耳机 / 蓝牙断开）→ 发 `pause`

## 涉及文件

| 文件 | 作用 |
|---|---|
| `ios/Runner/AppDelegate.swift` | `AudioSessionBridge`（约 320 行，纯新增）：会话配置、Now Playing、远端命令、中断/路由、后台额度 |
| `lib/services/ios_audio_session.dart` | Dart 侧封装：`install()` / `update()` / `stop()` / `beginBackgroundWindow()` / `endBackgroundWindow()` |
| `lib/pages/audio_page.dart` | 加一行 import（`audio_playback_controller.dart` 是它的 part） |
| `lib/services/audio_playback_controller.dart` | 听书：`start()` 接入、`_syncForeground()` 推送、远端命令与 `seek`、`close()` 释放 |
| `lib/widgets/video_player_chrome.dart` | 播放页：接入/推送/远端命令，`mode: 'video'` 用 `.moviePlayback` |

## 关于 1.0.205

本分支基于 1.0.204。1.0.205（含 PR #467）里已有的 `IosAudioBridge` 只有
`activate` / `deactivate` 两个方法，没有 Now Playing、没有远端命令、也没有中断与路由处理。
移植时建议直接用它替换 `IosAudioBridge`，并把 `_syncForeground()` 与播放页的推送点
接到 1.0.205 的对应位置；Dart 侧 `ios_audio_session.dart` 可原样复用。

## 验证

- 设备：iPhone 17 Pro Max（iOS 27.2），Release 构建
- 锁屏：出现「正在播放」卡片，标题为剧名 / 书名，副标题为章节名，进度条随播放推进
- 控制中心与耳机键：播放 / 暂停 / 上一章 / 下一章 均生效
- 来电或闹钟打断后自动暂停；挂断后（`shouldResume`）自动恢复
- 拔耳机 / 蓝牙断开后自动暂停
