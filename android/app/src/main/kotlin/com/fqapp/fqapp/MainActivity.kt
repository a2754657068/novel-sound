package com.fqapp.fqapp

import android.content.Intent
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 音量键翻页桥。Dart 侧在阅读页且开启“音量键翻页”时通过 setEnabled(true)
    // 通知原生拦截音量键，原生 dispatchKeyEvent 吃掉按键（系统音量不再变化）并通过
    // volumeKey 回调让 Dart 翻页。该方案在原生层拦截，不受 Flutter 生命周期
    // 过渡事件漏发导致的 HardwareKeyboard 派发丢失影响。
    private var volumeKeyEnabled = false
    // 通知栏点击进来的意图：Dart 还没挂上监听时先存在这里，等它来取。
    private var listenOpenChannel: MethodChannel? = null
    private var pendingListenOpen: Map<String, String>? = null
    private var volumeChannel: MethodChannel? = null
    private var hapticsChannel: MethodChannel? = null

    /** Read by the AI foreground-service bridge; a FGS may only start while this is true. */
    internal var isResumed = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 已在前台时点通知走这里：Activity 复用，必须显式换掉 intent 再派发。
        setIntent(intent)
        deliverListenOpen(intent)
    }

    /**
     * 把通知带的 bookId / chapterId 交给 Dart。空 bookId 表示这次启动不是点通知来的，
     * 直接忽略，免得每次冷启动都往听书页跳。
     */
    private fun deliverListenOpen(intent: Intent?) {
        val bookId = intent?.getStringExtra(ListenKeepAliveService.EXTRA_BOOK_ID)
        if (bookId.isNullOrBlank()) return
        val payload =
            mapOf(
                "bookId" to bookId,
                "chapterId" to
                    (intent.getStringExtra(ListenKeepAliveService.EXTRA_CHAPTER_ID) ?: ""),
                "title" to (intent.getStringExtra(ListenKeepAliveService.EXTRA_TITLE) ?: ""),
                "cover" to (intent.getStringExtra(ListenKeepAliveService.EXTRA_COVER_URL) ?: ""),
            )
        val channel = listenOpenChannel
        if (channel == null) {
            pendingListenOpen = payload
            return
        }
        channel.invokeMethod("open", payload)
        // 同一个 intent 只处理一次，避免 Activity 重建时重复弹播放页。
        intent.removeExtra(ListenKeepAliveService.EXTRA_BOOK_ID)
    }

    override fun getFlutterShellArgs(): FlutterShellArgs =
        super.getFlutterShellArgs().also {
            // Runs before the engine/FlutterLoader starts; configureFlutterEngine is
            // too late to select the process-wide rendering backend.
            RendererCompatibility.configure(it)
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 听书通知点击 → 回到正在播放的那一章。Dart 侧注册的是
        // fqapp/listen_open 的 "open"，冷启动时它还没就绪，就用 consumePending 取。
        listenOpenChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "fqapp/listen_open",
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "consumePending") {
                        result.success(pendingListenOpen)
                        pendingListenOpen = null
                    } else {
                        result.notImplemented()
                    }
                }
            }
        // configureFlutterEngine 之后 intent 已经能读到，补发一次冷启动点击。
        deliverListenOpen(intent)

        // Native ExoPlayer host for DRM short dramas (CENC streaming decrypt).
        flutterEngine.plugins.add(NativePlayerPlugin())
        flutterEngine.plugins.add(ReaderDevicePlugin())
        // 全屏播放用 WindowInsetsController 隐藏系统栏；immersiveSticky 在
        // target SDK 36 的 edge-to-edge 下已不生效（issue #176）。
        flutterEngine.plugins.add(PlayerSystemUiPlugin())
        flutterEngine.plugins.add(SystemTtsPlugin())
        flutterEngine.plugins.add(SecureKeyPlugin())
        flutterEngine.plugins.add(LocalBookPickerPlugin())
        flutterEngine.plugins.add(LibraryBackupPlugin())
        flutterEngine.plugins.add(FanqieAccountPlugin())
        // 官方系统分享是 Intent.ACTION_SEND；没有可分享的应用时回 false。
        flutterEngine.plugins.add(SharePlugin())
        // 整本 TXT 导出：MediaStore.Downloads 或应用外部目录，见 DownloadsPlugin。
        flutterEngine.plugins.add(DownloadsPlugin())
        // 海信墨水屏整屏刷新（压残影）：反射调用厂商 EPD 接口。
        flutterEngine.plugins.add(EinkRefreshPlugin())
        // 小米澎湃 OS 公平运行内存：收 TRIM/KILL 广播，转发 Dart 处理后回系统。
        flutterEngine.plugins.add(FairMemoryPlugin())
        flutterEngine.plugins.add(AiRequestPlugin())

        hapticsChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "fqapp/haptics",
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "setEnabled") {
                        result.notImplemented()
                    } else if (call.arguments !is Boolean) {
                        result.error("BAD_ARGUMENT", "Expected a boolean", null)
                    } else {
                        // Flutter's platform haptics target this view, including
                        // Material long presses that bypass our Dart cue helper.
                        window.decorView.isHapticFeedbackEnabled = call.arguments as Boolean
                        result.success(true)
                    }
                }
            }

        // 音量键翻页通道：Dart -> 原生 setEnabled 控制是否拦截；原生 -> Dart
        // volumeKey 回调翻页方向（+1 下一页 / -1 上一页）。
        volumeChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "fqapp/volume-key",
            ).also { ch ->
                ch.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "setEnabled" -> {
                            volumeKeyEnabled = call.arguments as? Boolean ?: false
                            result.success(null)
                        }

                        else -> {
                            result.notImplemented()
                        }
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        hapticsChannel?.setMethodCallHandler(null)
        hapticsChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (volumeKeyEnabled && event != null) {
            val key = event.keyCode
            if (key == KeyEvent.KEYCODE_VOLUME_DOWN || key == KeyEvent.KEYCODE_VOLUME_UP) {
                // 仅在首次按下（非长按重复）触发一次翻页，避免按住连翻。
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    val direction = if (key == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1
                    volumeChannel?.invokeMethod("volumeKey", direction)
                }
                // 无论按下/抬起都吃掉音量键，系统音量面板不再弹出。
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
