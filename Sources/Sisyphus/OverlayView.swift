import SwiftUI
import SisyphusCore

/// Geometry shared by the SwiftUI layout and the panel that hosts it. Every slot keeps its
/// height whether or not it's showing, so the readout never shifts under the pointer.
enum HUDLayout {
    static let margin: CGFloat = 18
    static let bannerHeight: CGFloat = 30
    static let gap: CGFloat = 10
    static let readout = CGSize(width: 760, height: 128)
    static let compactHeight: CGFloat = 56
    static let controlsHeight: CGFloat = 44

    static func panelSize(compact: Bool, scale: CGFloat) -> CGSize {
        let height = margin * 2 + bannerHeight + gap * 2 + (compact ? compactHeight : readout.height) + controlsHeight
        return CGSize(width: (readout.width + margin * 2) * scale, height: height * scale)
    }
}

private struct OfflineRenderingKey: EnvironmentKey { static let defaultValue = false }
private struct HUDScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var offlineRendering: Bool {
        get { self[OfflineRenderingKey.self] }
        set { self[OfflineRenderingKey.self] = newValue }
    }
    /// Overlay size multiplier. Applied to type and geometry directly so text stays sharp.
    var hudScale: CGFloat {
        get { self[HUDScaleKey.self] }
        set { self[HUDScaleKey.self] = newValue }
    }
}

private struct HUDGlass<S: Shape>: ViewModifier {
    var glass: Glass
    var tint: Color?
    var shape: S
    @Environment(\.offlineRendering) private var offline

    @ViewBuilder func body(content: Content) -> some View {
        if offline {
            // ImageRenderer can't composite window-server glass. Keep identical geometry for review.
            content
                .background(shape.fill(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.white.opacity(0.11))))
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.15)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
        } else {
            content.glassEffect(tint.map { glass.tint($0) } ?? glass, in: shape)
        }
    }
}

extension View {
    func hudGlass(_ glass: Glass = .regular, tint: Color? = nil, in shape: some Shape) -> some View {
        modifier(HUDGlass(glass: glass, tint: tint, shape: shape))
    }
}

struct OverlayView: View {
    @ObservedObject var model: RideModel
    @State private var gait = GaitClock()
    @Namespace private var glass
    private var s: CGFloat { CGFloat(model.scale) }

    var body: some View {
        GlassEffectContainer(spacing: 6 * s) {
            VStack(spacing: HUDLayout.gap * s) {
                bannerSlot
                if model.compact { compactReadout } else { readout }
                controlsSlot
            }
        }
        .padding(HUDLayout.margin * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.hudScale, s)
        .animation(.smooth(duration: 0.4), value: model.compact)
        .animation(.smooth(duration: 0.3), value: model.controlsVisible)
        .animation(.smooth(duration: 0.3), value: banner)
    }

    // MARK: Banner

    private struct Banner: Equatable {
        enum Kind { case warning, info, preview, waiting, status }
        var kind: Kind
        var text: String
    }

    private var banner: Banner? {
        if let error = model.trainer.errorMessage { return Banner(kind: .warning, text: error) }
        if let notice = model.notice { return Banner(kind: .info, text: notice) }
        if model.demo { return Banner(kind: .preview, text: "Preview · Simulated ride") }
        if model.transition { return Banner(kind: .waiting, text: model.statusText) }
        if model.controlsVisible { return Banner(kind: .status, text: model.statusText) }
        return nil
    }

