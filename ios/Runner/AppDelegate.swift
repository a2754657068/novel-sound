import AVFoundation
import Flutter
import MediaPlayer
import Security
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    SecureKeyBridge.register(messenger: messenger)
    FanqieLoginBridge.register(messenger: messenger)
    IosFilesBridge.register(messenger: messenger)
    AudioSessionBridge.register(messenger: messenger)
  }
}

/// 本机密钥库（iOS）：Keychain 通用密码项。
///
/// 取代 `flutter_secure_storage`（它在 Windows 端把 `win32` 钉在 5.x，挡住了
/// `wakelock_plus` / `package_info_plus` 的 Built-in Kotlin 版本，见 #205）。
///
/// - 每个条目 = 一个 account，service 固定为 `<bundle id>.secure_keys`；
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：后台朗读/播放需要
///   设备首次解锁后即可读取，且绝不随备份恢复到另一台设备；
/// - 查询失败必须区分 `errSecItemNotFound`（真的没有）与其他错误：后者抛给
///   Dart，让 `SecureKeyProvider` 失败关闭，而不是当成“没有密钥”另建一把。
final class SecureKeyBridge {
  private static let service = "\(Bundle.main.bundleIdentifier ?? "fqapp").secure_keys"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/secure_keys", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
        let key = arguments["key"] as? String,
        !key.isEmpty
      else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "缺少 key", details: nil))
        return
      }
      do {
        switch call.method {
        case "read":
          result(try read(key))
        case "write":
          guard let value = arguments["value"] as? String else {
            result(FlutterError(code: "BAD_ARGUMENT", message: "缺少 value", details: nil))
            return
          }
          try write(key, value)
          result(nil)
        case "delete":
          try delete(key)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "KEYCHAIN", message: error.localizedDescription, details: nil))
      }
    }
  }

  private static func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  private static func read(_ key: String) throws -> String? {
    var lookup = query(key)
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func write(_ key: String, _ value: String) throws {
    let data = Data(value.utf8)
    var update = query(key)
    update[kSecValueData as String] = data
    let updated = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
    if updated == errSecSuccess { return }
    if updated != errSecItemNotFound { throw KeychainError(updated) }
    var insert = query(key)
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(insert as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(added) }
  }

  private static func delete(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    throw KeychainError(status)
  }
}

struct KeychainError: LocalizedError {
  init(_ status: OSStatus) {
    self.status = status
  }

  let status: OSStatus

  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误 \(status)"
  }
}

// MARK: - 番茄登录窗口（iOS）

/// 番茄书架采集的登录入口。
///
/// Android 有原生登录页，Windows/Linux 用 `webview_windows`；iOS 上两者都没有，
/// 这里用 `WKWebView` 打开官方登录页，用户完成登录后点「读取书架」，把
/// `fanqienovel.com` 的 cookie 交回 Dart（`FanqieLibraryCaptureService.collect`
/// 拿到 cookie 后由 Rust/Dart 侧直接请求采集接口）。
///
/// 与桌面版同一套约束：只允许官方域名（离开就拦下并提示），读取时要求存在
/// `sessionid` / `sessionid_ss` / `sid_tt` 之一且非空，整串不超过 12 KB。
final class FanqieLoginBridge: NSObject {
  private static let allowedHosts = [
    "fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com",
  ]
  private static let loginURL = URL(string: "https://fanqienovel.com/main/writer/login")!
  private static var active: FanqieLoginBridge?

  private let result: FlutterResult
  private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  private let controller = UIViewController()
  private var finished = false

  private init(result: @escaping FlutterResult) {
    self.result = result
    super.init()
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/fanqie_account", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "login":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let dark = arguments["dark"] as? Bool ?? false
        DispatchQueue.main.async {
          login(dark: dark, result: result)
        }
      case "cancelLogin":
        DispatchQueue.main.async {
          active?.finish(nil, result: nil)
          result(nil)
        }
      case "clearSession":
        DispatchQueue.main.async {
          clearSession(completion: { result(nil) })
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func login(dark: Bool, result: @escaping FlutterResult) {
    guard active == nil else {
      result(FlutterError(code: "BUSY", message: "登录窗口已打开", details: nil))
      return
    }
    guard let host = topViewController() else {
      result(FlutterError(code: "NO_WINDOW", message: "窗口尚未就绪", details: nil))
      return
    }
    let bridge = FanqieLoginBridge(result: result)
    active = bridge
    bridge.present(from: host, dark: dark)
  }

  private func present(from host: UIViewController, dark: Bool) {
    controller.view.backgroundColor = .systemBackground
    controller.title = "番茄登录"
    controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "读取书架", style: .done, target: self, action: #selector(readTapped))

    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    controller.view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
      webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
    ])
    if dark {
      controller.overrideUserInterfaceStyle = .dark
      webView.overrideUserInterfaceStyle = .dark
    }
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    host.present(navigation, animated: true)
    webView.load(URLRequest(url: Self.loginURL))
  }

