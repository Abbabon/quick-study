import SwiftUI

/// Brand-colored, one-shot celebration flourishes for the game. Both honour
/// Reduce Motion (render nothing) and self-clean after their single run, so they
/// cost nothing at rest. Re-trigger by changing the view's `.id`.
///
/// - `SparkBurst` — a quick sparkle pop from a point (correct answer).
/// - `Confetti`   — a gentle full-window fall (new personal best).
///
/// Only the brand + status palette is allowed to celebrate.
private let celebrateColors: [Color] = [
    Color(hex: 0x7A45B6), Color(hex: 0x3E4FB5), Color(hex: 0x9B8AF2),
    Color(hex: 0x34C759), Color(hex: 0xD6B458), Color(hex: 0xFFF5C8),
]

// MARK: - Spark burst

private struct SparkParticle: Identifiable {
    let id = Int.random(in: .min ... .max)
    let target: CGSize
    let scale: CGFloat
    let rotation: Double
    let size: CGFloat
    let isStar: Bool
    let color: Color
    let duration: Double
}

private struct SparkValues {
    var t: Double = 0
    var opacity: Double = 0
    var scale: Double = 0.2
}

/// A radial pop of stars + dots from the host's center (~0.6–0.9s, ease-out).
struct SparkBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var count = 18
    var spread: CGFloat = 132

    private let particles: [SparkParticle]

    init(count: Int = 18, spread: CGFloat = 132) {
        self.count = count
        self.spread = spread
        self.particles = (0..<count).map { i in
            let angle = (Double(i) / Double(count)) * .pi * 2 + Double.random(in: -0.3...0.3)
            let dist = CGFloat.random(in: spread * 0.45 ... spread)
            let isStar = i % 3 != 0
            return SparkParticle(
                target: CGSize(width: cos(angle) * dist, height: sin(angle) * dist),
                scale: CGFloat.random(in: 0.5...1),
                rotation: Double.random(in: -160...160),
                size: isStar ? CGFloat.random(in: 9...15) : CGFloat.random(in: 5...8),
                isStar: isStar,
                color: celebrateColors.randomElement()!,
                duration: Double.random(in: 0.62...0.94)
            )
        }
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            ZStack {
                ForEach(particles) { p in particle(p) }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func particle(_ p: SparkParticle) -> some View {
        Group {
            if p.isStar {
                Image(systemName: "sparkle")
                    .resizable()
                    .frame(width: p.size, height: p.size)
                    .foregroundStyle(p.color)
                    .shadow(color: p.color.opacity(0.67), radius: 3)
            } else {
                Circle()
                    .fill(p.color)
                    .frame(width: p.size, height: p.size)
            }
        }
        .keyframeAnimator(initialValue: SparkValues()) { view, v in
            view
                .scaleEffect(v.scale)
                .rotationEffect(.degrees(p.rotation * v.t))
                .offset(x: p.target.width * v.t, y: p.target.height * v.t)
                .opacity(v.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.t) { LinearKeyframe(1, duration: p.duration) }
            KeyframeTrack(\.scale) { LinearKeyframe(p.scale, duration: p.duration) }
            KeyframeTrack(\.opacity) {
                CubicKeyframe(1, duration: p.duration * 0.18)
                CubicKeyframe(0, duration: p.duration * 0.82)
            }
        }
    }
}

// MARK: - Confetti

private struct ConfettiParticle: Identifiable {
    let id = Int.random(in: .min ... .max)
    let leftFraction: CGFloat
    let fall: CGFloat
    let sway: CGFloat
    let spin: Double
    let width: CGFloat
    let height: CGFloat
    let isStar: Bool
    let color: Color
    let duration: Double
    let delay: Double
}

private struct ConfettiValues {
    var t: Double = 0
    var opacity: Double = 0
}

/// A brief, gentle confetti fall over the whole window (~1.7–2.9s, ease-out).
struct Confetti: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var count = 64

    private let particles: [ConfettiParticle]

    init(count: Int = 64) {
        self.count = count
        self.particles = (0..<count).map { _ in
            let strip = Double.random(in: 0...1) < 0.4
            return ConfettiParticle(
                leftFraction: CGFloat.random(in: 0...1),
                fall: CGFloat.random(in: 360...560),
                sway: CGFloat.random(in: -60...60),
                spin: Double.random(in: 180...720),
                width: strip ? CGFloat.random(in: 4...7) : CGFloat.random(in: 7...12),
                height: strip ? CGFloat.random(in: 11...18) : CGFloat.random(in: 7...12),
                isStar: !strip && Double.random(in: 0...1) < 0.5,
                color: celebrateColors.randomElement()!,
                duration: Double.random(in: 1.7...2.9),
                delay: Double.random(in: 0...0.7)
            )
        }
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(particles) { p in
                        piece(p)
                            .position(x: p.leftFraction * geo.size.width, y: -20)
                            .keyframeAnimator(initialValue: ConfettiValues()) { view, v in
                                view
                                    .offset(x: p.sway * v.t, y: p.fall * v.t)
                                    .rotationEffect(.degrees(p.spin * v.t))
                                    .opacity(v.opacity)
                            } keyframes: { _ in
                                KeyframeTrack(\.t) {
                                    LinearKeyframe(0, duration: p.delay)
                                    LinearKeyframe(1, duration: p.duration)
                                }
                                KeyframeTrack(\.opacity) {
                                    LinearKeyframe(0, duration: p.delay)
                                    CubicKeyframe(1, duration: p.duration * 0.08)
                                    CubicKeyframe(0, duration: p.duration * 0.92)
                                }
                            }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func piece(_ p: ConfettiParticle) -> some View {
        if p.isStar {
            Image(systemName: "sparkle")
                .resizable()
                .frame(width: p.width, height: p.width)
                .foregroundStyle(p.color)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(p.color)
                .frame(width: p.width, height: p.height)
        }
    }
}
