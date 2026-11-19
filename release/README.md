# 未签名 IPA

`fqapp_ios_unsigned.ipa` —— 未做任何签名的 iOS 安装包，包名 `com.fqapp.fqapp`，
最低系统要求 iOS 15.0，arm64（真机）。

```
sha256  50cc7f18b356ba7fa86f6ad25d61405e4f809c556e15579b0eed145d20ee5569
size    29143089 bytes
```

用法：用自己的 `.p12` + `.mobileprovision` 重签（签名工具的「导入 IPA」功能，或用
`codesign` 手动逐层签名）。**描述文件的 App ID 必须与包名一致**，否则需要先改包名：

- 描述文件是通配符 App ID（如 `9R6K7A54LD.*`）→ 不用改包名；
- 描述文件写死了某个 App ID（如 `9R6K7A54LD.com.fw2nf.0w82`）→ 把 `Payload/Runner.app/Info.plist`
  里的 `CFBundleIdentifier` 改成该 ID，给 `Frameworks/` 里每个 framework 重新签名，再签主包。
