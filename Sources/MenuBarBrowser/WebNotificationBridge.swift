import AppKit
import WebKit

enum WebNotificationPermission: String, Codable {
    case ask = "default"
    case granted
    case denied
}

struct WebNotificationPermissionRequest: Identifiable, Equatable {
    let id = UUID()
    let origin: String
}

enum WebNotificationPolicy {
    /// Only trustworthy top-level web origins can request notifications.
    static func origin(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func permission(for pin: Pin, origin: String?) -> WebNotificationPermission {
        guard pin.notificationsEnabled, let origin else { return .denied }
        return pin.notificationPermissions[origin] ?? .ask
    }
}

struct WebNotice: Equatable {
    let pinID: UUID
    let id: String
    let documentID: String
    let origin: String
    let title: String
    let body: String
    let tag: String

    init?(pinID: UUID, origin: String, payload: [String: Any]) {
        guard let id = payload["id"] as? String, !id.isEmpty, id.count <= 128,
              let documentID = payload["documentID"] as? String, !documentID.isEmpty,
              documentID.count <= 128, let title = payload["title"] as? String else { return nil }
        self.pinID = pinID
        self.id = id
        self.documentID = documentID
        self.origin = origin
        self.title = String(title.prefix(120))
        self.body = String((payload["body"] as? String ?? "").prefix(500))
        self.tag = String((payload["tag"] as? String ?? "").prefix(120))
    }
}

/// Bounded inbox: the latest notice per open Tab, not an unbounded message history.
struct WebNotificationInbox {
    private(set) var latest: [UUID: WebNotice] = [:]
    var unreadPinIDs: Set<UUID> { Set(latest.keys) }

    mutating func receive(_ notice: WebNotice) { latest[notice.pinID] = notice }
    mutating func markRead(_ pinID: UUID) { latest[pinID] = nil }
    mutating func close(pinID: UUID, id: String, documentID: String) {
        guard let notice = latest[pinID], notice.id == id, notice.documentID == documentID else { return }
        latest[pinID] = nil
    }
    mutating func retain(_ pinIDs: Set<UUID>) {
        latest = latest.filter { pinIDs.contains($0.key) }
    }
}

/// Bridges document Notification API calls only. No Push API or Service Worker emulation.
/// WKUserContentController retains this handler; the reverse reference to WKWebView is weak.
@MainActor
final class WebNotificationBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "tabNestNotifications"
    let pinID: UUID
    private let store: PinStore
    weak var webView: WKWebView?
    var onNotice: ((WebNotice) -> Void)?
    var onClose: ((String, String) -> Void)?
    var onInvalidate: (() -> Void)?
    var onPermissionRequestChanged: ((WebNotificationPermissionRequest?) -> Void)?
    private(set) var permissionRequest: WebNotificationPermissionRequest?
    private var permissionReplies: [(Any?, String?) -> Void] = []
    private var stopped = false

    init(pinID: UUID, store: PinStore) {
        self.pinID = pinID
        self.store = store
    }

    func invalidateDocument() {
        cancelPermissionRequest()
        onInvalidate?()
    }

    private func finishPermissionRequest(_ permission: WebNotificationPermission) {
        guard permissionRequest != nil else { return }
        let replies = permissionReplies
        permissionReplies = []
        permissionRequest = nil
        onPermissionRequestChanged?(nil)
        for reply in replies { reply(permission.rawValue, nil) }
    }

    func cancelPermissionRequest() { finishPermissionRequest(.ask) }

    func resolvePermissionRequest(id: UUID, permission: WebNotificationPermission) {
        guard let request = permissionRequest, request.id == id else { return }
        guard !stopped, WebNotificationPolicy.origin(for: webView?.url) == request.origin,
              var pin = store.pin(with: pinID), pin.notificationsEnabled else {
            cancelPermissionRequest()
            return
        }
        // Clear the pending UI before publishing the store update (which can synchronously reenter).
        let replies = permissionReplies
        permissionReplies = []
        permissionRequest = nil
        onPermissionRequestChanged?(nil)
        if permission != .ask {
            pin.notificationPermissions[request.origin] = permission
            _ = store.update(pin)
            updatePermission(for: pin)
        }
        for reply in replies { reply(permission.rawValue, nil) }
    }

