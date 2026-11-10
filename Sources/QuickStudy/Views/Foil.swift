import SwiftUI

/// Foil treatments for the card image (prototype for a future supporter-only feature).
/// Gating hook: `isUnlocked` is the single place to check entitlement; the picker only lists unlocked styles.
enum FoilStyle: String, CaseIterable, Identifiable {
    case none, holo, etched, galaxy, surge
    static let storageKey = "foilStyle"
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.capitalized }
    var isUnlocked: Bool { true }
    static var available: [FoilStyle] { allCases.filter(\.isUnlocked) }

    /// The style for a stored `foilStyle` value: the removed "gilded" becomes surge, unknown or
    /// locked styles become none.
    init(stored raw: String) {
        let style = raw == "gilded" ? .surge : FoilStyle(rawValue: raw) ?? .none
        self = style.isUnlocked ? style : .none
    }

    /// Stitchable function in Resources/Foil.metal.
    fileprivate var shader: String? {
        switch self {
        case .none: nil
        case .holo: "foilHolo"
        case .etched: "foilEtched"
        case .galaxy: "foilGalaxy"
        case .surge: "foilSurge"
        }
    }
}

/// Per-pixel foil via the Metal shaders in Foil.metallib (GPU only; compiled into the bundle by
/// scripts/compile-shaders.sh). `pointer` is -1...1 from the card centre, the value `CardTilt` drives;
/// it is animatable so the light eases back to centre with the tilt instead of jumping.
struct FoilEffect: ViewModifier, Animatable {
    let style: FoilStyle
    var pointer: CGPoint

    /// nil when the metallib isn't in the bundle (e.g. `swift run`): no foil rather than a broken shader.
    static var library: ShaderLibrary? = Bundle.main.url(forResource: "Foil", withExtension: "metallib")
        .map { ShaderLibrary(url: $0) }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pointer.x, pointer.y) }
        set { pointer = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func body(content: Content) -> some View {
        if let name = style.shader, let library = Self.library {
            let p = pointer
            content.visualEffect { view, proxy in
                view.layerEffect(
                    ShaderFunction(library: library, name: name)(.float2(proxy.size), .float2(p)),
                    maxSampleOffset: .zero)
            }
        } else {
            content
        }
    }
}

/// Compact style picker shown directly below the card art.
struct FoilPicker: View {
    @AppStorage(FoilStyle.storageKey) private var raw = FoilStyle.none.rawValue
    var body: some View {
        Picker("Foil", selection: $raw) {
            ForEach(FoilStyle.available) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("Foil effect")
        .accessibilityLabel("Foil effect")
        // Rewrite legacy/locked stored values so the segmented control always shows a selection.
        .onAppear { let s = FoilStyle(stored: raw).rawValue; if s != raw { raw = s } }
    }
}