    private var bannerSlot: some View {
        ZStack {
            if let banner {
                HStack(spacing: 7 * s) {
                    switch banner.kind {
                    case .warning:
                        Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    case .info:
                        Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                    case .preview:
                        Circle().fill(.orange).frame(width: 7 * s, height: 7 * s)
                    case .waiting:
                        ProgressView().controlSize(.mini)
                    case .status:
                        Circle().fill(model.trainer.ready ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary)).frame(width: 7 * s, height: 7 * s)
                    }
                    Text(banner.text).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12 * s, weight: .medium))
                .padding(.horizontal, 14 * s)
                .frame(height: HUDLayout.bannerHeight * s)
                .hudGlass(in: Capsule())
                .glassEffectID("banner", in: glass)
                .help(banner.text)
            }
        }
        .frame(maxWidth: HUDLayout.readout.width * s)
        .frame(height: HUDLayout.bannerHeight * s)
    }

    // MARK: Readout

    private var readout: some View {
        HStack(spacing: 18 * s) {
            scene.frame(width: 140 * s, height: 90 * s)
            VStack(alignment: .leading, spacing: 9 * s) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 1 * s) {
                    GridRow {
                        caption("Power", width: 116)
                        caption("Target", width: 82)
                        caption("Cadence", width: 86)
                        caption("Heart Rate", width: 104)
                        caption("Interval", width: 86)
                        caption("Total", width: 84)
                    }
                    GridRow(alignment: .lastTextBaseline) {
                        Reading(value: model.powerText, unit: "W", size: 40)
                        Reading(value: "\(model.target)", unit: "W")
                            .opacity(model.target != model.appliedTarget ? 0.5 : 1)
                            .help(model.target != model.appliedTarget ? "Waiting for the trainer to apply this target" : "ERG target power")
                        Reading(value: model.cadenceText, unit: "RPM")
                        Reading(value: model.heartText, unit: "BPM")
                        Reading(value: model.intervalText)
                            .help("Riding time at this target. Changing the target starts a new interval.")
                        Reading(value: model.elapsedText)
                    }
                }
                PowerTrace(samples: model.session.samples, target: model.appliedTarget)
                    .frame(height: 24 * s)
                    .accessibilityLabel("Power for the last three minutes")
            }
        }
        .padding(.leading, 16 * s).padding(.trailing, 22 * s)
        .frame(width: HUDLayout.readout.width * s, height: HUDLayout.readout.height * s)
        .hudGlass(in: RoundedRectangle(cornerRadius: 34 * s, style: .continuous))
        .glassEffectID("readout", in: glass)
    }

    private var compactReadout: some View {
        HStack(spacing: 18 * s) {
            scene.frame(width: 64 * s, height: 40 * s)
            Reading(value: model.powerText, unit: "W", size: 26).frame(width: 82 * s, alignment: .leading)
            Reading(value: model.cadenceText, unit: "RPM", size: 20).frame(width: 74 * s, alignment: .leading)
            Reading(value: model.heartText, unit: "BPM", size: 20)
                .frame(width: 88 * s, alignment: .leading)
            Reading(value: model.intervalText, size: 20)
        }
        .padding(.leading, 16 * s).padding(.trailing, 24 * s)
        .frame(height: HUDLayout.compactHeight * s)
        .hudGlass(in: Capsule())
        .glassEffectID("readout", in: glass)
    }

    private var scene: some View { SisyphusScene(cadence: model.animationCadence, clock: gait) }

    private func caption(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11 * s, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: width * s, alignment: .leading)
    }

    // MARK: Controls

    private var controlsSlot: some View {
        ZStack {
            if model.controlsVisible {
                HStack(spacing: 10 * s) {
                    primaryButton
                    if model.canEndRide { endButton }
                    targetStepper
                    devicesButton
                    optionsMenu
                }
            }
        }
        .frame(height: HUDLayout.controlsHeight * s)
    }

    private var primaryButton: some View {
        let (title, symbol, tint): (String, String, Color?) =
            !model.canStart ? ("Connect", "antenna.radiowaves.left.and.right", .blue)
            : model.isRunning ? ("Pause", "pause.fill", nil)
            : (model.session.elapsed > 0 ? "Resume" : "Start", "play.fill", .green)
        return Button(action: model.toggleRide) {
            HStack(spacing: 7 * s) {
                if model.transition { ProgressView().controlSize(.small) } else { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 14 * s, weight: .semibold))
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .frame(minWidth: 84 * s)
            .padding(.horizontal, 18 * s)
            .frame(height: HUDLayout.controlsHeight * s)
            .contentShape(Capsule())
        }
        .buttonStyle(HUDButtonStyle())
        .disabled(model.transition)
        .hudGlass(.regular.interactive(), tint: tint, in: Capsule())
        .glassEffectID("primary", in: glass)
        .help(model.canStart ? "Start or pause ERG mode" : "Connect your trainer")
    }

    /// Apple Watch's convention: a red End beside Resume once a ride is paused.
    private var endButton: some View {
        Button(action: model.endRide) {
            Text("End")
                .font(.system(size: 14 * s, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20 * s)
                .frame(height: HUDLayout.controlsHeight * s)
                .contentShape(Capsule())
        }
        .buttonStyle(HUDButtonStyle())
        .hudGlass(.regular.interactive(), tint: .red, in: Capsule())
        .glassEffectID("end", in: glass)
        .help(model.demo ? "End the preview" : "End and save this ride")
    }

    private var targetStepper: some View {
        HStack(spacing: 0) {
            stepButton("minus", by: -5)
            VStack(spacing: 0) {
                Text("\(model.target) W")
                    .font(.system(size: 15 * s, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(model.target)))
                    .animation(.snappy, value: model.target)
                Text("Target").font(.system(size: 9 * s, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 64 * s)
            .accessibilityElement(children: .combine)
            stepButton("plus", by: 5)
        }
        .frame(height: HUDLayout.controlsHeight * s)
        .hudGlass(in: Capsule())
        .glassEffectID("stepper", in: glass)
    }

    private func stepButton(_ symbol: String, by watts: Int) -> some View {
        let help = watts > 0 ? "Increase target by 5 watts" : "Decrease target by 5 watts"
        return Button { model.changeTarget(watts) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14 * s, weight: .semibold))
                .frame(width: HUDLayout.controlsHeight * s, height: HUDLayout.controlsHeight * s)
                .contentShape(Circle())
        }
        .buttonStyle(HUDButtonStyle())
        .disabled(model.transition)
        .help(help)
        .accessibilityLabel(help)
    }

    private var devicesButton: some View {
        Button { model.showDevices = true } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 15 * s, weight: .medium))
                .foregroundStyle(model.trainer.ready ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                .frame(width: HUDLayout.controlsHeight * s, height: HUDLayout.controlsHeight * s)
                .contentShape(Circle())
        }
        .buttonStyle(HUDButtonStyle())
        .hudGlass(.regular.interactive(), in: Circle())
        .glassEffectID("devices", in: glass)
        .help("Trainer and heart rate sensor")
        .accessibilityLabel("Devices")
        .popover(isPresented: $model.showDevices, arrowEdge: .top) { DevicePicker(model: model) }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Compact", isOn: Binding(get: { model.compact }, set: { _ in model.toggleCompact() }))
            Picker("Size", selection: Binding(get: { model.scale }, set: model.updateScale)) {
                Text("Small").tag(0.85)
                Text("Medium").tag(1.0)
                Text("Large").tag(1.2)
            }
            Button("Let Clicks Pass Through") { model.setClickThrough(true) }
            Divider()
            Button("Rides…") { model.onShowRides?() }
            if model.demo {
                Button("Leave Preview") { model.exitPreview() }
            } else {
                Button("Preview with Simulated Data") { model.enablePreview() }
                    .disabled(model.isRunning || model.trainer.ready || model.transition)
            }
            Button("Discard Ride…") { model.discardRide() }
                .disabled(!model.canEndRide)
            Divider()
            Button("Quit Sisyphus") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15 * s, weight: .semibold))
                .frame(width: HUDLayout.controlsHeight * s, height: HUDLayout.controlsHeight * s)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hudGlass(.regular.interactive(), in: Circle())
        .glassEffectID("options", in: glass)
        .help("Options")
        .accessibilityLabel("Options")
    }
}

