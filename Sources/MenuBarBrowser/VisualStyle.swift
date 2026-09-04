import SwiftUI

/// Keep the deployment target at macOS 13. New systems render their own Liquid Glass;
/// older SDKs and systems retain native material instead of imitating glass with gradients.
enum TabNestVisualPolicy {
    enum Surface { case glass, material, opaque }

    static var supportsLiquidGlass: Bool {
        #if compiler(>=6.2) && !TABNEST_LEGACY_SDK
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    static func surface(modernSystem: Bool, reduceTransparency: Bool,
                        increasedContrast: Bool, forceLegacy: Bool) -> Surface {
        if reduceTransparency || increasedContrast { return .opaque }
        return modernSystem && !forceLegacy ? .glass : .material
    }
}

private struct LegacyAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

struct TabNestAccessibilityPreview {
    let reduceTransparency: Bool
    let increasedContrast: Bool
}

private struct AccessibilityPreviewKey: EnvironmentKey {
    static let defaultValue: TabNestAccessibilityPreview? = nil
}

extension EnvironmentValues {
    /// Injectable fallback for regression previews without changing the user's system settings.
    var tabNestLegacyAppearance: Bool {
        get { self[LegacyAppearanceKey.self] }
        set { self[LegacyAppearanceKey.self] = newValue }
    }
    var tabNestAccessibilityPreview: TabNestAccessibilityPreview? {
        get { self[AccessibilityPreviewKey.self] }
        set { self[AccessibilityPreviewKey.self] = newValue }
    }
}

private struct FloatingSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tabNestLegacyAppearance) private var legacy
    @Environment(\.tabNestAccessibilityPreview) private var preview
    private var opaque: Bool { preview?.reduceTransparency ?? reduceTransparency }
    private var highContrast: Bool { preview?.increasedContrast ?? (contrast == .increased) }

    @ViewBuilder func body(content: Content) -> some View {
        switch TabNestVisualPolicy.surface(modernSystem: TabNestVisualPolicy.supportsLiquidGlass,
                                           reduceTransparency: opaque,
                                           increasedContrast: highContrast, forceLegacy: legacy) {
        case .opaque:
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay {
                    if highContrast {
                        shape.stroke(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
                    }
                }
        case .glass:
            modernOrLegacy(content)
        case .material:
            content.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder private func modernOrLegacy(_ content: Content) -> some View {
        #if compiler(>=6.2) && !TABNEST_LEGACY_SDK
        if #available(macOS 26.0, *), !legacy {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #else
        content.background(.regularMaterial, in: shape)
        #endif
    }
}

private struct PrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tabNestLegacyAppearance) private var legacy
    @Environment(\.tabNestAccessibilityPreview) private var preview

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2) && !TABNEST_LEGACY_SDK
        if #available(macOS 26.0, *), !legacy,
           !(preview?.reduceTransparency ?? reduceTransparency),
           !(preview?.increasedContrast ?? (contrast == .increased)) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}

private struct ToolbarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.tabNestAccessibilityPreview) private var preview

    @ViewBuilder func body(content: Content) -> some View {
        if (preview?.reduceTransparency ?? reduceTransparency) || (preview?.increasedContrast ?? (contrast == .increased)) {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content.background(.bar)
        }
    }
}

extension View {
    func tabNestFloatingSurface<S: Shape>(in shape: S) -> some View {
        modifier(FloatingSurface(shape: shape))
    }

    func tabNestPrimaryAction() -> some View { modifier(PrimaryAction()) }
    func tabNestToolbarSurface() -> some View { modifier(ToolbarSurface()) }
}
