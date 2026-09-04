import AppKit
import SwiftUI

/// 所有菜单栏浮窗均允许箭头探入菜单栏，避免系统把窗口向下推。
class StatusPopoverPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 可在非激活状态下成为 key window 的无边框浮动面板。
final class BrowserPanel: StatusPopoverPanel {
    var onEscape: (() -> Void)?
    var onReload: (() -> Void)?
    var onHardReload: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetZoom: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "r":
                if event.modifierFlags.contains(.shift) {
                    onHardReload?()
                } else {
                    onReload?()
                }
                return true
            case "w": onEscape?(); return true
            case "[": onBack?(); return true
            case "]": onForward?(); return true
            case "+", "=": onZoomIn?(); return true
            case "-": onZoomOut?(); return true
            case "0": onResetZoom?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 玻璃容器：NSPopover 质感的毛玻璃背景，
/// 用统一轮廓蒙版把「圆角主体 + 凹弧过渡箭头」裁剪为一体。
final class GlassPanelRootView: NSView {
    /// 箭头顶点在视图内的 x 坐标（0 表示不绘制箭头）
    var arrowX: CGFloat = 0 { didSet { updateMaskIfNeeded() } }

    static let cornerRadius = PopoverGeometry.cornerRadius
    static let topInset = PopoverGeometry.topInset

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateMaskIfNeeded()
    }

    private func updateMaskIfNeeded() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        // silhouette 以「左上原点」语义构建；CALayer 是左下原点，需翻转
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        guard let flipped = PopoverGeometry.silhouette(size: bounds.size, arrowX: arrowX).copy(using: &transform) else { return }

        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = flipped
        layer?.mask = mask
    }
}

/// 网页浮窗与通知提醒共用轮廓、箭头偏移和贴近菜单栏图标的定位规则。
enum PopoverGeometry {
    static let cornerRadius: CGFloat = 12
    static let topInset: CGFloat = 14
    static let arrowHalfWidth: CGFloat = 9
    static let tipY: CGFloat = 2
    static let tipRadius: CGFloat = 4
    static let baseRadius: CGFloat = 2

    static var visualApexInset: CGFloat {
        let alpha = atan(arrowHalfWidth / max(topInset - tipY, 1))
        return tipRadius * (1 / sin(alpha) - 1)
    }

    static func arrowPosition(anchorX: CGFloat, frame: NSRect) -> CGFloat {
        let margin = cornerRadius + 12
        return min(max(anchorX - frame.minX, margin), frame.width - margin)
    }

    static func anchoredFrame(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        // 保持原网页浮窗的视觉距离：补偿圆角偏移，再向菜单栏上探 6pt。
        let y = max(anchor.minY + visualApexInset + 6 - size.height, visibleFrame.minY)
        let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX + 8),
                    visibleFrame.maxX - size.width - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 面板整体轮廓：单一连续路径（圆角矩形主体，顶边内嵌圆润三角箭头）。
    /// 语义坐标系：左上原点、y 向下。
    static func silhouette(size: CGSize, arrowX: CGFloat) -> CGPath {
        let w = size.width, h = size.height
        let r = cornerRadius
        let base = min(topInset, h)
        let hw = arrowHalfWidth
        let ax = min(max(arrowX, r + hw), w - r - hw)

        let p = CGMutablePath()
        p.move(to: CGPoint(x: r, y: base))
        // 左底角 → 圆润顶点 → 右底角
        roundedCorner(p, from: CGPoint(x: r, y: base),
                      corner: CGPoint(x: ax - hw, y: base),
                      to: CGPoint(x: ax, y: tipY), radius: baseRadius)
        roundedCorner(p, from: CGPoint(x: ax - hw, y: base),
                      corner: CGPoint(x: ax, y: tipY),
                      to: CGPoint(x: ax + hw, y: base), radius: tipRadius)
        roundedCorner(p, from: CGPoint(x: ax, y: tipY),
                      corner: CGPoint(x: ax + hw, y: base),
                      to: CGPoint(x: w - r, y: base), radius: baseRadius)
        p.addLine(to: CGPoint(x: w - r, y: base))
        p.addArc(tangent1End: CGPoint(x: w, y: base), tangent2End: CGPoint(x: w, y: base + r), radius: r)
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - r, y: h), radius: r)
        p.addLine(to: CGPoint(x: r, y: h))
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - r), radius: r)
        p.addLine(to: CGPoint(x: 0, y: base + r))
        p.addArc(tangent1End: CGPoint(x: 0, y: base), tangent2End: CGPoint(x: r, y: base), radius: r)
        p.closeSubpath()
        return p
    }

    /// 在拐角处以内切圆弧替代直角折线（切线连续）。
    private static func roundedCorner(_ p: CGMutablePath,
                                      from a: CGPoint, corner c: CGPoint, to b: CGPoint,
                                      radius radiusIn: CGFloat) {
        let lenAC = hypot(c.x - a.x, c.y - a.y)
        let lenCB = hypot(b.x - c.x, b.y - c.y)
        let radius = min(radiusIn, lenAC * 0.5, lenCB * 0.5)
        guard radius > 0.25 else {
            p.addLine(to: c)
            return
        }
        let u1 = CGPoint(x: (c.x - a.x) / lenAC, y: (c.y - a.y) / lenAC)
        p.addLine(to: CGPoint(x: c.x - u1.x * radius, y: c.y - u1.y * radius))
        p.addArc(tangent1End: c, tangent2End: b, radius: radius, transform: .identity)
    }
}

