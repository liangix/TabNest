import AppKit
import SwiftUI

/// 单个固定站点的完整窗口单元：菜单栏图标 ⇄ 带箭头的浮动面板 ⇄ 常驻 WebView。
@MainActor
final class PinWindowController: NSObject {
    let pinID: UUID
    let panel: BrowserPanel
    let webTab: WebTabController
    let panelModel: PinPanelModel

    /// 顶部箭头区高度；主体从该位置开始。
    static let topInset = PopoverGeometry.topInset

    private let glassRoot = GlassPanelRootView(frame: NSRect(x: 0, y: 0, width: 560, height: 694))
    private let dragZone = ArrowDragZone(frame: NSRect(x: 235, y: 0, width: 90, height: 12))
    private let backdropView = PanelBackdrop.make()
    private let resizeOverlay = ResizeOverlayView(frame: .zero)
    private weak var hostingView: NSHostingView<AnyView>?
    private weak var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var currentPin: Pin
    private var isAnchoringResize = false
    private var isClosed = false

    var isVisible: Bool { panel.isVisible }

    func updateStatusItem(_ item: NSStatusItem) {
        statusItem = item
        if isVisible {
            placeUnderStatusItem(resetSize: false)
            alignArrow()
        }
    }

    init(pin: Pin, statusItem: NSStatusItem, pinStore: PinStore? = nil) {
        self.pinID = pin.id
        self.statusItem = statusItem
        self.currentPin = pin
        let webTab = WebTabController(pin: pin, notificationStore: pinStore)
        self.webTab = webTab
        self.panelModel = PinPanelModel(webView: webTab.webView)

        panel = BrowserPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680 + Self.topInset),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear          // 形状完全由自绘视图决定
        panel.hasShadow = true                  // 阴影跟随自绘内容轮廓
        panel.minSize = NSSize(width: 340, height: 260 + Self.topInset)
        panel.identifier = NSUserInterfaceItemIdentifier("pin-\(pin.id)")

        // 仅用于持久化面板尺寸（位置每次停靠时重算）
        panel.setFrameAutosaveName("Panel-\(pin.id.uuidString)")

        // 内容布局：Liquid Glass 背景（含箭头轮廓）+ 网页主体，无任何浏览器 chrome
        guard let contentView = panel.contentView else { return }
        glassRoot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(glassRoot)

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        glassRoot.addSubview(backdropView)

        let hosting = NSHostingView(rootView: AnyView(PinPanelRootView(model: panelModel)))
        hostingView = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = GlassPanelRootView.cornerRadius   // 双保险：网页自身也按圆角裁剪
        hosting.layer?.masksToBounds = true
        glassRoot.addSubview(hosting)

        dragZone.frame = CGRect(x: 235, y: 0, width: 90, height: GlassPanelRootView.topInset)
        glassRoot.addSubview(dragZone)

        resizeOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resizeOverlay, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            glassRoot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            glassRoot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            glassRoot.topAnchor.constraint(equalTo: contentView.topAnchor),
            glassRoot.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            backdropView.leadingAnchor.constraint(equalTo: glassRoot.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: glassRoot.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: glassRoot.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: glassRoot.bottomAnchor),

            hosting.leadingAnchor.constraint(equalTo: glassRoot.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glassRoot.trailingAnchor),
            // 视口从箭头基线开始：页面内容零缺失
            hosting.topAnchor.constraint(equalTo: glassRoot.topAnchor, constant: Self.topInset),
            hosting.bottomAnchor.constraint(equalTo: glassRoot.bottomAnchor),

            resizeOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            resizeOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            resizeOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            resizeOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        webTab.onUpdate = { [weak self] in self?.refreshState() }
        panelModel.onRetry = { [weak self] in self?.hardReload() }
        webTab.notificationBridge.onPermissionRequestChanged = { [weak self] request in
            self?.panelModel.permissionRequest = request
        }
        panelModel.onPermissionDecision = { [weak self] id, permission in
            self?.webTab.notificationBridge.resolvePermissionRequest(id: id, permission: permission)
        }
        // 页面背景色采样 → 箭头底色融合
        webTab.onPageBackgroundColor = { [weak self] color in
            guard let self,
                  let solid = self.backdropView as? SolidBackdropView else { return }
            solid.fillColor = color ?? .windowBackgroundColor
        }
        refreshState()

