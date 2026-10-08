import SwiftUI

/// Sisyphus and his stone, drawn in the visual language of SF Symbols: rounded strokes of one
/// weight, a detached head, and knockout gaps where near limbs cross far ones.
///
/// Everything derives from `phase`, measured in gait cycles (two steps). Ground travel, foot
/// placement and the stone's spin share one distance, so planted feet never slide and the stone
/// rolls exactly as far as he walks.
struct SisyphusPose {
    struct Parts: OptionSet {
        let rawValue: Int
        static let ground = Parts(rawValue: 1), stone = Parts(rawValue: 2), figure = Parts(rawValue: 4)
        static let all: Parts = [.ground, .stone, .figure]
    }

    var phase: Double
    /// Layers to draw. The app icon styles the stone and figure separately.
    var parts: Parts = .all
    /// The stone sits back as a secondary layer, like a hierarchical SF Symbol.
    var stoneOpacity = 0.5
    /// Stroke weight, like picking a bolder SF Symbol weight. The app icon draws heavier.
    var weight = 1.0
    /// Small pits in the stone, which turn to noise in a bold, small drawing like the icon.
    var pits = true

    private var limb: Double { Self.limbWidth * weight }
    private var torsoWidth: Double { Self.torso * weight }
    private var headRadius: Double { Self.head * (1 + (weight - 1) / 2) }

    static let slope = Angle.degrees(11)
    /// Ground covered per gait cycle: seven cycles roll the stone exactly once, and the pebbles
    /// repeat on the same beat, so the whole scene loops seamlessly every seven cycles.
    static let stride = 2 * Double.pi * stoneRadius / Double(loopCycles)
    static let loopCycles = 7
    static let stance = 0.62            // share of a cycle each foot stays planted
    static let restPhases = [0.06, 0.56] // both feet down, one forward and one back

    private static let limbWidth = 5.6
    private static let torso = 7.0
    private static let head = 5.2
    private static let thigh = 12.5, shin = 12.5
    private static let upperArm = 10.0, forearm = 9.5
    private static let stoneRadius = 19.0
    private static let stoneX = 42.2
    private static let hipHeight = 22.5
    private static let footCenter = -6.0
    private static let lift = 4.2
    private static let gap = 1.3

    /// The first resting phase at or after `phase`.
    static func nextRest(after phase: Double) -> Double {
        let cycle = phase.rounded(.down)
        let candidates = (restPhases + restPhases.map { $0 + 1 }).map { cycle + $0 }
        return candidates.first { $0 >= phase } ?? cycle + 1 + restPhases[0]
    }