  @objc private func cancelTapped() {
    finish(nil, result: result, dismissedByUser: true)
  }

  @objc private func readTapped() {
    webView.evaluateJavaScript("document.title") { [weak self] _, _ in
      self?.readCookies()
    }
  }

  private func readCookies() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      let scoped = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      let names = ["sessionid", "sessionid_ss", "sid_tt"]
      let hasLogin = scoped.contains { cookie in
        names.contains(cookie.name) && !cookie.value.isEmpty
      }
      guard hasLogin else {
        DispatchQueue.main.async { self.alert("尚未取得登录态", "请先在官方页面完成登录与验证，再点「读取书架」。") }
        return
      }
      let value = scoped.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      guard value.utf8.count <= 12 * 1024 else {
        DispatchQueue.main.async { self.alert("登录态过大", "读取失败，请重试。") }
        return
      }
      DispatchQueue.main.async { self.finish(value, result: self.result) }
    }
  }

  private func alert(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    controller.present(alert, animated: true)
  }

  /// 关闭窗口并把结果交回 Dart；`finished` 保证只回调一次。
  private func finish(_ value: String?, result: FlutterResult?, dismissedByUser: Bool = false) {
    guard !finished else { return }
    finished = true
    Self.active = nil
    let navigation = controller.navigationController
    let complete = {
      result?(value)
    }
    if dismissedByUser, let navigation {
      navigation.dismiss(animated: true) { complete() }
    } else {
      navigation?.dismiss(animated: true) { complete() }
    }
  }

  private static func clearSession(completion: @escaping () -> Void) {
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { cookies in
      let targets = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      let group = DispatchGroup()
      for cookie in targets {
        group.enter()
        store.httpCookieStore.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { completion() }
    }
  }

  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

extension FanqieLoginBridge: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.scheme != "https" || url.user != nil || url.password != nil {
      decisionHandler(.cancel)
      return
    }
    let host = url.host ?? ""
    let allowed = FanqieLoginBridge.allowedHosts.contains { entry in
      host == entry || host.hasSuffix(".\(entry)")
    }
    if allowed {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      alert("已拦截跳转", "请留在番茄官方登录页面完成登录。")
    }
  }
}

// MARK: - 文件导出（iOS 分享面板）