        panel.onEscape = { [weak self] in self?.hide() }
        panel.onReload = { [weak self] in self?.reload() }
        panel.onHardReload = { [weak self] in self?.hardReload() }
        panel.onBack = { [weak self] in self?.goBack() }
        panel.onForward = { [weak self] in self?.goForward() }
        panel.onZoomIn = { [weak self] in self?.zoomIn() }
        panel.onZoomOut = { [weak self] in self?.zoomOut() }
        panel.onResetZoom = { [weak self] in self?.resetZoom() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.alignArrow() }
        })
        observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.anchorAfterResize()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.anchorDuringResize()
            }
        })
    }

    func syncPin(_ pin: Pin) {
        let oldPin = currentPin
        currentPin = pin
        webTab.updateNotificationSettings(for: pin)
        let userAgentChanged = webTab.applyUserAgent(for: pin)
        webTab.updateAutoRefresh(interval: pin.refreshInterval)
        webTab.setPageZoom(pin.pageZoom)
        webTab.setMuted(pin.isMuted)
        panel.title = pin.name

        if oldPin.canonicalURLString != pin.canonicalURLString, let url = pin.url {
            if userAgentChanged {
                webTab.reloadApplyingUserAgent(for: pin, targetURL: url)
            } else {
                webTab.navigate(to: url)
            }
        } else if userAgentChanged {
            webTab.reloadApplyingUserAgent(for: pin)
        }
    }

    func show() {
        // 始终停靠到所属图标正下方（跟随图标所在屏幕），仅保留记忆中的尺寸
        placeUnderStatusItem(resetSize: false)
        alignArrow()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        statusItem?.button?.highlight(true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let window = self.webTab.webView.window else { return }
            window.makeFirstResponder(self.webTab.webView)
        }
    }

    func hide() {
        webTab.notificationBridge.cancelPermissionRequest()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                self.statusItem?.button?.highlight(false)
            }
        })
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// 面板显示/移动后，重算箭头顶点对齐所属图标的中心。
    private func alignArrow() {
        guard let iconFrame = statusItem?.button?.window?.frame else {
            glassRoot.arrowX = 0
            return
        }
        glassRoot.arrowX = PopoverGeometry.arrowPosition(anchorX: iconFrame.midX, frame: panel.frame)

        // 拖拽热区只覆盖箭头附近，避免挡住网页顶部内容
        dragZone.frame = CGRect(x: glassRoot.arrowX - 45, y: 0,
                                width: 90, height: GlassPanelRootView.topInset)
    }

    private func anchorDuringResize() {
        guard !isAnchoringResize else { return }
        isAnchoringResize = true
        placeUnderStatusItem(resetSize: false)
        alignArrow()
        isAnchoringResize = false
    }

    private func anchorAfterResize() {
        guard !isAnchoringResize else { return }
        isAnchoringResize = true
        placeUnderStatusItem(resetSize: false)
        alignArrow()
        isAnchoringResize = false
    }

    /// 停靠到所属图标正下方：跟随图标所在屏幕，
    /// 顶部上探进菜单栏（tuck），使箭头尖端尽可能贴近图标。
    private func placeUnderStatusItem(resetSize: Bool) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              // 优先使用图标所在的屏幕，而非主屏幕
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let iconFrame = buttonWindow.frame
        var size = resetSize ? NSSize(width: 560, height: 680 + Self.topInset) : panel.frame.size
        size.width = max(size.width, panel.minSize.width)
        size.height = max(size.height, panel.minSize.height)
        size.width = min(size.width, max(panel.minSize.width, screen.visibleFrame.width - 16))
        size.height = min(size.height, max(panel.minSize.height, screen.visibleFrame.height))

        panel.setFrame(PopoverGeometry.anchoredFrame(size: size, anchor: iconFrame,
                                                   visibleFrame: screen.visibleFrame), display: true)
    }

    func closeForRemoval() {
        guard !isClosed else { return }
        isClosed = true
        panel.orderOut(nil)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        webTab.stop()
        panel.onEscape = nil
        panel.onReload = nil
        panel.onHardReload = nil
        panel.onBack = nil
        panel.onForward = nil
        panel.onZoomIn = nil
        panel.onZoomOut = nil
        panel.onResetZoom = nil
        hostingView?.rootView = AnyView(EmptyView())
        panelModel.onRetry = nil
        panelModel.onPermissionDecision = nil
        hostingView?.removeFromSuperview()
        hostingView = nil
        glassRoot.subviews.forEach { $0.removeFromSuperview() }
        // NSWindow 强持有 contentView；先解除 SwiftUI 观察和视图层级，
        // 再清空窗口内容，确保 panel/model/webView 可一起释放。
        panel.contentView = nil
        panel.close()
    }

    // MARK: - 页面动作（供菜单/快捷键调用）

    func reload()      { webTab.webView.reload() }
    func hardReload()  { webTab.reloadApplyingUserAgent(for: currentPin) }
    func clearCacheAndReload() { webTab.clearCacheAndReload(for: currentPin) }
    func goBack()      { webTab.webView.goBack() }
    func goForward()   { webTab.webView.goForward() }

    func zoomIn()    { updatePageZoom(PageZoom.increased(currentPin.pageZoom)) }
    func zoomOut()   { updatePageZoom(PageZoom.decreased(currentPin.pageZoom)) }
    func resetZoom() { updatePageZoom(PageZoom.defaultValue) }

    private func updatePageZoom(_ value: Double) {
        let normalized = PageZoom.normalized(value)
        guard normalized != currentPin.pageZoom else { return }
        var pin = currentPin
        pin.pageZoom = normalized
        PinStore.shared.update(pin)
    }

    func goHome() {
        guard let url = currentPin.url else { return }
        webTab.webView.load(URLRequest(url: url))
    }

    func openExternal() {
        guard let url = webTab.webView.url ?? currentPin.url else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleMute() {
        var pin = currentPin
        pin.isMuted.toggle()
        PinStore.shared.update(pin)
    }

    private func refreshState() {
        let wv = webTab.webView
        panelModel.state = TabState(
            title: wv.title?.isEmpty == false ? wv.title! : (wv.url?.host ?? L10n.text(.loading)),
            urlString: wv.url?.absoluteString ?? "",
            isLoading: wv.isLoading || webTab.isClearingCache,
            progress: webTab.isClearingCache ? 0 : wv.estimatedProgress,
            canGoBack: wv.canGoBack,
            canGoForward: wv.canGoForward,
            loadErrorMessage: webTab.loadErrorMessage
        )
    }

}
