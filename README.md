<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="TabNest icon">
</p>

<h1 align="center">TabNest — Menu Bar Browser</h1>

<p align="center">
  把常用网页收进 macOS 菜单栏，需要时在图标下方即时展开。
</p>

<p align="center">
  <a href="https://github.com/liangix/TabNest/actions/workflows/release.yml"><img src="https://github.com/liangix/TabNest/actions/workflows/release.yml/badge.svg" alt="Release DMG"></a>
  <a href="https://github.com/liangix/TabNest/releases/latest"><img src="https://img.shields.io/github/v/release/liangix/TabNest" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138" alt="Swift 5.9+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

TabNest 是一个原生 macOS 菜单栏浏览器。每个网页拥有独立的浮动面板、站点图标和快捷键，也可以把所有 Tab 收拢到一个应用图标。面板使用常驻 `WKWebView`，收起再打开不会丢失当前页面和登录状态。

纯 Swift 实现，基于 **AppKit + WebKit + SwiftUI**，没有第三方运行时依赖。

## 下载与安装

1. 从 [GitHub Releases](https://github.com/liangix/TabNest/releases/latest) 下载最新的 `TabNest-<version>.dmg`。
2. 打开 DMG，将 `TabNest.app` 拖入 `Applications`。
3. 启动 TabNest，菜单栏会出现站点图标。

当前 Release 使用 ad-hoc 签名，尚未进行 Apple Developer ID 公证。macOS 首次启动时可能提示“Apple 无法验证 TabNest 是否包含可能危害 Mac 安全或泄漏隐私的恶意软件”。请只从本项目的 GitHub Releases 下载，并按下面的方法放行；不要安装来源不明的二次打包版本。

### macOS 安全放行

1. 先尝试打开一次 TabNest，看到安全提示后关闭提示框。
2. 打开“系统设置 → 隐私与安全性”。
3. 向下滚动到“安全性”，找到 TabNest 被阻止的提示。
4. 点击“仍要打开”，输入登录密码或使用 Touch ID 确认。
5. 再次确认“打开”。此操作只需执行一次，之后可正常启动 TabNest。

“仍要打开”通常只会在首次启动被阻止后的一段时间内出现。如果没有看到，请重新尝试启动 TabNest，再回到“隐私与安全性”。部分 macOS 版本也可以在 Finder 的“应用程序”中右键 TabNest，选择“打开”并确认。

不要为了安装 TabNest 全局关闭 Gatekeeper。

系统要求：**macOS 13 Ventura 或更高版本**。Release DMG 包含 `arm64` 与 `x86_64` 双架构，可运行于 Apple Silicon 和 Intel Mac。

## 核心能力

- **菜单栏原生体验**：面板始终停靠在所属图标正下方，拖动缩放时保持居中对齐。
- **展开或收拢**：每个 Tab 可以显示为独立 favicon，也可以收拢为单个 TabNest 图标。
- **预设与 Tab 分离**：关闭 Tab 不会删除预设站点，随时可以从右键菜单重新打开。
- **站点快捷键**：默认使用 `⌥⇧1–9`，支持为每个站点录制自定义全局快捷键或关闭快捷键。
- **可靠的站点图标**：优先读取页面真实 Tab favicon，带缓存与回退策略，避免加载闪烁。
- **浏览器标识**：支持系统 Safari、固定桌面 Safari、移动端 Safari 和自定义 User-Agent；修改后立即重新载入生效。
- **页面缩放**：每个站点独立保存，默认 90%，范围 50%–200%。
- **媒体控制**：支持静音；关闭 Tab 时同步停止音视频和网络加载。
- **网页录音**：HTTPS 页面可以请求麦克风，先确认网页来源，再进入 macOS 系统授权。
- **网页通知**：按站点授权，在菜单栏图标下方显示提醒和未读红点，点击提醒打开对应浮窗；支持关闭通知。
- **中英界面**：自动跟随系统首选语言，支持中文和英语，其他语言环境回退为英语。
- **其他能力**：自动刷新、强制刷新、前进后退、登录态持久化、登录时启动。

## 网页通知

首次打开页面后，网站通过标准 `Notification.requestPermission()` 请求授权，再通过 `new Notification(...)` 发送通知。TabNest 在网页顶部显示非阻塞授权条，展示具体来源，可选择 **允许 / 拒绝 / 稍后**，不暂停网页交互。选择稍后或收起浮窗不保存决定；导航或关闭 Tab 会取消旧请求。授权按站点预设及精确来源（协议、域名、端口）保存，不会沿用到跨站跳转后的其他网站。请求授权需要在可见页面中由用户操作触发。

- 提醒小窗在所属图标下方显示约 3 秒；收拢模式显示在应用图标下方。未读红点显示在图标右下角。
- 菜单栏红点表示该 Tab 有未读通知；点击提醒或打开对应 Tab 后清除。收拢菜单也会标记未读站点。
- 点击提醒的关闭按钮只隐藏提醒；点击禁用按钮，或在 **右键菜单 → 网页通知** 中取消启用，可立即停用该站点的通知。添加／编辑站点时也可关闭。
- **右键菜单 → 网页通知** 展示当前页面来源，可直接选择 **允许此网站通知 / 禁止此网站通知 / 下次询问**，无需等待网页弹出请求。也可使用 **重置通知授权** 清除该站点预设保存的全部来源授权。
- 提醒小窗带有指向所属菜单栏图标的箭头；收拢模式下指向 TabNest 图标，靠近屏幕边缘时箭头随图标位置调整。
- 每个 Tab 仅保留最新一条未读通知，不保存通知内容到磁盘。关闭 Tab、页面导航或退出应用会清除对应提醒；已有授权的打开 Tab 会在下次启动时加载。

这是 TabNest 内的提醒，不是 macOS 通知中心推送。仅支持已加载且保持打开的 Tab（浮窗可收起）；不识别任意网页内部提示条，不支持 Service Worker 的 `showNotification()`、Push API 或关闭 Tab 后的后台推送。后台运行仍受 WebKit／系统节流影响，不能承诺所有网站实时送达。

## 默认预设

首次安装且不存在旧偏好数据时，TabNest 会创建以下预设并打开为 Tab：

| 站点 | 地址 | 默认浏览器标识 |
|---|---|---|
| Bing | `https://www.bing.com` | 系统 Safari |
| GitHub | `https://github.com` | 系统 Safari |
| YouTube Music | `https://music.youtube.com` | 桌面 Safari |
| ChatGPT | `https://chatgpt.com` | 系统 Safari |

覆盖安装不会重置用户已经维护的预设和 Tab。

## 使用方式

| 操作 | 结果 |
|---|---|
| 左键菜单栏图标 | 展开或收起对应网页面板 |
| 右键 / `⌥` + 左键图标 | 打开站点操作菜单 |
| `Esc` / `⌘W` | 收起当前面板 |
| `⌘R` | 重新载入 |
| `⇧⌘R` | 重新应用 UA 并忽略缓存载入 |
| `⌘[` / `⌘]` | 后退 / 前进 |
| `⌘+` / `⌘−` | 放大 / 缩小页面 |
| `⌘0` | 恢复默认 90% 缩放 |
| `⌥⇧1–9` | 唤起对应顺序的站点 |

右键菜单还可以新建站点、维护预设、切换图标模式、静音、在默认浏览器打开以及设置登录启动。

## 权限与隐私

- 登录状态和站点配置保存在本机，不上传到 TabNest 服务；项目本身不包含远程后端。
- 所有 WebView 使用系统 `WKWebsiteDataStore` 保存 Cookie 和网站数据。
- 网页只能从 HTTPS 来源申请麦克风；每次请求都会显示来源确认，摄像头请求默认拒绝。
- 麦克风系统授权可在“系统设置 → 隐私与安全性 → 麦克风”中撤销。
- 网页尝试唤起未安装的外部 App Scheme 时会被拦截，避免出现系统 URL 弹窗。

## 从源码构建

需要 macOS 13 或更高版本，以及 Swift 5.9 或更高版本。可以安装 Xcode 15 或更新版本，也可以先安装 Xcode Command Line Tools：

```bash
xcode-select --install
swift --version
```

克隆项目并运行测试：

```bash
git clone https://github.com/liangix/TabNest.git
cd TabNest

swift test
```

测试建议使用完整 Xcode（包含 XCTest）。无桌面会话的 CI 使用 `CI=true swift test`，会跳过菜单栏窗口生命周期测试。通知集成测试默认跳过，在已登录的本机桌面中可额外运行：

```bash
TABNEST_NOTIFICATION_INTEGRATION=1 swift test --filter WebNotificationTests
```

该测试使用独立临时配置和本地回环网页，短暂显示测试图标、授权弹窗及提醒，结束后清理，不修改实际站点配置。

开发模式直接运行：

```bash
swift run
```

构建标准 macOS 应用并安装到“应用程序”：

```bash
./scripts/make_app.sh release
ditto "dist/TabNest.app" "/Applications/TabNest.app"
open "/Applications/TabNest.app"
```

本地构建使用 ad-hoc 签名，适合在自己的 Mac 上运行和调试，不适合作为已公证版本向其他用户分发。

构建通用架构 DMG：

```bash
TABNEST_VERSION=1.0.2 ./scripts/make_dmg.sh release
```

输出文件：

- `dist/TabNest-1.0.2.dmg`
- `dist/TabNest-1.0.2.dmg.sha256`

两个文件位于同一目录时可验证下载完整性：

```bash
shasum -a 256 -c TabNest-1.0.2.dmg.sha256
```

## Release 流水线

`.github/workflows/release.yml` 在推送 `v*` 版本标签时自动执行：

1. 运行完整测试；
2. 构建 Apple Silicon + Intel 通用应用；
3. 生成并验证压缩 DMG；
4. 生成 SHA-256 校验文件；
5. 创建 GitHub Release 并上传两个文件。

```bash
git tag v1.0.2
git push origin v1.0.2
```

也可以从 GitHub Actions 页面手动运行，并指定符合语义化版本格式的标签。

## 项目结构

```text
.
├── Package.swift
├── Resources/AppIcon.png
├── Sources/MenuBarBrowser/       # AppKit / WebKit / SwiftUI 应用源码
├── Tests/MenuBarBrowserTests/    # 模型、WebView 生命周期与资源处理测试
├── scripts/make_app.sh           # 生成并签名 .app
├── scripts/make_dmg.sh           # 生成通用架构 DMG 与校验文件
└── .github/workflows/release.yml # GitHub Release 流水线
```

## License

[MIT](LICENSE)
