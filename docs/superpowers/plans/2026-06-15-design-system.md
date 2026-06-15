# Design System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Quick Study design system natively in SwiftUI — a centralized token layer, the brand blue→violet accent, and MTG mana color identity (gold-for-multicolor) across thumbnails, placeholders, mana pips, and badges.

**Architecture:** A pure `ColorIdentity` enum + derivation in `Shared` (framework-agnostic) feeds a `DS` token namespace and small reusable views in `Sources/QuickStudy/DesignSystem/`. Existing views are then re-pointed at tokens. No DB migration — the `colors` column already exists.

**Tech Stack:** Swift, SwiftUI, AppKit, GRDB (SQLite), XCTest. Min target macOS 14.

---

## Reference docs

- Spec: `docs/superpowers/specs/2026-06-15-design-system-design.md`
- Design tokens (canonical hex/values): `quick-study-design-system/tokens/*.css` (in the handoff)
- Behavior references: `quick-study-design-system/components/{mtg/ManaCost.jsx,mtg/Badge.jsx,search/ResultRow.jsx}`

## File structure

**Create:**
- `Sources/QuickStudy/DesignSystem/Tokens.swift` — `Color` helpers + `DS` namespace (colors, radii, shadow, motion, tint mapping)
- `Sources/QuickStudy/DesignSystem/ManaCost.swift` — pure pip parser (`ManaPip`, `ManaCost.pips(from:)`)
- `Sources/QuickStudy/DesignSystem/ManaCostView.swift` — renders pips
- `Sources/QuickStudy/DesignSystem/IdentityPlaceholder.swift` — mana-tinted gradient fill
- `Sources/QuickStudy/DesignSystem/IdentityBadge.swift` — identity-tinted capsule
- `Sources/QuickStudy/DesignSystem/BrandProminentButtonStyle.swift` — accent-gradient button style
- `Tests/SearchEngineTests/ColorIdentityTests.swift`
- `Tests/SearchEngineTests/ManaCostTests.swift`
- `Tests/SearchEngineTests/CardStoreIdentityTests.swift`

**Modify:**
- `Sources/Shared/Card.swift` — `ColorIdentity`, `Card.identity`, `Mini.identity`
- `Sources/Shared/CardStore.swift` — `loadMinis()` reads `colors`
- `Sources/QuickStudy/Views/Thumbnail.swift`, `ResultList.swift`, `PinnedRow.swift`, `CardPreview.swift`, `SearchPanel.swift`, `DownloadPromptView.swift`
- `Sources/QuickStudy/SettingsView.swift`

---

## Task 1: ColorIdentity enum + Card.identity

**Files:**
- Modify: `Sources/Shared/Card.swift`
- Test: `Tests/SearchEngineTests/ColorIdentityTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/ColorIdentityTests.swift`:

```swift
import XCTest
import Shared

final class ColorIdentityTests: XCTestCase {
    func testSingleColor() {
        XCTAssertEqual(ColorIdentity(colors: ["R"]), .red)
        XCTAssertEqual(ColorIdentity(colors: ["W"]), .white)
        XCTAssertEqual(ColorIdentity(colors: ["U"]), .blue)
        XCTAssertEqual(ColorIdentity(colors: ["B"]), .black)
        XCTAssertEqual(ColorIdentity(colors: ["G"]), .green)
    }

    func testTwoOrMoreColorsIsMulticolor() {
        XCTAssertEqual(ColorIdentity(colors: ["W", "U"]), .multicolor)
        XCTAssertEqual(ColorIdentity(colors: ["W", "U", "B", "R", "G"]), .multicolor)
    }

    func testEmptyIsColorless() {
        XCTAssertEqual(ColorIdentity(colors: []), .colorless)
    }

    func testCardIdentityComputed() {
        let card = Card(id: "x", name: "Niv-Mizzet", manaCost: "{U}{R}", typeLine: nil,
                        oracleText: nil, power: nil, toughness: nil, colors: ["U", "R"],
                        imagePath: nil, scryfallURI: "")
        XCTAssertEqual(card.identity, .multicolor)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ColorIdentityTests`
Expected: FAIL — `ColorIdentity` not in scope / no member `identity`.

- [ ] **Step 3: Add the enum and computed property**

In `Sources/Shared/Card.swift`, add at the top level (after the imports, before or after `struct Card`):