    /// Maps slope coordinates (x uphill along the ground, y up from it) into a view of `size`,
    /// fitting a fixed design box so the composition holds at any size.
    static func transform(for size: CGSize) -> CGAffineTransform {
        let fit = min(size.width / 96, size.height / 60)
        return CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: fit, y: fit)
            .translatedBy(x: -22, y: 23)
            .rotated(by: -slope.radians)
            .scaledBy(x: 1, y: -1)
    }

    /// The stone's bounds in a view of `size`.
    static func stoneFrame(in size: CGSize) -> CGRect {
        // From the center and radius: a rotated rect's bounds would overstate a circle.
        let center = CGPoint(x: stoneX, y: stoneRadius).applying(transform(for: size))
        let radius = stoneRadius * min(size.width / 96, size.height / 60)
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    func draw(in context: GraphicsContext, size: CGSize) {
        var context = context
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        // Everything draws straight into the canvas, with no offscreen layers: they would cost a
        // CPU bitmap per layer per frame. Cutouts are ordered so they only bite what lies behind.
        var scene = context
        scene.concatenate(Self.transform(for: size))

        let distance = phase * Self.stride
        let gait = phase - phase.rounded(.down)

        // Body geometry, in slope coordinates.
        let bob = 0.7 * cos(4 * .pi * (gait - Self.stance / 2))
        let pelvis = CGPoint(x: 0, y: Self.hipHeight + bob)
        let lean = Angle.degrees(38 + 1.5 * sin(4 * .pi * gait)).radians
        let spine = CGVector(dx: sin(lean), dy: cos(lean))
        let neck = pelvis + spine * 14
        let shoulder = pelvis + spine * 12.5
        let head = pelvis + spine * (14 + torsoWidth / 2 + Self.gap + headRadius)
        let stone = CGPoint(x: Self.stoneX, y: Self.stoneRadius)
        func grip(_ degrees: Double) -> CGPoint {
            let angle = Angle.degrees(degrees).radians
            return stone + CGVector(dx: cos(angle), dy: sin(angle)) * (Self.stoneRadius + limb / 2)
        }
        let nearArm = Self.joint(from: shoulder, to: grip(153), Self.upperArm, Self.forearm, bendDown: true)
        let farArm = Self.joint(from: shoulder, to: grip(140), Self.upperArm, Self.forearm, bendDown: true)
        let nearLeg = Self.joint(from: pelvis, to: foot(gait), Self.thigh, Self.shin, bendDown: false)
        let farLeg = Self.joint(from: pelvis, to: foot(gait + 0.5), Self.thigh, Self.shin, bendDown: false)

        // The stone, with a crack and pits cut out so its roll reads clearly.
        if parts.contains(.stone) {
            scene.opacity = stoneOpacity
            scene.fill(Path(ellipseIn: CGRect(x: stone.x - Self.stoneRadius, y: stone.y - Self.stoneRadius,
                                              width: Self.stoneRadius * 2, height: Self.stoneRadius * 2)), with: .foreground)
            scene.opacity = 1
            scene.blendMode = .destinationOut
            let spin = -distance / Self.stoneRadius
            func onStone(_ radius: Double, _ angle: Double) -> CGPoint {
                stone + CGVector(dx: cos(angle + spin), dy: sin(angle + spin)) * (radius * Self.stoneRadius)
            }
            var crack = Path()
            crack.addLines([onStone(1.1, 0.95), onStone(0.66, 1.25), onStone(0.5, 0.82), onStone(0.2, 1.05)])
            crack.addLines([onStone(0.5, 0.82), onStone(0.62, 0.35)])
            scene.stroke(crack, with: .color(.black), style: Self.stroke(1.5))
            for (radius, angle, size) in pits ? [(0.55, 3.7, 0.16), (0.68, 4.75, 0.09)] : [] {
                let center = onStone(radius, angle)
                let r = size * Self.stoneRadius
                scene.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(.black))
            }
            for arm in [nearArm, farArm] {
                scene.stroke(Self.path(arm), with: .color(.black), style: Self.stroke(limb + Self.gap * 2))
            }
            scene.blendMode = .normal
        }

        // The figure, back to front. Near limbs cut a hairline gap into whatever lies behind them.
        if parts.contains(.figure) {
            scene.stroke(Self.path(farArm), with: .foreground, style: Self.stroke(limb))
            scene.stroke(Self.path(farLeg), with: .foreground, style: Self.stroke(limb))
            scene.stroke(Self.path([pelvis, neck]), with: .foreground, style: Self.stroke(torsoWidth))
            scene.fill(Path(ellipseIn: CGRect(x: head.x - headRadius, y: head.y - headRadius,
                                              width: headRadius * 2, height: headRadius * 2)), with: .foreground)
            for near in [nearLeg, nearArm] {
                // Start the cut part way down the limb so it doesn't notch the joint it hangs from.
                var knock = near
                knock[0] = near[0] + (near[1] - near[0]) * 0.45
                scene.blendMode = .destinationOut
                scene.stroke(Self.path(knock), with: .color(.black), style: Self.stroke(limb + Self.gap * 2))
                scene.blendMode = .normal
                scene.stroke(Self.path(near), with: .foreground, style: Self.stroke(limb))
            }
        }
        guard parts.contains(.ground) else { return }

        // The ground goes last, slipped underneath everything: a hairline hill fading toward the
        // edges, with pebbles drifting downhill as he climbs.
        let ink: Color = context.environment.colorScheme == .dark ? .white : .black
        let toView = scene.transform
        func visibility(_ x: Double) -> Double { // x along the ground, in slope coordinates
            let position = (x * toView.a + toView.tx) / size.width
            return min(1, max(0, min(position, 1 - position) / 0.2))
        }
        let left = -toView.tx / toView.a, right = (size.width - toView.tx) / toView.a
        scene.blendMode = .destinationOver
        var line = Path()
        line.move(to: CGPoint(x: left, y: 0)); line.addLine(to: CGPoint(x: right, y: 0))
        scene.stroke(line, with: .linearGradient(
            Gradient(stops: [.init(color: ink.opacity(0), location: 0), .init(color: ink.opacity(0.32), location: 0.2),
                             .init(color: ink.opacity(0.32), location: 0.8), .init(color: ink.opacity(0), location: 1)]),
            startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: right, y: 0)), lineWidth: 1.6)
        let spacing = Self.stride * Double(Self.loopCycles) / 6 // Six pebble sizes per loop.
        let sizes = [1.5, 1.0, 1.25, 0.85, 1.4, 1.1]
        let depths = [3.6, 6.0, 4.4, 7.2, 5.0, 3.2]
        for index in -8..<16 {
            let slot = ((index % sizes.count) + sizes.count) % sizes.count
            let x = Double(index) * spacing - distance.truncatingRemainder(dividingBy: spacing * Double(sizes.count)) + Double(slot) * 2.3
            let r = sizes[slot]
            let alpha = 0.32 * visibility(x)
            guard alpha > 0 else { continue }
            scene.fill(Path(ellipseIn: CGRect(x: x - r, y: -depths[slot] - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(alpha)))
        }
    }

    /// Where a foot is at a point in its own cycle: planted and carried back by the ground, then
    /// lifted and swung forward.
    private func foot(_ cyclePhase: Double) -> CGPoint {
        let p = cyclePhase - cyclePhase.rounded(.down)
        let reach = Self.stride * Self.stance / 2
        let ground = limb / 2
        if p < Self.stance {
            return CGPoint(x: Self.footCenter + reach - Self.stride * p, y: ground)
        }
        let swing = (p - Self.stance) / (1 - Self.stance)
        let ease = (1 - cos(.pi * swing)) / 2
        return CGPoint(x: Self.footCenter - reach + 2 * reach * ease, y: ground + Self.lift * sin(.pi * swing))
    }

    /// Two-bone inverse kinematics: root, joint, end.
    private static func joint(from root: CGPoint, to end: CGPoint, _ a: Double, _ b: Double, bendDown: Bool) -> [CGPoint] {
        let delta = end - root
        let reach = min(max(hypot(delta.dx, delta.dy), abs(a - b) + 0.01), a + b - 0.01)
        let direction = atan2(delta.dy, delta.dx)
        let opening = acos((a * a + reach * reach - b * b) / (2 * a * reach))
        let options = [direction + opening, direction - opening].map { root + CGVector(dx: cos($0), dy: sin($0)) * a }
        // Knees bend forward (+x); elbows hang below the line from shoulder to hand.
        let joint = bendDown ? options.min { $0.y < $1.y }! : options.max { $0.x < $1.x }!
        let tip = joint + CGVector(dx: end.x - joint.x, dy: end.y - joint.y).normalized * b
        return [root, joint, tip]
    }

    private static func path(_ points: [CGPoint]) -> Path {
        var path = Path(); path.addLines(points); return path
    }

    private static func stroke(_ width: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// Integrates cadence into gait phase. Speed changes ease in, and stopping walks on into the next
/// two-footed stance rather than freezing mid-stride.
final class GaitClock {
    private(set) var phase = SisyphusPose.restPhases[0]
    private var speed = 0.0
    private var lastTime: Double?
    private var restTarget: Double?
    private let response = 0.45

    func advance(to time: Double, cyclesPerSecond target: Double) -> Double {
        let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        if target > 0 {
            restTarget = nil
            speed += (target - speed) * (1 - exp(-dt / response))
        } else if speed > 0 {
            let rest = restTarget ?? SisyphusPose.nextRest(after: phase + speed * response)
            restTarget = rest
            let remaining = rest - phase
            // Ease in, but keep a floor on speed so he actually arrives rather than creeping forever.
            speed = max(min(speed, remaining / response), 0.06)
            guard speed * dt < remaining else { phase = rest; speed = 0; restTarget = nil; return phase }
        }
        phase += speed * dt
        return phase
    }
}

/// The animated scene. One step follows one crank revolution.
struct SisyphusScene: View {
    /// Pedal cadence in rpm while riding, zero otherwise.
    var cadence: Double
    /// Owned by the caller so the stride carries across layout changes.
    var clock: GaitClock
    @State private var idle = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = cadence > 0 && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving && idle)) { timeline in
            let phase = clock.advance(to: timeline.date.timeIntervalSinceReferenceDate,
                                      cyclesPerSecond: moving ? cadence / 120 : 0)
            Canvas { context, size in SisyphusPose(phase: phase).draw(in: context, size: size) }
        }
        // Keep frames coming briefly after pedaling stops so he can settle into a stance.
        .task(id: moving) {
            if moving { idle = false; return }
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { idle = true }
        }
        .accessibilityElement()
        .accessibilityLabel(moving ? "Sisyphus pushing his stone in time with your pedaling" : "Sisyphus resting against his stone")
    }
}