/// SwiftUI 与 AppKit 的蒙版使用同一条连续圆弧路径。
struct PopoverOutline: Shape {
    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(PopoverGeometry.silhouette(size: rect.size, arrowX: arrowX))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// 顶部透明热区：按住可拖动面板。
final class ArrowDragZone: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 为无边框窗口提供更宽的内部缩放命中区，避免网页内容抢走边缘事件。
final class ResizeOverlayView: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    private let hitWidth: CGFloat = 9
    private var activeEdges: Edges = []
    private var initialMouse = NSPoint.zero
    private var initialSize = NSSize.zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: point).isEmpty ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: hitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - hitWidth, y: 0, width: hitWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: hitWidth), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - hitWidth, width: bounds.width, height: hitWidth), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        initialMouse = NSEvent.mouseLocation
        initialSize = window?.frame.size ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !activeEdges.isEmpty else { return }
        let delta = NSPoint(x: NSEvent.mouseLocation.x - initialMouse.x,
                            y: NSEvent.mouseLocation.y - initialMouse.y)
        var size = initialSize
        if activeEdges.contains(.left) { size.width -= delta.x }
        if activeEdges.contains(.right) { size.width += delta.x }
        if activeEdges.contains(.bottom) { size.height -= delta.y }
        if activeEdges.contains(.top) { size.height += delta.y }
        size.width = max(window.minSize.width, size.width)
        size.height = max(window.minSize.height, size.height)
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
    }

    private func edges(at point: NSPoint) -> Edges {
        var result: Edges = []
        if point.x <= hitWidth { result.insert(.left) }
        if point.x >= bounds.width - hitWidth { result.insert(.right) }
        if point.y <= hitWidth { result.insert(.bottom) }
        if point.y >= bounds.height - hitWidth { result.insert(.top) }
        return result
    }
}

/// 面板背景：可动态调整的纯色底色（默认系统底色，可被页面背景色覆盖）。
final class SolidBackdropView: NSView {
    var fillColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
    }
}

/// Only the arrow uses material; the web viewport keeps its own opaque background.
final class AdaptiveArrowBackdropView: NSVisualEffectView {
    private let colorOverlay = SolidBackdropView()
    var pageColor: NSColor? {
        didSet {
            guard pageColor != oldValue else { return }
            colorOverlay.isHidden = pageColor == nil
            colorOverlay.fillColor = pageColor ?? .windowBackgroundColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        colorOverlay.isHidden = true
        colorOverlay.frame = bounds
        colorOverlay.autoresizingMask = [.width, .height]
        addSubview(colorOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
enum PanelBackdrop {
    static func make() -> NSView {
        SolidBackdropView()
    }
}
