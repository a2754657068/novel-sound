<p align="center">
  <img src="assets/images/app_logo.webp" width="120" alt="什锦铺">
</p>

<h1 align="center">什锦铺 · iOS 维护分支</h1>

<p align="center">
  小说 / 短剧 / 漫剧 / 听书 / 漫画，一个书架装完
</p>

> **上游项目：[ch6vip/novel-sound](https://github.com/ch6vip/novel-sound)**（GPL-3.0）
>
> 本仓库是基于上游的个人维护分支，**主要目标是让 iOS 能装上、能用**；
> 上游本身只发布 Android / Windows 版本，官方也明确写了「目前没有正式的 iPhone 安装包」。

---

## 分支信息

| 项 | 值 |
|---|---|
| 本分支 | `custom-ios-2026-11-19` |
| 基于上游版本 | `1.0.204+209` |
| 主要维护平台 | iOS 15.0+（真机，arm64） |
| 未签名 IPA | [`release/fqapp_ios_unsigned.ipa`](release/fqapp_ios_unsigned.ipa)（见 [release/README.md](release/README.md)） |
| 变更清单 | [变更说明_2026-11-19.md](变更说明_2026-11-19.md)、[变更说明_2026-11-18.md](变更说明_2026-11-18.md)、[修复说明_2026-11-16.md](修复说明_2026-11-16.md) |

上游在 2026-11-17 发布了 `1.0.205`，新增了云盘/多设备同步、UGC 短篇等功能。
本分支**暂不跟进**：那次改动重写了播放器的平台通道，合并后 iOS 侧的视频与听书会失效，
需要把 iOS 播放链路整段重做，工作量大于收益。

---

## 在原作者基础上添加/修改了什么

### 一、iOS 平台支持（本分支最主要的工作）

上游代码里虽然有 `ios/` 目录，但没有可用的 iOS 播放实现，也没有构建链。本分支补齐：

- **Rust 核心接入 iOS**：`scripts/build_rust_ios.sh` 把 `fqapi_core` 编成
  `aarch64-apple-ios` 静态库，通过 `-force_load` 链进 App（`DEAD_CODE_STRIPPING = NO`，
  否则 `dlsym` 找不到符号），Dart 侧走 flutter_rust_bridge 的 `ExternalLibrary.process()`。
- **视频播放**：新增 `lib/services/ios_platform.dart`，把 `fqapp/native_player` 的方法/事件通道
  接到桌面端那套 media_kit 实现上；`pubspec.yaml` 补 `media_kit_libs_ios_video` 带入
  libmpv（`Mpv.xcframework`）；`supportsVideoPlayback` 放开 iOS。
- **加密媒体的取流**：Rust 的 `desktop_media` / `desktop_fetch` 模块与 CENC 解密所需的 C 源
  一并编进 iOS 目标，短剧这类带 `encrypt_info` 的片子才能在 iOS 上播。
- **导入图书**：`file_selector_ios` 只认 UTI，补 `public.plain-text` / `org.idpf.epub-container`；
  GBK 编码的 TXT 用 iconv 解码（原来在 iOS 上调 `kernel32.dll` 必然失败）。
- **番茄登录/采集**：`AppDelegate.swift` 里用 `WKWebView` 打开 `fanqienovel.com` 登录页，
  点「读取书架」把 cookie 交回 Dart（`FanqieLoginBridge`）。
- **文件导出**：`IosFilesBridge` 走 `UIActivityViewController` 分享面板，
  备份、TXT 导出、番茄采集都能「存储到文件 / 隔空投送」。
- **听书与视频的系统级控制**：`AudioSessionBridge` 提供
  `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`（锁屏/控制中心卡片、耳机键、
  来电打断、拔耳机暂停），并区分 `.spokenAudio` / `.moviePlayback` 音频会话模式。

### 二、上游接口变化导致的播放故障（这几次修复是上游改了服务端）

| 现象 | 真因 | 修复 |
|---|---|---|
| 短剧/漫剧全部「播放失败」 | 播放请求必须带 `x-medusa` 头，客户端原来主动把它剥掉 | 保留该头 |
| 部分漫剧、短剧「该视频暂不支持播放」 | `mixed_video_id_map` 的 `content_type` 只发了 `1004` | 同时挂 `1 / 1002 / 1004 / 1007` |
| 某些剧全部档位都是 bytevc2（VVC） | mpv 无解码器，上游模型里 `codec_type=4` | 自动改写为 `codec_type=1` 取 H.265 版本 |

### 三、阅读与播放体验

- **分类独立二级页**（`category_detail_page.dart`）：官方分类池 + 子分类轮换采样，
  支持「小说 / 短剧 · 漫剧」切换、完结状态、字数档位、标签筛选，筛选全部在本地完成
  （上游接口忽略 `limit`/`offset`，且筛选项其实不过滤，所以不能依赖它）。
- **首页小说推荐三段式**：第一段排行榜不变 → 「完结推荐」「连载推荐」两条横滑
  （各 10 本，日期/启动种子 → 每次打开换一批）→「更多推荐」纵向网格，下滑自动加载。
- **常读类型加权**：从阅读历史与阅读时长统计用户常看的类型，只对「更多推荐」加权
  （最多 3 个类型、保留探索位），完结/连载两栏不加权，避免越用越窄。
- **首页顶栏**：去掉与底部重复的「短剧」「漫剧」，四项（推荐 / 小说 / 漫画 / 听书）平分整行。
- **播放页**：评论按钮上方加「收藏」（短剧/漫剧一键进书架）；全屏胶囊挪到信息区上方居中，
  半透明不挡字幕。
- **书架**：新增按媒介筛选（全部/小说/漫画/短剧/漫剧/听书），底部 dock 常驻不隐藏。

### 四、iOS 上的稳定性修复

- **后台整章播完不续播**：iOS 在音频停掉后约 1 秒挂起进程，换章那几步跑不完。
  现在后台收到「本章播完」立刻走 `_advanceInBackground()`，在**同一个 mpv 实例上原地换源**
  （后台新建播放器会卡在音频输出初始化），并用 `beginBackgroundTask` 借一段后台额度。
- **离线缓存打不开**：`SecureKeyBridge.write` 把 `kSecClass` 等查询键塞进了
  `SecItemUpdate` 的更新字典，iOS 26/27 返回 `errSecNoSuchAttr(-25303)`，导致 Hive 密钥
  永远建不出来。改为只提交 `kSecValueData`。

---

## 平台支持现状

| 平台 | 状态 |
|---|---|
| **iOS 15+** | **主要维护目标**，本轮所有验证都在 iPhone 真机上完成 |
| Android | 代码保留、可构建（`scripts/build_rust_backend.sh` + `flutter build apk`），理论上可用；但本分支主要精力在 iOS，**不保证所有功能与 iOS 一致**（历史上曾出现个别页面未适配的情况） |
| Windows | 需要 Windows 主机 + VS2022 + MSVC 自行编译（macOS 无法交叉编译），**不提供二进制、不保证功能完整** |
| macOS / Linux | 上游本来就没有正式包，本分支同样不提供 |

---

## 构建（iOS）

```bash
# 1. 依赖（macOS + Xcode 27 + Flutter 3.50 + Rust 1.99 + CocoaPods 1.17）
flutter pub get

# 2. 编 Rust 静态库（要求已装 xcode-select / 见 IOS.md）
./scripts/build_rust_ios.sh          # 产物：ios/Frameworks/libfqapi_core.a

# 3. 编 App
flutter build ios --release --no-codesign
# 产物：build/ios/iphoneos/Runner.app

# 4. 自己签名（示例）
#    - 需要 .p12 + .mobileprovision
#    - 注意：entitlements 里不要保留描述文件中的 keychain-access-groups（通配符组无效）
ditto build/ios/iphoneos/Runner.app Payload/Runner.app
zip -qry fqapp.ipa Payload
```

更细的签名步骤、踩过的坑（iCloud 目录导致 `codesign` 报 `resource fork, Finder information…`、
CocoaPods CDN 被墙需要本地 FlutterMacOS 占位 spec 等）都写在
[变更说明_2026-11-19.md](变更说明_2026-11-19.md) 与 [IOS.md](IOS.md) 里。

---

## 许可

沿用上游：**GPL-3.0**。本分支的修改同样以 GPL-3.0 发布。
上游 README 原文保留在 [README_UPSTREAM.md](README_UPSTREAM.md)。