/// A value with its unit, set like Apple's workout readouts: rounded numerals, small caps unit.
/// Live values change in place, as on Apple Watch. Rolling digits would redraw blurred text on
/// the CPU every frame of every update, which costs too much in an always-on overlay.
private struct Reading: View {
    var value: String
    var unit: String? = nil
    var size: CGFloat = 24
    @Environment(\.hudScale) private var s

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3 * s) {
            if unit == "BPM" {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.5 * s, weight: .bold))
                    .foregroundStyle(.red)
            }
            Text(value)
                .font(.system(size: size * s, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let unit {
                Text(unit)
                    .font(.system(size: max(11, size * 0.42) * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([value, unit].compactMap { $0 }.joined(separator: " "))
    }
}

/// Plain content with a soft hover wash and press fade; the glass behind provides the chrome.
private struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration) }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background(Capsule().fill(.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

struct PowerTrace: View {
    let samples: [PowerSample]
    let target: Int

    var body: some View {
        Canvas { context, size in
            let window = 180.0
            let end = samples.last?.seconds ?? window
            let start = max(0, end - window)
            // Frame the readings around the target so ERG wobble is visible rather than a flat line.
            let values = samples.compactMap(\.power) + samples.map { Double($0.target) } + [Double(target)]
            let low = values.min() ?? 0, high = values.max() ?? 1
            let middle = (low + high) / 2
            let half = max((high - low) / 2 * 1.25, 20)
            func point(_ seconds: Double, _ watts: Double) -> CGPoint {
                CGPoint(x: (seconds - start) / max(window, end - start) * size.width,
                        y: (0.5 - (watts - middle) / (half * 2)) * size.height)
            }

            var targetPath = Path()
            if samples.isEmpty {
                targetPath.move(to: point(0, Double(target))); targetPath.addLine(to: point(window, Double(target)))
            } else {
                var lastTarget: Int?
                for sample in samples {
                    let p = point(sample.seconds, Double(sample.target))
                    if let previous = lastTarget {
                        targetPath.addLine(to: point(sample.seconds, Double(previous))); targetPath.addLine(to: p)
                    } else { targetPath.move(to: p) }
                    lastTarget = sample.target
                }
            }
            var guide = context
            guide.opacity = 0.35
            guide.stroke(targetPath, with: .foreground, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            // Missing readings break the line instead of dropping to zero.
            var segments: [[CGPoint]] = [], current: [CGPoint] = []
            for sample in samples {
                if let watts = sample.power { current.append(point(sample.seconds, watts)) }
                else if !current.isEmpty { segments.append(current); current = [] }
            }
            if !current.isEmpty { segments.append(current) }
            for segment in segments where segment.count > 1 {
                var line = Path(); line.addLines(segment)
                var area = line
                area.addLine(to: CGPoint(x: segment[segment.count - 1].x, y: size.height))
                area.addLine(to: CGPoint(x: segment[0].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [.green.opacity(0.28), .green.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(.green), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            if let last = samples.last, let watts = last.power {
                let p = point(last.seconds, watts)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.green))
            }
        }
    }
}

struct DevicePicker: View {
    @ObservedObject var model: RideModel
    @ObservedObject private var connection: TrainerConnection
    init(model: RideModel) { self.model = model; connection = model.trainer }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                if connection.scanning { ProgressView().controlSize(.small) }
            }
            if model.demo {
                Text("The preview uses simulated readings. Leave it to connect your trainer.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Leave Preview") { model.exitPreview(); connection.scan() }
                    .buttonStyle(.glassProminent)
            } else {
                if connection.trainerName != nil || connection.heartRateName != nil {
                    section("Connected") {
                        if let name = connection.trainerName {
                            DeviceRow(symbol: "bicycle", name: name, detail: connection.ready ? "Ready for ERG" : connection.status) {
                                if connection.ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                else { ProgressView().controlSize(.small) }
                            }
                        }
                        if let name = connection.heartRateName {
                            if connection.trainerName != nil { Divider().padding(.leading, 40) }
                            DeviceRow(symbol: "heart.fill", tint: .red, name: name, detail: "Heart rate") {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
                section("Nearby") {
                    let nearby = connection.devices.filter { $0.name != connection.trainerName && $0.name != connection.heartRateName }
                    if nearby.isEmpty {
                        Text(connection.scanning ? "Looking for trainers and heart rate sensors…" : "Wake your trainer, then search.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(nearby.enumerated()), id: \.element.id) { index, device in
                                    if index > 0 { Divider().padding(.leading, 40) }
                                    Button { connection.connect(device) } label: {
                                        DeviceRow(symbol: device.isHeartRate ? "heart" : "bicycle", name: device.name,
                                                  detail: device.isHeartRate ? "Heart rate sensor" : "Trainer") {
                                            Text("Connect").font(.callout).foregroundStyle(.tint)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!device.isHeartRate && connection.trainerName != nil)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
                if connection.heartRateName == nil {
                    Label("Using AirPods Pro 3? Open an iPhone app that shares heart rate over Bluetooth, then search.",
                          systemImage: "airpodspro")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let message = connection.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(connection.scanning ? "Stop" : "Search") {
                        if connection.scanning { connection.stopScan() } else { connection.scan() }
                    }
                    Spacer()
                    if connection.trainerName != nil {
                        Button("Disconnect", role: .destructive) { connection.disconnect() }
                            .disabled(model.isRunning || model.transition)
                    } else {
                        Button("Try the Preview") { model.enablePreview(); model.showDevices = false }
                            .buttonStyle(.link)
                            .disabled(model.isRunning || model.transition)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct DeviceRow<Trailing: View>: View {
    var symbol: String
    var tint: Color? = nil
    var name: String
    var detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
