import SwiftUI
import AppKit

@MainActor
final class PinPanelModel: ObservableObject {
    @Published var state = TabState()
    let webView: NSView

    init(webView: NSView) {
        self.webView = webView
    }
}

/// 单个站点面板的根视图：纯网页 + 顶部细进度条（无浏览器 chrome）。
struct PinPanelRootView: View {
    @ObservedObject var model: PinPanelModel

    var body: some View {
        ZStack(alignment: .top) {
            WebViewContainer(view: model.webView)

            if model.state.isLoading {
                ProgressView(value: min(model.state.progress, 1))
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .tint(.accentColor)
            }
        }
        .frame(minWidth: 340, minHeight: 270)
        .background(Color.clear)   // 背景由玻璃容器负责
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
