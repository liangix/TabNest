import AppKit
import SwiftUI

/// Status items briefly have a zero-height window while AppKit lays out the menu bar.
struct StatusItemAnchor {
    let frame: NSRect
    let visibleFrame: NSRect

    @MainActor
    static func resolve(_ item: NSStatusItem) -> StatusItemAnchor? {
        guard let window = item.button?.window, let screen = window.screen,
              window.frame.width > 0, window.frame.height > 0,
              window.frame.intersects(screen.frame) else { return nil }
        return StatusItemAnchor(frame: window.frame, visibleFrame: screen.visibleFrame)
    }
}

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
    private let arrowBackdrop = AdaptiveArrowBackdropView(frame: .zero)
    private var backgroundSamplingTimer: Timer?
    private let resizeOverlay = ResizeOverlayView(frame: .zero)
    private weak var hostingView: NSHostingView<AnyView>?
    private weak var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var currentPin: Pin
    private var isAnchoringResize = false
    private var isClosed = false
    private let anchorProvider: @MainActor (NSStatusItem) -> StatusItemAnchor?
    private var anchorRetry: DispatchWorkItem?
    private var presentationRevision = 0
    private(set) var wantsVisible = false

    var isVisible: Bool { panel.isVisible }

    func updateStatusItem(_ item: NSStatusItem) {
        statusItem?.button?.highlight(false)
        statusItem = item
        refreshAnchor()
    }

    init(pin: Pin, statusItem: NSStatusItem, pinStore: PinStore? = nil,
         anchorProvider: @escaping @MainActor (NSStatusItem) -> StatusItemAnchor? = StatusItemAnchor.resolve) {
        self.pinID = pin.id
        self.statusItem = statusItem
        self.currentPin = pin
        self.anchorProvider = anchorProvider
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
        arrowBackdrop.translatesAutoresizingMaskIntoConstraints = false
        glassRoot.addSubview(arrowBackdrop)

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
            backdropView.topAnchor.constraint(equalTo: glassRoot.topAnchor, constant: Self.topInset),
            backdropView.bottomAnchor.constraint(equalTo: glassRoot.bottomAnchor),

            arrowBackdrop.leadingAnchor.constraint(equalTo: glassRoot.leadingAnchor),
            arrowBackdrop.trailingAnchor.constraint(equalTo: glassRoot.trailingAnchor),
            arrowBackdrop.topAnchor.constraint(equalTo: glassRoot.topAnchor),
            arrowBackdrop.heightAnchor.constraint(equalToConstant: Self.topInset),

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
            self?.arrowBackdrop.pageColor = color
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
        // Follow the icon after initial layout, menu-bar reordering and display changes.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow,
                          window === self.statusItem?.button?.window else { return }
                    self.refreshAnchor()
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAnchor() }
        })
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
        guard !isClosed else { return }
        presentationRevision += 1
        wantsVisible = true
        refreshAnchor()
    }

    private func refreshAnchor(attempt: Int = 0) {
        guard wantsVisible, !isClosed else { return }
        anchorRetry?.cancel()
        anchorRetry = nil
        // 始终停靠到所属图标正下方（跟随图标所在屏幕），仅保留记忆中的尺寸
        guard placeUnderStatusItem(resetSize: false) else {
            // Never expose the initial (0, 0) frame or an obsolete icon's position.
            panel.orderOut(nil)
            stopBackgroundSampling()
            guard attempt < 100 else {
                wantsVisible = false
                statusItem?.button?.highlight(false)
                return
            }
            let retry = DispatchWorkItem { [weak self] in self?.refreshAnchor(attempt: attempt + 1) }
            anchorRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
            return
        }
        alignArrow()
        statusItem?.button?.highlight(true)
        // Re-anchoring an already visible window must not restart its fade-in.
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        startBackgroundSampling()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.wantsVisible, !self.isClosed, self.panel.isVisible,
                  let window = self.webTab.webView.window else { return }
            window.makeFirstResponder(self.webTab.webView)
        }
    }

    func hide() {
        stopBackgroundSampling()
        wantsVisible = false
        presentationRevision += 1
        let revision = presentationRevision
        anchorRetry?.cancel()
        anchorRetry = nil
        statusItem?.button?.highlight(false)
        webTab.notificationBridge.cancelPermissionRequest()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.presentationRevision == revision else { return }
                self.panel.orderOut(nil)
                self.statusItem?.button?.highlight(false)
            }
        })
    }

    func toggle() {
        if wantsVisible {
            hide()
        } else {
            show()
        }
    }

    /// 面板显示/移动后，重算箭头顶点对齐所属图标的中心。
    private func alignArrow() {
        guard let item = statusItem, let iconFrame = anchorProvider(item)?.frame else {
            glassRoot.arrowX = 0
            return
        }
        glassRoot.arrowX = PopoverGeometry.arrowPosition(anchorX: iconFrame.midX, frame: panel.frame)
        webTab.backgroundSampleXFraction = glassRoot.arrowX / max(panel.frame.width, 1)

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
    @discardableResult
    private func placeUnderStatusItem(resetSize: Bool) -> Bool {
        guard let item = statusItem, let anchor = anchorProvider(item) else { return false }
        let iconFrame = anchor.frame
        var size = resetSize ? NSSize(width: 560, height: 680 + Self.topInset) : panel.frame.size
        size.width = max(size.width, panel.minSize.width)
        size.height = max(size.height, panel.minSize.height)
        size.width = min(size.width, max(panel.minSize.width, anchor.visibleFrame.width - 16))
        size.height = min(size.height, max(panel.minSize.height, anchor.visibleFrame.height))

        panel.setFrame(PopoverGeometry.anchoredFrame(size: size, anchor: iconFrame,
                                                   visibleFrame: anchor.visibleFrame), display: true)
        return true
    }

    func closeForRemoval() {
        guard !isClosed else { return }
        isClosed = true
        stopBackgroundSampling()
        wantsVisible = false
        presentationRevision += 1
        anchorRetry?.cancel()
        anchorRetry = nil
        statusItem?.button?.highlight(false)
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

    private func startBackgroundSampling() {
        guard backgroundSamplingTimer == nil else { return }
        webTab.setBackgroundTrackingEnabled(true)
        webTab.samplePageBackgroundColor()
        // Events handle scrolling/theme changes; low-frequency reads cover unobservable CSS changes.
        let timer = Timer(timeInterval: PageAppearanceObserver.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsVisible, self.panel.isVisible else { return }
                self.webTab.samplePageBackgroundColor()
            }
        }
        timer.tolerance = 0.3
        backgroundSamplingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopBackgroundSampling() {
        webTab.setBackgroundTrackingEnabled(false)
        backgroundSamplingTimer?.invalidate()
        backgroundSamplingTimer = nil
    }

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
