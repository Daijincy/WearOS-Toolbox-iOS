# WearOS 工具箱（iOS 版）

通过 WiFi ADB（TCP）远程管理 WearOS 手表（如小米 Watch5）的 iOS 应用。
UI 全部使用 iOS 26 原生 SwiftUI 控件，由 GitHub Actions 云构建生成 IPA。

## 功能

| 模块 | 说明 |
|---|---|
| 设备配对 | 首次配对（IP + 配对端口 + 6 位配对码），配对成功后保存档案 |
| 设备连接 | 选中档案后可修改 IP/端口直接连接（无需再次配对码），密钥持久化 |
| 安装 APK | 推送 APK 到设备并 `pm install` |
| 安装 Split APK | 多选 base + 拆分包，`pm install-create/write/commit` 批量安装 |
| 交互式终端 | `shell:v2` 实时终端，命令历史，预设常用命令 |
| 命令行 | 单次执行命令返回完整输出 |
| 远程屏幕 | 双模式：静态截图（screencap）+ scrcpy 实时镜像（H.264 硬解码 + 触控/按键） |
| 屏幕工具 | 修改分辨率 / DPI，一键恢复默认 |
| 电池工具 | 读取电量、充电状态、电池属性 |
| 文件管理 | 双向文件传输，浏览/删除设备目录 |
| 应用管理 | 列出应用、卸载、清除数据 |
| 剪切板 | 双向同步剪贴板文本 |
| 备份恢复 | 应用数据备份命令入口 |
| 日志 | ADB 通信日志实时查看 |

## 架构

```
WearOSBox/
├── Models/          # SwiftData 设备档案、功能模块枚举
├── Services/
│   ├── ADB/         # ADB 协议核心（报文/连接/配对/shell/sync/设备操作）
│   ├── ScrcpyClient # scrcpy v2 视频流 + VideoToolbox 硬解码 + 控制指令
│   ├── DeviceScanner# mDNS 扫描 _adb-tls-pairing / _adb-tls-connect
│   └── AdbSessionManager  # 会话状态管理（单例）
├── Views/           # 全部页面（iOS 26 原生控件）
└── Utils/           # 输入校验、日志
```

### ADB 协议实现（无内置 adb 二进制）

- **传输层**：CNXN / AUTH / OPEN / WRTE / OKAY / CLSE 报文（CRC32 + magic 校验）
- **认证**：RSA-2048 密钥，RSA-SHA1 PKCS1v1.5 签名 token；公钥 PKCS#8 SPKI PEM 格式
- **配对**：AOSP `pairing_connection.cpp` 协议，X25519 密钥交换 + AES-256-GCM 加密传输配对码
- **Shell**：`shell:v2` 帧解析（stdout/stderr/exit）
- **文件**：sync 协议（SEND/RECV/DATA/DONE）
- **镜像**：scrcpy v2 协议，AVCC H.264 硬解码

## GitHub 云构建

推送 `main` 分支或打 `v*` tag 自动触发 `build-ipa.yml`，macOS runner 构建并上传 IPA artifact。

### 签名配置（可选）

未配置 secrets 时构建**无签名 IPA**（验证编译可用，无法安装真机）。
配置以下仓库 secrets 后自动签名构建可安装 IPA：

| Secret | 说明 |
|---|---|
| `DEVELOPER_CERTIFICATE` | 开发者证书 `.p12` 的 Base64 |
| `DEVELOPER_CERTIFICATE_PASSWORD` | `.p12` 密码 |
| `PROVISIONING_PROFILE` | 描述文件 `.mobileprovision` 的 Base64 |
| `PROVISIONING_PROFILE_NAME` | 描述文件名称（Xcode 中显示的名字） |
| `DEVELOPMENT_TEAM` | Team ID（如 ABC123DEFG） |
| `KEYCHAIN_PASSWORD` | 构建时临时钥匙串密码（随意设置） |

本地生成 Base64：

```bash
base64 -i Certificates.p12 | pbcopy
base64 -i profile.mobileprovision | pbcopy
```

### 本地构建（可选）

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project WearOSBox.xcodeproj -scheme WearOSBox -destination 'generic/platform=iOS' -archivePath build/WearOSBox.xcarchive archive
xcodebuild -exportArchive -archivePath build/WearOSBox.xcarchive -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export
```

## 使用前提

1. 手表开启「开发者选项 → 无线调试」，记下配对端口与配对码
2. iPhone 与手表连接**同一 WiFi**
3. iOS 26 及以上，首次打开需在系统设置中允许**本地网络**权限

## 限制

- 仅支持 WiFi 局域网 TCP；不支持蓝牙 ADB
- 首次配对需在手表屏幕确认授权
- App 退后台会断开 ADB 连接（iOS 系统限制）
- scrcpy 实时镜像需要设备端已推送 `scrcpy-server.jar` 到 `/data/local/tmp/`
- 部分系统命令受 WearOS 权限管控返回 Permission denied（与电脑端 adb 一致）

## 协议参考

- AOSP `system/core/adb`（protocol.txt / auth.cpp / pairing / sync / shell v2）
- scrcpy（https://github.com/Genymobile/scrcpy）