/// The app icon, layered the way macOS 26 icons are: a lit color field, a frosted glass hillside,
/// a glass boulder and a solid figure, each casting a soft shadow onto what lies behind it.
struct SisyphusIcon: View {
    /// The macOS icon grid: an 824 pt continuous-corner tile centered on a 1024 pt canvas.
    private static let side: CGFloat = 824
    private static let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
    /// Where the pose sits within the tile.
    private static let art = CGRect(x: 22, y: 214, width: 770, height: 481)
    private static let shade = Color(red: 0, green: 0.27, blue: 0.17)
    private let pose = SisyphusPose(phase: SisyphusPose.restPhases[0], stoneOpacity: 1, weight: 1.3, pits: false)

    var body: some View {
        let stone = SisyphusPose.stoneFrame(in: Self.art.size).offsetBy(dx: Self.art.minX, dy: Self.art.minY)
        let light = UnitPoint(x: (stone.minX + stone.width * 0.3) / Self.side, y: (stone.minY + stone.height * 0.25) / Self.side)
        ZStack {
            LinearGradient(colors: [Color(red: 0.33, green: 0.88, blue: 0.52), Color(red: 0, green: 0.60, blue: 0.43)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.3), .clear], center: UnitPoint(x: 0.25, y: 0), startRadius: 0, endRadius: 760)
            hill(closed: true)
                .fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            hill(closed: false).stroke(.white.opacity(0.4), lineWidth: 3)
            // Translucent glass, so it reads apart from the solid figure, with light along its upper rim.
            layer(.stone)
                .foregroundStyle(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0.42)], center: light, startRadius: 0, endRadius: stone.width * 0.95))
                .shadow(color: Self.shade.opacity(0.3), radius: 22, y: 14)
            Circle()
                .trim(from: 0.5, to: 0.85)
                .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.95), .white.opacity(0)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: stone.width - 10, height: stone.height - 10)
                .position(x: stone.midX, y: stone.midY)
            Ellipse()
                .fill(.white)
                .frame(width: stone.width * 0.24, height: stone.height * 0.13)
                .rotationEffect(.degrees(-35))
                .blur(radius: 5)
                .position(x: stone.minX + stone.width * 0.3, y: stone.minY + stone.height * 0.22)
            layer(.figure)
                .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.9, green: 0.97, blue: 0.93)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Self.shade.opacity(0.4), radius: 18, y: 14)
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(Self.tile)
        .frame(width: 1024, height: 1024)
        .environment(\.colorScheme, .dark)
    }

    private func layer(_ parts: SisyphusPose.Parts) -> some View {
        var pose = pose
        pose.parts = parts
        return Canvas { context, _ in
            var context = context
            context.translateBy(x: Self.art.minX, y: Self.art.minY)
            pose.draw(in: context, size: Self.art.size)
        }
        .frame(width: Self.side, height: Self.side)
    }

    /// The pose's ground line carried past both edges of the tile, optionally closed along the bottom.
    private func hill(closed: Bool) -> Path {
        let toTile = SisyphusPose.transform(for: Self.art.size).concatenating(CGAffineTransform(translationX: Self.art.minX, y: Self.art.minY))
        let left = CGPoint(x: -80, y: 0).applying(toTile), right = CGPoint(x: 140, y: 0).applying(toTile)
        var path = Path()
        path.move(to: left)
        path.addLine(to: right)
        if closed {
            path.addLine(to: CGPoint(x: right.x, y: Self.side + 20))
            path.addLine(to: CGPoint(x: left.x, y: Self.side + 20))
            path.closeSubpath()
        }
        return path
    }
}

private func + (point: CGPoint, vector: CGVector) -> CGPoint { CGPoint(x: point.x + vector.dx, y: point.y + vector.dy) }
private func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
private func * (vector: CGVector, scale: Double) -> CGVector { CGVector(dx: vector.dx * scale, dy: vector.dy * scale) }
private extension CGVector {
    var normalized: CGVector {
        let length = hypot(dx, dy)
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : self
    }
}