```swift
/// Magic color identity used for frame/thumbnail/badge tints.
/// Two or more colors collapse to `.multicolor` (gold) — never a blend.
public enum ColorIdentity: Sendable, Equatable {
    case white, blue, black, red, green, colorless, multicolor

    public init(colors: [String]) {
        if colors.count >= 2 {
            self = .multicolor
            return
        }
        switch colors.first {
        case "W": self = .white
        case "U": self = .blue
        case "B": self = .black
        case "R": self = .red
        case "G": self = .green
        default:  self = .colorless
        }
    }
}
```

Inside `struct Card`, add the computed property (e.g. right after the stored properties, before `init`):

```swift
    public var identity: ColorIdentity { ColorIdentity(colors: colors) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ColorIdentityTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/Card.swift Tests/SearchEngineTests/ColorIdentityTests.swift
git commit -m "Add ColorIdentity enum and Card.identity"
```

---

## Task 2: Card.Mini carries identity

**Files:**
- Modify: `Sources/Shared/Card.swift`
- Test: `Tests/SearchEngineTests/ColorIdentityTests.swift`

- [ ] **Step 1: Add the failing test**

Append to `ColorIdentityTests`:

```swift
    func testMiniDefaultInitIsColorless() {
        let mini = Card.Mini(id: "1", name: "Shock")
        XCTAssertEqual(mini.identity, .colorless)
    }

    func testMiniColorsInitDerivesIdentity() {
        let mini = Card.Mini(id: "2", name: "Lightning Helix", colors: ["R", "W"])
        XCTAssertEqual(mini.identity, .multicolor)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ColorIdentityTests`
Expected: FAIL — `Mini` has no member `identity` / no `init(id:name:colors:)`.

- [ ] **Step 3: Extend `Card.Mini`**

In `Sources/Shared/Card.swift`, replace the existing `Mini` struct with:

```swift
    /// Minimal projection loaded into memory for fast search ranking.
    public struct Mini: Sendable, Equatable {
        public let id: String
        public let name: String
        public let nameLower: String
        public let identity: ColorIdentity

        /// Kept for callers (and tests) that don't need identity; defaults to colorless.
        public init(id: String, name: String) {
            self.init(id: id, name: name, colors: [])
        }

        public init(id: String, name: String, colors: [String]) {
            self.id = id
            self.name = name
            self.nameLower = name.lowercased()
            self.identity = ColorIdentity(colors: colors)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ColorIdentityTests`
Expected: PASS (6 tests). The existing `SearchEngineTests` still compile because `Mini(id:name:)` is retained.

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/Card.swift Tests/SearchEngineTests/ColorIdentityTests.swift
git commit -m "Carry color identity on Card.Mini (additive)"
```

---

## Task 3: CardStore.loadMinis reads colors

**Files:**
- Modify: `Sources/Shared/CardStore.swift:50-55`
- Test: `Tests/SearchEngineTests/CardStoreIdentityTests.swift`

- [ ] **Step 1: Write the failing integration test**

Create `Tests/SearchEngineTests/CardStoreIdentityTests.swift`:

```swift
import XCTest
import Shared