    func stop() {
        stopped = true
        invalidateDocument()
        onNotice = nil
        onClose = nil
        onInvalidate = nil
        onPermissionRequestChanged = nil
    }

    func updatePermission(for pin: Pin) {
        guard let webView else { return }
        let origin = WebNotificationPolicy.origin(for: webView.url)
        let permission = WebNotificationPolicy.permission(for: pin, origin: origin)
        webView.callAsyncJavaScript(
            "window.__tabNestUpdateNotificationPermission?.(origin, permission)",
            arguments: ["origin": origin ?? "", "permission": permission.rawValue],
            in: nil, in: .page, completionHandler: nil
        )
        if permissionRequest?.origin == origin, permission != .ask {
            finishPermissionRequest(permission)
        }
        if permission != .granted { onInvalidate?() }
    }

    func dispatch(_ event: String, for notice: WebNotice) {
        guard !stopped, WebNotificationPolicy.origin(for: webView?.url) == notice.origin else { return }
        webView?.callAsyncJavaScript(
            "window.__tabNestNotificationEvent?.(documentID, id, event)",
            arguments: ["documentID": notice.documentID, "id": notice.id, "event": event],
            in: nil, in: .page, completionHandler: nil
        )
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard !stopped, message.frameInfo.isMainFrame, message.webView === webView,
              let payload = message.body as? [String: Any],
              let operation = payload["operation"] as? String,
              let pin = store.pin(with: pinID),
              let origin = WebNotificationPolicy.origin(for: message.frameInfo.request.url),
              origin == WebNotificationPolicy.origin(for: webView?.url) else {
            replyHandler(nil, "Notifications require an open, secure top-level page.")
            return
        }
        // Trust WebKit's security origin, never a page-supplied origin string (or a base URL).
        let security = message.frameInfo.securityOrigin
        let securityHost = security.host.contains(":") && !security.host.hasPrefix("[") ? "[\(security.host)]" : security.host
        guard let securityURL = URL(string: "\(security.protocol)://\(securityHost)\(security.port > 0 ? ":\(security.port)" : "")"),
              WebNotificationPolicy.origin(for: securityURL) == origin else {
            replyHandler(nil, "Untrusted notification origin.")
            return
        }
        let permission = WebNotificationPolicy.permission(for: pin, origin: origin)
        switch operation {
        case "permission":
            replyHandler(permission.rawValue, nil)
        case "requestPermission":
            guard permission == .ask else { replyHandler(permission.rawValue, nil); return }
            guard payload["userGesture"] as? Bool == true,
                  webView?.window?.isVisible == true, onPermissionRequestChanged != nil,
                  permissionReplies.count < 16 else {
                replyHandler(WebNotificationPermission.ask.rawValue, nil)
                return
            }
            if let request = permissionRequest, request.origin != origin { cancelPermissionRequest() }
            permissionReplies.append(replyHandler)
            if permissionRequest == nil {
                let request = WebNotificationPermissionRequest(origin: origin)
                permissionRequest = request
                onPermissionRequestChanged?(request)
            }
        case "show":
            guard permission == .granted,
                  let notice = WebNotice(pinID: pinID, origin: origin, payload: payload) else {
                replyHandler(nil, "Notification permission denied or invalid payload.")
                return
            }
            onNotice?(notice)
            replyHandler(true, nil)
        case "close":
            if let id = payload["id"] as? String, let documentID = payload["documentID"] as? String {
                onClose?(id, documentID)
            }
            replyHandler(true, nil)
        default:
            replyHandler(nil, "Unsupported notification operation.")
        }
    }

