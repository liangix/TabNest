import AppKit
import WebKit

/// 单个站点的 WKWebView 封装：负责导航代理、UA、favicon 抓取与状态回调。
@MainActor
final class WebTabController: NSObject {
    let pinID: UUID
    let webView: WKWebView
    var autoRefreshTimer: Timer?

    /// 状态变化时回调（主线程）
    var onUpdate: (() -> Void)?

    /// 页面顶部背景色采样完成回调（用于箭头底色融合）
    var onPageBackgroundColor: ((NSColor?) -> Void)?

    private var observers: [NSKeyValueObservation] = []
    private var pendingIconSignature: String = ""
    private var faviconExtractionWorkItem: DispatchWorkItem?
    private var currentRefreshInterval: TimeInterval = 0
    private var isMuted = false
    /// 取消尚未提交的延迟导航，避免连续编辑 UA/地址时旧请求覆盖最新配置。
    private var navigationRevision: UInt = 0
    private(set) var isStopped = false

    init(pin: Pin) {
        self.pinID = pin.id

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 登录态/cookie 持久化
        Self.installUserScripts(on: config.userContentController, muted: pin.isMuted)

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(true, forKey: "allowsMagnification") // ⌘+滚轮缩放页面
        applyUserAgent(for: pin)
        setPageZoom(pin.pageZoom)

        if let url = pin.url {
            webView.load(URLRequest(url: url))
        }

        observers.append(webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.onUpdate?()
                self?.scheduleFaviconExtraction(after: 0.25)
            }
        })
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.pendingIconSignature = ""
                self?.onUpdate?()
                self?.scheduleFaviconExtraction(after: 0.25)
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onUpdate?() }
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onUpdate?() }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onUpdate?() }
        })
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onUpdate?() }
        })
        isMuted = pin.isMuted
        scheduleAutoRefresh(interval: pin.refreshInterval)
    }

    /// 应用站点 UA，并返回本次是否实际发生变化。
    @discardableResult
    func applyUserAgent(for pin: Pin) -> Bool {
        let target = UserAgentStrings.userAgent(for: pin)
        guard webView.customUserAgent != target else { return false }
        webView.customUserAgent = target
        return true
    }

    func updateAutoRefresh(interval: TimeInterval) {
        scheduleAutoRefresh(interval: interval)
    }

    func setPageZoom(_ value: Double) {
        webView.pageZoom = CGFloat(PageZoom.normalized(value))
    }

    /// 静音当前页面媒体元素，并注入脚本保证后续导航保持静音。
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        let contentController = webView.configuration.userContentController
        Self.installUserScripts(on: contentController, muted: muted)
        let js = "window.__mbbMuted = \(muted ? "true" : "false"); window.__mbbApplyMuted && window.__mbbApplyMuted();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func installUserScripts(on controller: WKUserContentController, muted: Bool) {
        controller.removeAllUserScripts()
        controller.addUserScript(externalAppBlockingUserScript())
        controller.addUserScript(muteUserScript(muted: muted))
    }

    /// 在页面脚本处理点击之前阻止 App Scheme，避免 WebKit 把请求交给 LaunchServices
    /// 后弹出“未设定用来打开该 URL 的应用程序”。原生导航代理仍作为第二道防线。
    private static func externalAppBlockingUserScript() -> WKUserScript {
        let source = #"""
        (function(){
          if (window.__tabNestExternalSchemeGuardInstalled) return;
          window.__tabNestExternalSchemeGuardInstalled = true;

          const allowed = new Set(['http:', 'https:', 'about:', 'blob:', 'data:', 'javascript:']);
          function isAllowed(raw) {
            if (raw == null || raw === '') return true;
            const value = String(raw).trim();
            if (!value || value[0] === '#') return true;
            try {
              return allowed.has(new URL(value, document.baseURI).protocol.toLowerCase());
            } catch (_) {
              return false;
            }
          }

          function blockLinkEvent(event) {
            const element = event.target instanceof Element
              ? event.target.closest('a[href], area[href]') : null;
            if (!element || isAllowed(element.getAttribute('href'))) return;
            event.preventDefault();
            event.stopImmediatePropagation();
          }

          document.addEventListener('click', blockLinkEvent, true);
          document.addEventListener('auxclick', blockLinkEvent, true);
          document.addEventListener('submit', function(event) {
            const submitterAction = event.submitter && event.submitter.getAttribute
              ? event.submitter.getAttribute('formaction') : null;
            const formAction = event.target && event.target.getAttribute
              ? event.target.getAttribute('action') : null;
            if (isAllowed(submitterAction || formAction)) return;
            event.preventDefault();
            event.stopImmediatePropagation();
          }, true);

          const nativeOpen = window.open;
          window.open = function(url) {
            if (!isAllowed(url)) return null;
            return nativeOpen.apply(window, arguments);
          };
        })();
        """#
        return WKUserScript(source: source, injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }

    private static func muteUserScript(muted: Bool) -> WKUserScript {
        let source = """
        (function(){
          window.__mbbMuted = \(muted ? "true" : "false");
          window.__mbbApplyMuted = function(){
            document.querySelectorAll('video,audio').forEach(function(el){
              el.muted = !!window.__mbbMuted;
            });
          };
          function start(){
            window.__mbbApplyMuted();
            if (!window.__mbbMuteObserver) {
              window.__mbbMuteObserver = new MutationObserver(window.__mbbApplyMuted);
              window.__mbbMuteObserver.observe(document.documentElement, {childList:true, subtree:true});
            }
          }
          if (document.documentElement) start();
          else document.addEventListener('DOMContentLoaded', start, {once:true});
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private func scheduleAutoRefresh(interval: TimeInterval) {
        guard interval != currentRefreshInterval || autoRefreshTimer == nil else { return }
        currentRefreshInterval = interval
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        guard interval > 0 else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return } // 仅刷新当前可见标签
                self.webView.reload()
            }
        }
    }

    var isVisible: Bool {
        webView.window?.isVisible == true && !webView.isHidden
    }

    /// 重新应用目标 UA，再用新的无缓存主导航请求载入当前页面。
    ///
    /// `reloadFromOrigin()` 仍会重用“当前导航”的语义，并允许条件缓存校验；UA 刚改变时
    /// WebKit 可能继续使用旧导航上下文。这里停止旧导航，并延迟到下一主线程周期重新
    /// `load(URLRequest)`，确保请求头和页面中的 navigator.userAgent 同时来自新配置。
    func reloadApplyingUserAgent(for pin: Pin, targetURL: URL? = nil) {
        applyUserAgent(for: pin)
        guard let url = targetURL ?? webView.url ?? pin.url else { return }
        loadFresh(url)
    }

    func navigate(to url: URL) {
        navigationRevision &+= 1
        pendingIconSignature = ""
        webView.load(URLRequest(url: url))
    }

    static func freshRequest(for url: URL) -> URLRequest {
        URLRequest(url: url,
                   cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                   timeoutInterval: 60)
    }

    private func loadFresh(_ url: URL) {
        navigationRevision &+= 1
        let revision = navigationRevision
        pendingIconSignature = ""
        webView.stopLoading()

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isStopped,
                  self.navigationRevision == revision else { return }
            self.webView.load(Self.freshRequest(for: url))
        }
    }

    static func isAllowedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "blob", "data"].contains(scheme)
    }

    /// 采样页面顶部中心的实际背景色（沿 DOM 向上找第一个不透明背景）。
    func samplePageBackgroundColor() {
        let js = """
        (function(){
          function solid(c){
            if(!c || c === 'transparent') return null;
            if(c[0] === '#') return c;
            var m = c.match(/rgba?\\(([^)]+)\\)/);
            if(!m) return null;
            var p = m[1].split(',').map(parseFloat);
            if(p.length >= 3 && (p.length < 4 || p[3] > 0)) return 'rgb(' + p[0] + ',' + p[1] + ',' + p[2] + ')';
            return null;
          }
          var el = document.elementFromPoint(window.innerWidth / 2, 3);
          var n = el;
          while(n){
            var v = solid(getComputedStyle(n).backgroundColor);
            if(v) return v;
            n = n.parentElement;
          }
          return null;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let css = result as? String else {
                DispatchQueue.main.async { self?.onPageBackgroundColor?(nil) }
                return
            }
            let color = Self.color(fromCSS: css)
            DispatchQueue.main.async { self?.onPageBackgroundColor?(color) }
        }
    }

    /// 解析 CSS 颜色字符串（支持 rgb/rgba/#hex）
    static func color(fromCSS css: String) -> NSColor? {
        let s = css.replacingOccurrences(of: " ", with: "").lowercased()

        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 {
                hex = hex.map { "\($0)\($0)" }.joined()
            }
            guard hex.count == 6 || hex.count == 8,
                  let rgb = UInt64(hex.prefix(6), radix: 16) else { return nil }
            let r = CGFloat((rgb >> 16) & 0xFF) / 255
            let g = CGFloat((rgb >> 8) & 0xFF) / 255
            let b = CGFloat(rgb & 0xFF) / 255
            var a: CGFloat = 1
            if hex.count == 8, let av = UInt64(hex.suffix(2), radix: 16) {
                a = CGFloat(av) / 255
            }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }

        if s.hasPrefix("rgb") {
            let inner = s.drop { $0 != "(" }.dropFirst().dropLast()
            let parts = inner.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 3 else { return nil }
            let alpha = parts.count > 3 ? min(max(parts[3], 0), 1) : 1
            return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255,
                           blue: parts[2] / 255, alpha: alpha)
        }

        return nil
    }

    /// 页面加载完成后抓取站点图标地址，写回 PinStore。
    func extractFavicon() {
        let js = """
        (function(){
          function score(link) {
            const rel = (link.rel || '').toLowerCase().split(/\\s+/);
            let value = rel.includes('icon') ? 100 : 20;
            if ((link.type || '').toLowerCase().includes('svg') || /\\.svg(?:$|[?#])/i.test(link.href)) value -= 25;
            else value += 10;
            const sizes = (link.sizes && link.sizes.value || '').toLowerCase();
            if (sizes === 'any') value += 20;
            else {
              const width = parseInt(sizes, 10);
              if (Number.isFinite(width)) value += Math.max(0, 20 - Math.abs(width - 32));
            }
            return value;
          }
          const links = Array.from(document.querySelectorAll('link[rel*="icon"]'))
            .filter(l => {
              const rel = (l.rel || '').toLowerCase().split(/\\s+/);
              return l.href && (rel.includes('icon') || rel.includes('apple-touch-icon'));
            }).sort((a, b) => score(b) - score(a));
          return links.map(link => new URL(link.href, document.baseURI).toString())
            .filter((href, index, all) => all.indexOf(href) === index);
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let urlStrings = result as? [String],
                  !urlStrings.isEmpty else { return }
            let signature = urlStrings.joined(separator: "\n")
            guard signature != self.pendingIconSignature else { return }
            self.pendingIconSignature = signature
            DispatchQueue.main.async {
                FaviconCache.shared.refresh(pinID: self.pinID,
                                             candidateURLStrings: urlStrings)
            }
        }
    }

    private func scheduleFaviconExtraction(after delay: TimeInterval) {
        faviconExtractionWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.extractFavicon() }
        faviconExtractionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        navigationRevision &+= 1

        observers.forEach { $0.invalidate() }
        observers.removeAll()
        faviconExtractionWorkItem?.cancel()
        faviconExtractionWorkItem = nil
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        onUpdate = nil
        onPageBackgroundColor = nil

        // 关闭 Tab 的语义是销毁页面，而非仅隐藏窗口。先使用 WebKit 的媒体 API
        // 立即终止音频、视频、全屏和画中画，再停止网络并清空页面作为兜底。
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("<!doctype html><meta charset=\"utf-8\">", baseURL: nil)
        webView.removeFromSuperview()
    }
}

extension WebTabController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decide policy: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = policy.request.url, !Self.isAllowedWebURL(url) {
            mbbTrace("已阻止网页唤起外部 App：\(url.scheme ?? "unknown")")
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onUpdate?()
        extractFavicon()
        samplePageBackgroundColor()
        // SPA 页面样式常延迟应用，稍后补采一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.samplePageBackgroundColor()
            self?.extractFavicon()
        }
        // 部分站点在页面框架加载完成后才异步写入 favicon。
        scheduleFaviconExtraction(after: 3.0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onUpdate?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        onUpdate?()
    }
}

extension WebTabController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        // 仅开放用户要求的麦克风录音。摄像头或组合请求不在本次授权范围内。
        guard type == .microphone else {
            decisionHandler(.deny)
            return
        }

        let scheme = origin.protocol.lowercased()
        let host = origin.host.lowercased()
        let isLocalhost = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocalhost) else {
            decisionHandler(.deny)
            return
        }

        let port = origin.port > 0 ? ":\(origin.port)" : ""
        let source = "\(scheme)://\(origin.host)\(port)"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(.microphonePermissionTitle)
        alert.informativeText = L10n.text(.microphonePermissionMessage, source)
        alert.addButton(withTitle: L10n.text(.commonAllow))
        alert.addButton(withTitle: L10n.text(.commonDeny))
        decisionHandler(alert.runModal() == .alertFirstButtonReturn ? .grant : .deny)
    }

    // target="_blank" 的链接直接在当前标签打开
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if Self.isAllowedWebURL(url) {
                webView.load(URLRequest(url: url))
            } else {
                mbbTrace("已阻止新窗口唤起外部 App：\(url.scheme ?? "unknown")")
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? L10n.text(.webMessageTitle)
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text(.commonOK))
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L10n.text(.commonOK))
        alert.addButton(withTitle: L10n.text(.commonCancel))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.text(.commonOK))
        alert.addButton(withTitle: L10n.text(.commonCancel))
        let ok = alert.runModal() == .alertFirstButtonReturn
        completionHandler(ok ? input.stringValue : nil)
    }
}

