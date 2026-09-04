import SwiftUI
import AppKit

@MainActor
final class PinPanelModel: ObservableObject {
    @Published var state = TabState()
    let webView: NSView
    var onRetry: (() -> Void)?
    @Published var permissionRequest: WebNotificationPermissionRequest?
    var onPermissionDecision: ((UUID, WebNotificationPermission) -> Void)?

    init(webView: NSView) {
        self.webView = webView
    }
}

/// 单个站点面板：网页、细进度条及按需显示的非阻塞通知授权条。
struct PinPanelRootView: View {
    @ObservedObject var model: PinPanelModel

    var body: some View {
        VStack(spacing: 0) {
            if let request = model.permissionRequest {
                NotificationPermissionBar(request: request) { id, permission in
                    model.onPermissionDecision?(id, permission)
                }
                Divider()
            }
            ZStack(alignment: .top) {
                WebViewContainer(view: model.webView)

                if model.state.isLoading {
                    ProgressView(value: min(model.state.progress, 1))
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                        .tint(.accentColor)
                }

                if let message = model.state.loadErrorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(L10n.text(.webLoadFailedTitle))
                            .font(.headline)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                        Button(L10n.text(.webRetry)) { model.onRetry?() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(24)
                    .frame(maxWidth: 360)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 270)
        .background(Color.clear)   // 背景由玻璃容器负责
    }
}

/// 优先单行展示；完整内容放不下时折为两行，不挤压操作按钮。
struct NotificationPermissionBar: View {
    let request: WebNotificationPermissionRequest
    var language = L10n.language
    let onDecision: (UUID, WebNotificationPermission) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title.fixedSize()
                origin.fixedSize()
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    title.fixedSize()
                    origin.frame(maxWidth: .infinity, alignment: .leading)
                }
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private var title: some View {
        Label(L10n.text(.notificationPermissionTitle, language: language), systemImage: "bell.badge")
            .font(.system(size: 12, weight: .medium))
            .help(L10n.text(.notificationPermissionHint, language: language))
    }

    private var origin: some View {
        Text(request.origin)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(request.origin).accessibilityLabel(request.origin)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(L10n.text(.notificationLater, language: language)) { onDecision(request.id, .ask) }
            Button(L10n.text(.commonDeny, language: language)) { onDecision(request.id, .denied) }
            Button(L10n.text(.commonAllow, language: language)) { onDecision(request.id, .granted) }
                .tint(.accentColor)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .fixedSize()
    }
}

/// 把常驻 WKWebView 桥接进 SwiftUI 层级。
struct WebViewContainer: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "menubar.dock.rectangle")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("TabNest").font(.title3.bold())
            Text(L10n.text(.aboutSubtitle))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Divider()
            Text(L10n.text(.aboutInstructions))
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