    static func userScript(for pin: Pin) -> WKUserScript {
        let settings: [String: Any] = [
            "enabled": pin.notificationsEnabled,
            "permissions": pin.notificationPermissions.mapValues(\.rawValue),
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: settings), encoding: .utf8)!
        return WKUserScript(source: "(function(){ const settings = \(json);\n" + scriptBody + "\n})();",
                            injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static let scriptBody = #"""
    if (!window.isSecureContext || window.top !== window) return;
    const handler = window.webkit?.messageHandlers?.tabNestNotifications;
    if (!handler) return;
    const origin = location.origin;
    const documentID = crypto.randomUUID();
    let lastTrustedInput = -Infinity;
    for (const type of ['click', 'keydown', 'touchend']) {
      window.addEventListener(type, event => {
        if (event.isTrusted) lastTrustedInput = performance.now();
      }, true);
    }
    let permission = settings.enabled ? (settings.permissions[origin] || 'default') : 'denied';
    let sequence = 0;
    const notices = new Map();
    const send = (operation, data = {}) => handler.postMessage({operation, documentID, ...data});
    const ready = send('permission').then(value => { permission = value; }).catch(() => { permission = 'denied'; });
    function fire(notice, type) {
      notice.dispatchEvent(new Event(type));
    }
    class TabNestNotification extends EventTarget {
      constructor(title, options = {}) {
        super();
        if (permission !== 'granted') throw new DOMException('Notification permission is not granted.', 'NotAllowedError');
        this.title = String(title);
        this.body = String(options.body || '');
        this.tag = String(options.tag || '');
        this.data = options.data ?? null;
        this.icon = String(options.icon || '');
        this.silent = Boolean(options.silent);
        this._id = String(++sequence);
        this._closed = false;
        this.onclick = this.onclose = this.onerror = this.onshow = null;
        if (this.tag) {
          for (const previous of notices.values()) {
            if (previous.tag === this.tag) previous.close();
          }
        }
        // Match the native bounded inbox and avoid retaining a page's entire notification history.
        if (notices.size >= 32) notices.values().next().value.close();
        notices.set(this._id, this);
        ready.then(() => {
          if (this._closed) return;
          return send('show', {id: this._id, title: this.title, body: this.body, tag: this.tag})
            .then(() => { if (!this._closed) fire(this, 'show'); });
        }).catch(() => { fire(this, 'error'); this.close(); });
      }
      static get permission() { return permission; }
      static get maxActions() { return 0; }
      static requestPermission(callback) {
        const gesture = navigator.userActivation
          ? navigator.userActivation.isActive : performance.now() - lastTrustedInput < 1000;
        return ready.then(() => send('requestPermission', {userGesture: gesture}))
          .then(value => { permission = value; if (typeof callback === 'function') callback(value); return value; });
      }
      close() {
        if (this._closed) return;
        this._closed = true;
        notices.delete(this._id);
        send('close', {id: this._id}).catch(() => {});
        fire(this, 'close');
      }
    }
    // Event-handler properties and addEventListener share normal EventTarget dispatch semantics.
    for (const type of ['click', 'close', 'error', 'show']) {
      Object.defineProperty(TabNestNotification.prototype, 'on' + type, {
        get() { return this['_on' + type] || null; },
        set(fn) {
          if (this['_on' + type]) this.removeEventListener(type, this['_on' + type]);
          this['_on' + type] = typeof fn === 'function' ? fn : null;
          if (this['_on' + type]) this.addEventListener(type, this['_on' + type]);
        }
      });
    }
    Object.defineProperty(window, 'Notification', {value: TabNestNotification, configurable: true});
    window.__tabNestUpdateNotificationPermission = (expectedOrigin, value) => {
      if (expectedOrigin === origin) permission = value;
    };
    window.__tabNestNotificationEvent = (expectedDocument, id, type) => {
      if (expectedDocument !== documentID) return;
      const notice = notices.get(id);
      if (!notice) return;
      if (type === 'click') fire(notice, 'click');
      if (type === 'close') notice.close();
    };
    """#
}