enum UserAgentStrings {
    /// macOS WKWebView 的原生 UA 缺少 Safari `Version/` 标识，部分站点会把冻结的
    /// AppleWebKit/605.1.15 误判为过旧浏览器。系统模式补齐本机 Safari 的版本段。
    static var system: String {
        desktopSafari(version: installedSafariVersion ?? "18.6")
    }

    /// 固定兼容标识，不随系统 Safari 变化，供限制内嵌浏览器的站点手动切换。
    static let desktop = desktopSafari(version: "18.6")
    static let mobile = mobileSafari(version: "18.6")

    static func userAgent(for pin: Pin) -> String? {
        switch pin.userAgentMode {
        case .system:
            return system
        case .desktop:
            return desktop
        case .mobile:
            return mobile
        case .custom:
            let value = pin.customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    static func desktopSafari(version: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(normalizedSafariVersion(version) ?? "18.6") Safari/605.1.15"
    }

    static func mobileSafari(version: String) -> String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(normalizedSafariVersion(version) ?? "18.6") "
            + "Mobile/15E148 Safari/604.1"
    }

    static func normalizedSafariVersion(_ rawValue: String) -> String? {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return components.prefix(2).joined(separator: ".")
    }

    private static var installedSafariVersion: String? {
        let paths = [
            "/Applications/Safari.app",
            "/System/Applications/Safari.app",
        ]
        for path in paths {
            guard let bundle = Bundle(path: path),
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let normalized = normalizedSafariVersion(version) else { continue }
            return normalized
        }
        return nil
    }
}
