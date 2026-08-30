# TabNest — Menu Bar Browser

原生 macOS 菜单栏浏览器：打开的 Tab 可以展开为各自的 favicon 图标，也可以收拢为一个应用图标；点击后在图标正下方弹出带连接箭头的网页浮窗。无浏览器 chrome、不抢焦点、登录态持久保存。

纯 Swift 实现，**AppKit + WebKit + SwiftUI**，零第三方依赖。

![tech](https://img.shields.io/badge/macOS-13%2B-black) ![swift](https://img.shields.io/badge/Swift-5.9-orange)

## 交互模型

```
菜单栏:   [🅖 GitHub] [🎵 YT Music] [🤖 ChatGPT]      ← 每站点一个 favicon 图标
              │(左键)        │            │
              ▼              ▼            ▼
          ┌────────┐    ┌────────┐
          │▲箭头    │    │▲       │                ← 箭头标记面板归属哪个图标
          │ webpage│    │webpage │                ← 面板内纯网页，可多开并存
          └────────┘    └────────┘
```

- **左键图标**：弹出 / 收起该站点的浮动面板（多个面板可同时打开）
- **右键（或 ⌥+左键）**：该站点的完整操作菜单
- **图标模式**：支持“每个 Tab 一个图标”和“全部 Tab 收拢为一个图标”
- **全局快捷键**：默认使用 ⌥⇧1–9，也可为每个站点录入任意组合键或关闭
- **点击面板外部**：自动收起所有面板（可在菜单关闭）
- 无站点时显示占位图标，右键即可「新建站点」

## 功能

- 每站点独立面板：位置/大小按站点记忆，常驻 WebView 切换零状态丢失
- 预设站点与打开的 Tab 分离：关闭 Tab 不删除预设，可随时从预设管理器重新打开
- favicon 图标自动抓取（页面 icon → `/favicon.ico` 回退），失败时首字母色块占位
- 登录态持久化（共享 WKWebsiteDataStore）
- 浏览器标识：系统 / 桌面 / 移动端 / 自定义 UA
- 自动刷新（30s / 1min / 5min）、静音、强制刷新、在默认浏览器打开
- 面板内快捷键：`Esc`/`⌘W` 关闭 · `⌘R` 刷新 · `⇧⌘R` 强刷 · `⌘[`/`⌘]` 前进后退 · ⌘+滚轮缩放
- 每站点快捷键可设为自动 / 自定义 / 关闭，基于 Carbon HotKey，无需辅助功能权限
- 登录自启（SMAppService）

## 构建与运行

```bash
swift run                        # 开发调试
./scripts/make_app.sh            # 打包 .app（release + ad-hoc 签名）
open dist/TabNest.app
cp -R dist/TabNest.app /Applications/          # 可选安装
```

> 「登录时启动」需应用位于 `/Applications` 才能稳定生效。

## 项目结构

```
MenuBarBrowser/
├── Package.swift                     # SwiftPM，macOS 13+
├── Sources/MenuBarBrowser/
│   ├── main.swift                    # 入口（accessory 模式）+ mbbTrace 诊断日志
│   ├── AppDelegate.swift             # 组装、Edit 菜单、开机自启、首启引导
│   ├── StatusItemManager.swift       # 多图标管理：favicon 渲染、左右键分发、右键菜单
│   ├── WindowManager.swift           # 站点窗口注册表：懒创建、点击外部隐藏、快捷键分发
│   ├── PinWindowController.swift     # 单站点窗口单元：面板+箭头+常驻 WebView+动作
│   ├── PinWindow.swift               # BrowserPanel（非激活 key panel）+ ArrowView
│   ├── HotkeyManager.swift           # Carbon 全局快捷键注册与分发
│   ├── HotkeyRecorder.swift          # 快捷键录入控件
│   ├── FaviconCache.swift            # favicon 异步加载缓存与占位图渲染
│   ├── FormWindow.swift              # 添加/编辑/关于 的独立小窗口
│   ├── PresetManagerView.swift       # 预设站点查看、打开、编辑与删除
│   ├── WebTabController.swift        # 单个 WKWebView 封装：KVO、UA、favicon 抓取、静音
│   ├── PinStore.swift                # 站点列表持久化
│   ├── SettingsStore.swift           # 应用设置持久化
│   ├── Models.swift                  # Pin / TabState / AppSettings
│   ├── PanelViews.swift              # 面板根视图（纯网页+进度条）、关于页
│   └── PinFormView.swift             # 添加/编辑站点与快捷键配置表单
├── Tests/MenuBarBrowserTests/         # 模型与持久化单元测试
└── scripts/make_app.sh               # .app 打包脚本
```

### 关键设计

| 问题 | 方案 |
|---|---|
| 弹出不抢焦点 | `NSPanel(.nonactivatingPanel)` 子类化 `canBecomeKey` |
| 面板归属标识 | 单一连续轮廓蒙版内嵌圆润箭头，尖端补偿圆角偏移后贴近图标 |
| 箭头颜色融合 | JS 采样页面顶部背景色（rgb/hex，DOM 上溯）动态渲染底色 |
| 一 Tab 一面板 | `WindowManager` 按 pinID 懒创建控制器；关闭 Tab 时释放，预设继续保留 |
| 单/多图标 | `StatusItemManager` 在应用图标与每 Tab favicon 之间切换并重新绑定面板锚点 |
| 图标页面样式 | FaviconCache 异步抓取 → NSStatusBarButton.image |
| 全局快捷键 | 每站点持久化配置；Carbon RegisterEventHotKey，C 回调经 Task@MainActor 转发 |
| 探入菜单栏 | 重写 `constrainFrameRect` 解除系统钳制 |

## Roadmap

- [ ] 每站点独立数据存储（Cookie 隔离）
- [ ] 页面内查找
- [ ] DMG 发布流水线

## License

MIT