final class CardStoreIdentityTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qs-test-\(UUID().uuidString).sqlite")
        return try CardStore(url: url)
    }

    func testLoadMinisDerivesIdentityFromColors() throws {
        let store = try makeStore()
        try store.upsert([
            Card(id: "mono", name: "Shock", manaCost: "{R}", typeLine: "Instant",
                 oracleText: nil, power: nil, toughness: nil, colors: ["R"],
                 imagePath: nil, scryfallURI: ""),
            Card(id: "multi", name: "Lightning Helix", manaCost: "{R}{W}", typeLine: "Instant",
                 oracleText: nil, power: nil, toughness: nil, colors: ["R", "W"],
                 imagePath: nil, scryfallURI: ""),
            Card(id: "colorless", name: "Sol Ring", manaCost: "{1}", typeLine: "Artifact",
                 oracleText: nil, power: nil, toughness: nil, colors: [],
                 imagePath: nil, scryfallURI: ""),
        ])

        let minis = try store.loadMinis()
        let byID = Dictionary(uniqueKeysWithValues: minis.map { ($0.id, $0.identity) })
        XCTAssertEqual(byID["mono"], .red)
        XCTAssertEqual(byID["multi"], .multicolor)
        XCTAssertEqual(byID["colorless"], .colorless)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CardStoreIdentityTests`
Expected: FAIL — every identity comes back `.colorless` (loadMinis ignores `colors`).

- [ ] **Step 3: Widen the query**

In `Sources/Shared/CardStore.swift`, replace `loadMinis()`:

```swift
    public func loadMinis() throws -> [Card.Mini] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, colors FROM cards")
            return rows.map { row in
                let colorsRaw: String = row["colors"] ?? "[]"
                let colors = (try? JSONDecoder().decode([String].self, from: Data(colorsRaw.utf8))) ?? []
                return Card.Mini(id: row["id"], name: row["name"], colors: colors)
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CardStoreIdentityTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/CardStore.swift Tests/SearchEngineTests/CardStoreIdentityTests.swift
git commit -m "loadMinis derives color identity from stored colors"
```

---

## Task 4: Mana-cost pip parser

**Files:**
- Create: `Sources/QuickStudy/DesignSystem/ManaCost.swift`
- Test: `Tests/SearchEngineTests/ManaCostTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SearchEngineTests/ManaCostTests.swift`:

```swift
import XCTest
@testable import QuickStudy
import Shared

final class ManaCostTests: XCTestCase {
    func testParsesColorAndGenericPips() {
        let pips = ManaCost.pips(from: "{2}{W}{U}")
        XCTAssertEqual(pips, [
            ManaPip(glyph: "2", identity: .colorless),
            ManaPip(glyph: "W", identity: .white),
            ManaPip(glyph: "U", identity: .blue),
        ])
    }

    func testTapSymbol() {
        XCTAssertEqual(ManaCost.pips(from: "{T}"), [ManaPip(glyph: "↻", identity: .colorless)])
    }

    func testHybridFallsBackToColorlessDiscWithText() {
        XCTAssertEqual(ManaCost.pips(from: "{B/R}"), [ManaPip(glyph: "B/R", identity: .colorless)])
    }

    func testEmptyAndNoTokens() {
        XCTAssertEqual(ManaCost.pips(from: ""), [])
        XCTAssertEqual(ManaCost.pips(from: "no braces"), [])
    }

    func testXAndColorlessAreColorlessDiscs() {
        XCTAssertEqual(ManaCost.pips(from: "{X}{C}"), [
            ManaPip(glyph: "X", identity: .colorless),
            ManaPip(glyph: "C", identity: .colorless),
        ])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ManaCostTests`
Expected: FAIL — `ManaCost` / `ManaPip` not defined.

- [ ] **Step 3: Implement the parser**

Create `Sources/QuickStudy/DesignSystem/ManaCost.swift`:

```swift
import Shared

/// One rendered mana pip: the glyph shown inside the disc and the identity that tints it.
public struct ManaPip: Equatable {
    public let glyph: String
    public let identity: ColorIdentity
}

/// Pure parser for Scryfall mana-cost strings like "{2}{U}{U}".
/// W/U/B/R/G map to their color; everything else (numbers, X, C, hybrids,
/// Phyrexian) renders as a colorless disc showing the inner text. "{T}" → ↻.
public enum ManaCost {
    public static func pips(from cost: String) -> [ManaPip] {
        guard !cost.isEmpty else { return [] }
        var pips: [ManaPip] = []
        var token = ""
        var inside = false
        for ch in cost {
            switch ch {
            case "{": inside = true; token = ""
            case "}": inside = false; pips.append(pip(for: token))
            default:  if inside { token.append(ch) }
            }
        }
        return pips
    }

    private static func pip(for token: String) -> ManaPip {
        let upper = token.uppercased()
        switch upper {
        case "W": return ManaPip(glyph: "W", identity: .white)
        case "U": return ManaPip(glyph: "U", identity: .blue)
        case "B": return ManaPip(glyph: "B", identity: .black)
        case "R": return ManaPip(glyph: "R", identity: .red)
        case "G": return ManaPip(glyph: "G", identity: .green)
        case "T": return ManaPip(glyph: "↻", identity: .colorless)
        default:  return ManaPip(glyph: upper, identity: .colorless)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ManaCostTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/DesignSystem/ManaCost.swift Tests/SearchEngineTests/ManaCostTests.swift
git commit -m "Add mana-cost pip parser"
```

---

## Task 5: Token layer (Tokens.swift)

**Files:**
- Create: `Sources/QuickStudy/DesignSystem/Tokens.swift`

This task is build-verified (visual tokens, no logic to unit-test).

- [ ] **Step 1: Create the token layer**

Create `Sources/QuickStudy/DesignSystem/Tokens.swift`:

```swift
import SwiftUI
import AppKit
import Shared

extension Color {
    /// Build a color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A color that resolves differently in light vs dark appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: return NSColor(dark)
            default:        return NSColor(light)
            }
        })
    }
}

/// Design-system tokens. Text/surfaces/separators intentionally keep native
/// macOS semantics (`.primary`, `.secondary`, `.separator`) — those already
/// match the design's label opacities and adapt to the OS appearance.
enum DS {
    // MARK: Brand (marketing mark only)
    static let brandBlue = Color(hex: 0x283C8C)
    static let brandViolet = Color(hex: 0x7846B4)
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandBlue, brandViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Interactive accent
    static let accent = Color(light: Color(hex: 0x5B45C2), dark: Color(hex: 0x9B8AF2))
    static let accentGradientStart = Color(light: Color(hex: 0x3E4FB5), dark: Color(hex: 0x4A5BC8))
    static let accentGradientEnd = Color(light: Color(hex: 0x7A45B6), dark: Color(hex: 0x8E54CE))
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentGradientStart, accentGradientEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Selection wash
    static let selection = Color(light: Color(hex: 0x5B45C2).opacity(0.16),
                                 dark: Color(hex: 0x9B8AF2).opacity(0.30))
    static let selectionStrong = Color(light: Color(hex: 0x5B45C2).opacity(0.26),
                                       dark: Color(hex: 0x9B8AF2).opacity(0.42))

    // MARK: MTG mana tints (theme-independent)
    static let manaW = Color(hex: 0xFFFBD5)
    static let manaU = Color(hex: 0xAAE0FA)
    static let manaB = Color(hex: 0xCBC2BF)
    static let manaR = Color(hex: 0xF9AA8F)
    static let manaG = Color(hex: 0x9BD3AE)
    static let manaC = Color(hex: 0xCAC5C0)
    static let manaGold = Color(hex: 0xD6B458)
    static let manaInk = Color(hex: 0x1A1714)
    static var goldGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0xE6CC74), Color(hex: 0xC49B3F)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The solid frame/thumbnail tint for a color identity.
    static func tint(for identity: ColorIdentity) -> Color {
        switch identity {
        case .white: return manaW
        case .blue: return manaU
        case .black: return manaB
        case .red: return manaR
        case .green: return manaG
        case .colorless: return manaC
        case .multicolor: return manaGold
        }
    }

    /// A subtle gradient fill for placeholders; gold gradient for multicolor.
    static func identityGradient(for identity: ColorIdentity) -> LinearGradient {
        if identity == .multicolor { return goldGradient }
        let base = tint(for: identity)
        return LinearGradient(colors: [base, base.opacity(0.82)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Status
    static let statusRed = Color(hex: 0xFF3B30)
    static let statusGreen = Color(hex: 0x34C759)
    static let statusOrange = Color(hex: 0xFF9500)

    // MARK: Radii
    enum Radius {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 6
        static let md: CGFloat = 7
        static let lg: CGFloat = 10
        static let img: CGFloat = 12
        static let panel: CGFloat = 14
    }

    // MARK: Motion
    enum Motion {
        static let selectScroll = Animation.easeOut(duration: 0.08)
        static let resize = Animation.easeInOut(duration: 0.2)
    }
}

extension View {
    /// Soft medium shadow for card images (design: 0 8 24 black @ .18).
    func dsCardShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
    }

    /// 0.5px hairline ring used around thumbnails and real card images.
    func dsHairlineRing(cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/DesignSystem/Tokens.swift
git commit -m "Add DS token layer (colors, radii, shadow, motion, tints)"
```

---

## Task 6: ManaCostView

**Files:**
- Create: `Sources/QuickStudy/DesignSystem/ManaCostView.swift`

- [ ] **Step 1: Create the view**

Create `Sources/QuickStudy/DesignSystem/ManaCostView.swift`:

```swift
import SwiftUI

/// Renders a mana-cost string as a row of colored pips.
struct ManaCostView: View {
    let cost: String
    var size: CGFloat = 18

    var body: some View {
        let pips = ManaCost.pips(from: cost)
        HStack(spacing: 3) {
            ForEach(Array(pips.enumerated()), id: \.offset) { _, pip in
                Text(pip.glyph)
                    .font(.system(size: round(size * 0.58), weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.manaInk)
                    .frame(width: size, height: size)
                    .background(Circle().fill(DS.tint(for: pip.identity)))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/DesignSystem/ManaCostView.swift
git commit -m "Add ManaCostView pip renderer"
```

---

## Task 7: IdentityPlaceholder

**Files:**
- Create: `Sources/QuickStudy/DesignSystem/IdentityPlaceholder.swift`

- [ ] **Step 1: Create the view**

Create `Sources/QuickStudy/DesignSystem/IdentityPlaceholder.swift`:

```swift
import SwiftUI
import Shared

/// Mana-tinted gradient fill shown wherever a card image is missing.
struct IdentityPlaceholder: View {
    let identity: ColorIdentity
    var cornerRadius: CGFloat = DS.Radius.xs
    var symbol: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DS.identityGradient(for: identity))
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title)
                        .foregroundStyle(DS.manaInk.opacity(0.45))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/DesignSystem/IdentityPlaceholder.swift
git commit -m "Add IdentityPlaceholder gradient fill"
```

---

## Task 8: IdentityBadge

**Files:**
- Create: `Sources/QuickStudy/DesignSystem/IdentityBadge.swift`

- [ ] **Step 1: Create the view**

Create `Sources/QuickStudy/DesignSystem/IdentityBadge.swift`:

```swift
import SwiftUI
import Shared

/// A small identity-tinted capsule shown in the card preview header.
/// Displays the card's color letters (e.g. "WU"), or "C" when colorless.
struct IdentityBadge: View {
    let colors: [String]

    private var identity: ColorIdentity { ColorIdentity(colors: colors) }
    private var label: String { colors.isEmpty ? "C" : colors.joined() }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.manaInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(DS.tint(for: identity)))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/DesignSystem/IdentityBadge.swift
git commit -m "Add IdentityBadge capsule"
```

---

## Task 9: BrandProminentButtonStyle

**Files:**
- Create: `Sources/QuickStudy/DesignSystem/BrandProminentButtonStyle.swift`

- [ ] **Step 1: Create the style**

Create `Sources/QuickStudy/DesignSystem/BrandProminentButtonStyle.swift`:

```swift
import SwiftUI

/// Prominent button with the brand accent gradient fill (design: solid fills
/// use the blue→violet gradient). Use for primary actions only.
struct BrandProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.accentGradient)
            )
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

extension ButtonStyle where Self == BrandProminentButtonStyle {
    static var brandProminent: BrandProminentButtonStyle { BrandProminentButtonStyle() }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/DesignSystem/BrandProminentButtonStyle.swift
git commit -m "Add BrandProminentButtonStyle (accent gradient)"
```

---

## Task 10: Thumbnail uses identity + placeholder

**Files:**
- Modify: `Sources/QuickStudy/Views/Thumbnail.swift`

- [ ] **Step 1: Replace the file**

Replace `Sources/QuickStudy/Views/Thumbnail.swift` with:

```swift
import SwiftUI
import AppKit
import Shared

/// Small card thumbnail loaded synchronously from the on-disk image cache,
/// with a mana-tinted placeholder when the image hasn't been downloaded.
/// Shared by the results list and the pinned row.
struct Thumbnail: View {
    let id: String
    var identity: ColorIdentity = .colorless
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs))
                    .dsHairlineRing(cornerRadius: DS.Radius.xs)
            } else {
                IdentityPlaceholder(identity: identity, cornerRadius: DS.Radius.xs)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let url = Paths.imageURL(forCardID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Cheap synchronous load — thumbnails are small JPEGs.
        if let img = NSImage(contentsOf: url) {
            self.image = img
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (callers still use `Thumbnail(id:)`, identity defaults to colorless — updated next task).

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickStudy/Views/Thumbnail.swift
git commit -m "Thumbnail: mana-tinted placeholder + identity param"
```

---

## Task 11: ResultList + PinnedRow — identity thumbnails + brand selection

**Files:**
- Modify: `Sources/QuickStudy/Views/ResultList.swift:39-52`
- Modify: `Sources/QuickStudy/Views/PinnedRow.swift:25-37`

- [ ] **Step 1: Update ResultList.Row**

In `Sources/QuickStudy/Views/ResultList.swift`, replace the body of `Row` (the `return HStack…` block) with:

```swift
            let scale = UIScale(value: uiScaleValue)
            return HStack(spacing: scale.pad(10)) {
                Thumbnail(id: mini.id, identity: mini.identity)
                    .frame(width: scale.size(28), height: scale.size(40))
                Text(mini.name)
                    .lineLimit(1)
                    .font(scale.font(14))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, scale.pad(10))
            .padding(.vertical, scale.pad(4))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(selected ? DS.selectionStrong : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
```

- [ ] **Step 2: Update PinnedRow.entry**

In `Sources/QuickStudy/Views/PinnedRow.swift`, in `entry(_:scale:)` change the thumbnail and the selection background:

Replace:
```swift
            Thumbnail(id: mini.id)
                .frame(width: scale.size(44), height: scale.size(62))
```
with:
```swift
            Thumbnail(id: mini.id, identity: mini.identity)
                .frame(width: scale.size(44), height: scale.size(62))
```

Replace:
```swift
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
        )
```
with:
```swift
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(selected ? DS.selectionStrong : Color.clear)
        )
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/QuickStudy/Views/ResultList.swift Sources/QuickStudy/Views/PinnedRow.swift
git commit -m "Result/pinned rows: identity thumbnails + brand selection wash"
```

---

## Task 12: CardPreview — pips, badge, shadow, placeholder, pin tint

**Files:**
- Modify: `Sources/QuickStudy/Views/CardPreview.swift`

- [ ] **Step 1: Update the header to use ManaCostView + IdentityBadge**

In `content(card:scale:)`, replace the header `HStack` (the block starting `HStack(spacing: scale.pad(8)) {` containing name/cost/pin) with:

```swift
                HStack(spacing: scale.pad(8)) {
                    Text(card.name).font(scale.font(17, weight: .bold))
                    IdentityBadge(colors: card.colors)
                    Spacer()
                    if let cost = card.manaCost, !cost.isEmpty {
                        ManaCostView(cost: cost, size: scale.size(16))
                    }
                    pinButton(scale: scale)
                }
```

- [ ] **Step 2: Add the card-image shadow**

In `content(card:scale:)`, change the image frame line:

Replace:
```swift
            cardImage(for: card.id)
                .frame(maxWidth: 330, maxHeight: 480)
```
with:
```swift
            cardImage(for: card.identity, id: card.id)
                .frame(maxWidth: 330, maxHeight: 480)
                .dsCardShadow()
```

- [ ] **Step 3: Update the pin button tint**

In `pinButton(scale:)`, replace the `foregroundStyle` line:

Replace:
```swift
                .foregroundStyle(isPinned ? Color.accentColor : .secondary)
```
with:
```swift
                .foregroundStyle(isPinned ? DS.accent : Color.secondary)
```

- [ ] **Step 4: Update the missing-image placeholder**

Replace the whole `cardImage(for:)` function with:

```swift
    @ViewBuilder
    private func cardImage(for identity: ColorIdentity, id: String) -> some View {
        let url = Paths.imageURL(forCardID: id)
        if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.img))
        } else {
            IdentityPlaceholder(identity: identity, cornerRadius: DS.Radius.img, symbol: "photo")
        }
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickStudy/Views/CardPreview.swift
git commit -m "CardPreview: mana pips, identity badge, image shadow, tinted placeholder"
```

---

## Task 13: SearchPanel + DownloadPromptView — brand tint + prominent buttons

**Files:**
- Modify: `Sources/QuickStudy/Views/SearchPanel.swift:13-27`
- Modify: `Sources/QuickStudy/Views/DownloadPromptView.swift:21-30`

- [ ] **Step 1: Tint the SearchPanel root with brand accent**

In `Sources/QuickStudy/Views/SearchPanel.swift`, in `body`, add `.tint(DS.accent)` to the root `VStack`. Replace:

```swift
        .frame(minWidth: scale.size(860), minHeight: scale.size(520))
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
```
with:
```swift
        .frame(minWidth: scale.size(860), minHeight: scale.size(520))
        .tint(DS.accent)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
```

- [ ] **Step 2: Promote the update banner's primary button**

In `updateBanner`, replace:
```swift
            Button("Update") { model.startRefresh(skipImages: false) }
                .controlSize(.small)
```
with:
```swift
            Button("Update") { model.startRefresh(skipImages: false) }
                .buttonStyle(.brandProminent)
                .controlSize(.small)
```

- [ ] **Step 3: Promote the download-prompt primary button + tint**

In `Sources/QuickStudy/Views/DownloadPromptView.swift`, in the `.idle` case replace:
```swift
                HStack(spacing: 10) {
                    Button("Download Everything (~4 GB)") {
                        model.startRefresh(skipImages: false)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Cards Only (no images)") {
                        model.startRefresh(skipImages: true)
                    }
                }
```
with:
```swift
                HStack(spacing: 10) {
                    Button("Download Everything (~4 GB)") {
                        model.startRefresh(skipImages: false)
                    }
                    .buttonStyle(.brandProminent)
                    .keyboardShortcut(.defaultAction)
                    Button("Cards Only (no images)") {
                        model.startRefresh(skipImages: true)
                    }
                }
```

And add `.tint(DS.accent)` to the root `VStack` of `DownloadPromptView.body`. Replace:
```swift
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
```
with:
```swift
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .tint(DS.accent)
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickStudy/Views/SearchPanel.swift Sources/QuickStudy/Views/DownloadPromptView.swift
git commit -m "SearchPanel/DownloadPrompt: brand tint + prominent primary buttons"
```

---

## Task 14: SettingsView — brand tint

**Files:**
- Modify: `Sources/QuickStudy/SettingsView.swift`

- [ ] **Step 1: Inspect the root view**

Run: `grep -n "var body" Sources/QuickStudy/SettingsView.swift`
Identify the outermost container returned by the top-level `body` (likely a `Form` or `TabView`).

- [ ] **Step 2: Add `.tint(DS.accent)` to that outermost container**

Add `.tint(DS.accent)` as the last modifier on the outermost container in the top-level `body`. For example, if `body` ends with a `Form { … }` followed by modifiers, append `.tint(DS.accent)` after the final existing modifier.

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/QuickStudy/SettingsView.swift
git commit -m "SettingsView: brand accent tint"
```

---

## Task 15: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: PASS — all suites green (`SearchEngineTests`, `ColorIdentityTests`, `ManaCostTests`, `CardStoreIdentityTests`, and the pre-existing `UpdateCheckerTests`/`ImageCacheTests`/`UIScaleTests`/`AppUpdateCheckerTests`).

- [ ] **Step 2: Build the app bundle and smoke-test visually**

Run: `./scripts/build-app.sh`
Then launch `./dist/QuickStudy.app`, open the panel (⌥⌘M), and confirm:
- result-list and pinned thumbnails show mana-tinted placeholders (gold for multicolor cards) when images are missing
- selection wash is the brand violet, not the OS accent
- the preview shows colored mana pips + an identity badge, and the card image has a soft shadow
- the first-run download prompt's "Download Everything" button has the blue→violet gradient fill

- [ ] **Step 3: Final commit (if any tidy-ups were needed)**

```bash
git add -A
git commit -m "Design system: final verification tidy-ups" || echo "nothing to commit"
```

---

## Self-review notes

- **Spec coverage:** token layer (T5), brand accent (T5/T11–14), `ColorIdentity`+`Mini` (T1–3), mana pips (T4/T6), identity badge (T8/T12), placeholders (T7/T10/T12), selection wash (T11), card shadow (T12), prominent buttons (T9/T13), tests (T1–4, T15). All spec sections mapped.
- **Type consistency:** `ColorIdentity` cases, `ManaPip(glyph:identity:)`, `DS.tint(for:)`, `DS.Radius.*`, `DS.accent`, `.brandProminent`, `Thumbnail(id:identity:)`, `cardImage(for:id:)` are used identically across tasks.
- **No migration:** confirmed `colors` column pre-exists; `loadMinis` only widens its SELECT.
- **Tests stay green:** `Mini(id:name:)` retained for `SearchEngineTests`.