/// `saveBackup` / `exportFanqieCapture` / `saveText` 在桌面上弹「另存为」，
/// iOS 没有等价的选择器，改为写临时文件再弹系统分享面板（存储到「文件」、
/// 发微信、AirDrop 都行）。Dart 侧拿到的是临时文件路径。
final class IosFilesBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/ios_files", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
        let name = arguments["name"] as? String,
        let data = arguments["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "缺少文件内容", details: nil))
        return
      }
      presentShare(name: name, data: data.data, result: result)
    }
  }

  private static func presentShare(
    name: String, data: Data, result: @escaping FlutterResult
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fqapp-share", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(sanitize(name))
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      result(FlutterError(code: "WRITE", message: error.localizedDescription, details: nil))
      return
    }
    DispatchQueue.main.async {
      guard let host = FanqieLoginBridge.topViewController() else {
        result(FlutterError(code: "NO_WINDOW", message: "窗口尚未就绪", details: nil))
        return
      }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = activity.popoverPresentationController,
        UIDevice.current.userInterfaceIdiom == .pad
      {
        popover.sourceView = host.view
        popover.sourceRect = CGRect(
          x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      var reported = false
      activity.completionWithItemsHandler = { _, _, _, _ in
        guard !reported else { return }
        reported = true
        result(url.path)
      }
      host.present(activity, animated: true)
    }
  }

  private static func sanitize(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(
      of: "[\\\\/:*?\"<>|]", with: "_", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "fqapp-export" : trimmed
  }
}

// MARK: - 锁屏 / 控制中心 / 耳机键（iOS 的媒体会话）
//
// 安卓侧由 `ListenKeepAliveService` 提供前台服务 + MediaSessionCompat；iOS 没有
// 等价物，必须自己组合 AVAudioSession（让音频在后台继续）+ MPNowPlayingInfoCenter
// （锁屏与任务切换器里的卡片）+ MPRemoteCommandCenter（锁屏按钮、耳机线控、
// 车机与蓝牙按键）。Dart 侧只在播放状态变化时推一次元数据，收到的远端命令
// 复用安卓那套 `_handleRemoteAction`，两端行为因此一致。
//
//   MethodChannel `fqapp/audio_session`        "update" / "stop"
//   EventChannel  `fqapp/audio_session/events` play / pause / playPause / next / prev / seek / stop
final class AudioSessionBridge: NSObject {
  private static let methodName = "fqapp/audio_session"
  private static let eventName = "fqapp/audio_session/events"

  private static var sink: FlutterEventSink?
  private static var configured = false
  private static var sessionActive = false
  private static var playing = false
  private static var artwork: MPMediaItemArtwork?
  private static var artworkKey: String?
  private static var artworkTask: URLSessionDataTask?
  private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: methodName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "update":
        guard let arguments = call.arguments as? [String: Any] else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "缺少媒体元数据", details: nil))
          return
        }
        apply(arguments)
        result(nil)
      case "stop":
        teardown()
        result(nil)
      case "beginBackgroundWindow":
        // 换章的空档里没有音频在播，iOS 会立刻挂起进程；这段额度让取流与
        // 初始化播放器跑完（系统最多给约 30 秒，够一次换章）。
        beginBackgroundWindow()
        result(nil)
      case "endBackgroundWindow":
        endBackgroundWindow()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(name: eventName, binaryMessenger: messenger)
      .setStreamHandler(Events())
    configureSession()
    registerCommands()
    observeInterruptions()
  }

  // MARK: - 换章时的后台额度

  private static func beginBackgroundWindow() {
    endBackgroundWindow()
    backgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "fqapp-chapter-advance"
    ) {
      // 到期回调：系统要收回额度，先主动结束，避免进程被强杀。
      trace("background window EXPIRED")
      endBackgroundWindow()
    }
    trace("background window begin raw=\(backgroundTask.rawValue) remaining=\(UIApplication.shared.backgroundTimeRemaining)")
  }

  /// 桥的调试轨迹：写到 App 自己的 logs 目录，方便用 devicectl 取回。
  static func trace(_ message: String) {
    guard
      let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }
    let dir = base.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("bridge.log")
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: file) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: file, options: .atomic)
    }
  }

  private static func endBackgroundWindow() {
    guard backgroundTask != .invalid else { return }
    trace("background window end raw=\(backgroundTask.rawValue)")
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  // MARK: - 会话

  /// 当前音频会话的用途：`audio` 是听书（长语音），`video` 是影视。
  private static var sessionMode = ""

  private static func configureSession(_ mode: String = "audio") {
    let session = AVAudioSession.sharedInstance()
    // 听书是长语音，走 spokenAudio：静音键不打断，也不会启用系统为音乐准备的
    // 空间音频；影视要走 moviePlayback，否则 AirPods 的语音优化会压到音轨上。
    let wanted = mode == "video" ? AVAudioSession.Mode.moviePlayback
                                 : AVAudioSession.Mode.spokenAudio
    let changed = !configured || sessionMode != mode
    guard changed else { return }
    configured = true
    sessionMode = mode
    do {
      try session.setCategory(.playback, mode: wanted, options: [])
    } catch {
      NSLog("audio session category failed: \(error.localizedDescription)")
    }
    // 冷启动时后台播放在会话真正开始前也可能先到元数据，这里先激活一次；
    // 失败不致命，下一次 update 会再试。
    activateSession()
  }

  private static func activateSession() {
    guard configured else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true, options: [])
      sessionActive = true
    } catch {
      sessionActive = false
      NSLog("audio session activate failed: \(error.localizedDescription)")
    }
  }

  private static func apply(_ arguments: [String: Any]) {
    configureSession(arguments["mode"] as? String ?? "audio")
    // 只有 playing 为真才强行激活：暂停时保持会话，让锁屏卡片留在原地。
    let nowPlaying = arguments["playing"] as? Bool ?? false
    if nowPlaying { activateSession() }
    playing = nowPlaying

    let title = arguments["title"] as? String ?? ""
    let episode = arguments["episode"] as? String ?? ""
    let positionMs = arguments["positionMs"] as? Int ?? 0
    let durationMs = arguments["durationMs"] as? Int ?? 0
    let rate = arguments["rate"] as? Double ?? 1
    let hasPrev = arguments["hasPrev"] as? Bool ?? false
    let hasNext = arguments["hasNext"] as? Bool ?? false
    let cover = arguments["cover"] as? String ?? ""

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title.isEmpty ? "什锦铺" : title,
      MPMediaItemPropertyAlbumTitle: episode,
      MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000.0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000.0,
      MPNowPlayingInfoPropertyPlaybackRate: nowPlaying ? rate : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPMediaItemPropertyAlbumTrackNumber: 1,
    ]
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = nowPlaying ? .playing : .paused

    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] = episode

    commands(enabled: true, hasPrev: hasPrev, hasNext: hasNext)
    if !cover.isEmpty { loadArtwork(coverURL: cover) }
  }

  private static func loadArtwork(coverURL: String) {
    guard coverURL != artworkKey else { return }
    artworkKey = coverURL
    artworkTask?.cancel()
    guard let url = URL(string: coverURL) else { return }
    // 封面来自 CDN，下载失败只是没有大图，不影响播放。
    artworkTask = URLSession.shared.dataTask(with: url) { data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      let cover = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      DispatchQueue.main.async {
        guard coverURL == artworkKey else { return }
        artwork = cover
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = cover
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    artworkTask?.resume()
  }

  private static func teardown() {
    playing = false
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    commands(enabled: false, hasPrev: false, hasNext: false)
    artwork = nil
    artworkKey = nil
    artworkTask?.cancel()
    artworkTask = nil
    guard sessionActive else { return }
    sessionActive = false
    do {
      // notifyOthersOnDeactivation：让别的 App（音乐、播客）能接着播。
      try AVAudioSession.sharedInstance().setActive(
        false, options: [.notifyOthersOnDeactivation])
    } catch {
      NSLog("audio session deactivate failed: \(error.localizedDescription)")
    }
  }

  // MARK: - 远端命令

  private static func commands(enabled: Bool, hasPrev: Bool, hasNext: Bool) {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = enabled
    center.pauseCommand.isEnabled = enabled
    center.togglePlayPauseCommand.isEnabled = enabled
    center.stopCommand.isEnabled = enabled
    center.changePlaybackPositionCommand.isEnabled = enabled
    center.previousTrackCommand.isEnabled = enabled && hasPrev
    center.nextTrackCommand.isEnabled = enabled && hasNext
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
  }

  private static func registerCommands() {
    let center = MPRemoteCommandCenter.shared()

    func handler(_ action: String) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
      return { _ in
        emit(["action": action])
        return .success
      }
    }

    center.playCommand.addTarget { handler("play")($0) }
    center.pauseCommand.addTarget { handler("pause")($0) }
    center.togglePlayPauseCommand.addTarget { handler("playPause")($0) }
    center.stopCommand.addTarget { handler("stop")($0) }
    center.nextTrackCommand.addTarget { handler("next")($0) }
    center.previousTrackCommand.addTarget { handler("prev")($0) }
    center.changePlaybackPositionCommand.addTarget { event in
      guard let seek = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      emit(["action": "seek", "positionMs": Int(seek.positionTime * 1000)])
      return .success
    }
    commands(enabled: false, hasPrev: false, hasNext: false)
  }

  // MARK: - 中断与路由变化

  private static func observeInterruptions() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { note in
      guard
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      switch type {
      case .began:
        // 来电/闹钟：先停下，等系统说可以恢复再继续，避免和对方抢音频。
        if playing { emit(["action": "pause"]) }
      case .ended:
        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
          .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        if options.contains(.shouldResume) {
          activateSession()
          emit(["action": "play"])
        }
      @unknown default:
        break
      }
    }
    center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { note in
      guard
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
      else { return }
      // 拔耳机时 iOS 会把音频切到外放，听书场景里这是打扰，直接暂停。
      if reason == .oldDeviceUnavailable, playing {
        emit(["action": "pause"])
      }
    }
  }

  private static func emit(_ payload: [String: Any]) {
    guard let sink else { return }
    if Thread.isMainThread {
      sink(payload)
    } else {
      DispatchQueue.main.async { sink(payload) }
    }
  }

  private final class Events: NSObject, FlutterStreamHandler {
    func onListen(
      withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
      AudioSessionBridge.sink = events
      return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
      AudioSessionBridge.sink = nil
      return nil
    }
  }
}
