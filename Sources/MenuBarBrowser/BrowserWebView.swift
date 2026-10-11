import AppKit
import WebKit

/// 保留 WebKit 原生右键菜单，并补充系统默认浏览器入口。
@MainActor
final class BrowserWebView: WKWebView, NSMenuItemValidation {
    static let linkHandlerName = "tabNestLinks"
    var openExternalURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var openNewTab: ((URL) -> Void)?
    private var contextLinkURL: URL?
    private weak var contextLinkItem: NSMenuItem?
    private weak var newTabItem: NSMenuItem?

    static func isBrowserURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func linkUserScript() -> WKUserScript {
        let source = #"""
        (() => {
          function linkURL(event) {
            for (const node of event.composedPath()) {
              if (!(node instanceof Element)) continue;
              const link = node.closest('a[href], area[href]');
              if (!link) continue;
              try {
                const url = new URL(link.getAttribute('href'), link.baseURI);
                return ['http:', 'https:'].includes(url.protocol) ? url.href : null;
              } catch (_) { return null; }
            }
            return null;
          }
          document.addEventListener('click', event => {
            if (!event.isTrusted || !event.metaKey || event.button !== 0) return;
            const url = linkURL(event);
            if (!url) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            window.webkit.messageHandlers.tabNestLinks.postMessage({kind: 'open', url});
          }, true);
          document.addEventListener('contextmenu', event => {
            if (!event.isTrusted) return;
            window.webkit.messageHandlers.tabNestLinks.postMessage({kind: 'context', url: linkURL(event)});
          }, true);
        })();
        """#
        // 独立脚本环境支持 iframe，不向站点脚本暴露默认浏览器处理器。
        return WKUserScript(source: source, injectionTime: .atDocumentStart,
                            forMainFrameOnly: false, in: .defaultClient)
    }

    func setContextLink(_ url: URL?) {
        contextLinkURL = url.flatMap { Self.isBrowserURL($0) ? $0 : nil }
        contextLinkItem?.representedObject = contextLinkURL
        contextLinkItem?.isHidden = contextLinkURL == nil
        contextLinkItem?.isEnabled = contextLinkURL != nil
        newTabItem?.representedObject = contextLinkURL
        newTabItem?.isEnabled = contextLinkURL != nil && openNewTab != nil
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // 替换原生“新窗口”动作，仅显式菜单操作新建 Tab；普通 _blank 点击仍在当前页打开。
        if let item = menu.items.first(where: {
            $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
        }) {
            item.title = L10n.text(.menuOpenLinkInNewTab)
            item.target = self
            item.action = #selector(openInNewTab(_:))
            item.representedObject = contextLinkURL
            item.isEnabled = contextLinkURL != nil && openNewTab != nil
            newTabItem = item
        }
        menu.addItem(.separator())
        let linkItem = browserMenuItem(title: L10n.text(.menuOpenLinkInDefaultBrowser), url: contextLinkURL)
        linkItem.isHidden = contextLinkURL == nil
        menu.addItem(linkItem)
        contextLinkItem = linkItem
        menu.addItem(browserMenuItem(title: L10n.text(.menuOpenInDefaultBrowser), url: url))
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextLinkItem = nil
        newTabItem = nil
        contextLinkURL = nil
    }

    private func browserMenuItem(title: String, url: URL?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openInBrowser(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url.flatMap { Self.isBrowserURL($0) ? $0 : nil }
        item.isEnabled = item.representedObject != nil
        return item
    }

    @objc func openInBrowser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, Self.isBrowserURL(url) else { return }
        openExternalURL(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openInNewTab(_:)), openNewTab == nil { return false }
        guard let url = menuItem.representedObject as? URL else { return false }
        return Self.isBrowserURL(url)
    }

    @objc func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, Self.isBrowserURL(url) else { return }
        openNewTab?(url)
    }
}

/// WKUserContentController 强持有处理器；弱引用避免与 WebView 形成循环。
@MainActor
final class BrowserLinkHandler: NSObject, WKScriptMessageHandler {
    weak var webView: BrowserWebView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let url = (body["url"] as? String).flatMap(URL.init(string:))
        if kind == "context" {
            webView?.setContextLink(url)
        } else if kind == "open", let url, BrowserWebView.isBrowserURL(url) {
            webView?.openExternalURL(url)
        }
    }
}
