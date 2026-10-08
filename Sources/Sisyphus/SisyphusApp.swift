import AppKit
import SwiftUI
import Combine
import ImageIO

@main
enum SisyphusApp {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-gif"), arguments.count > index + 1 {
            writeLoop(to: arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: "--render-icon"), arguments.count > index + 1 {
            writeImage(SisyphusIcon(), to: arguments[index + 1], scale: 1)
            return
        }
        if let index = arguments.firstIndex(of: "--render"), arguments.count > index + 1 {
            let model = RideModel(); model.enablePreview()
            if arguments.contains("--compact") { model.toggleCompact() }
            if arguments.contains("--paused") { model.toggleRide() }
            model.pointer(inside: true)
            writeImage(PreviewStage(model: model).environment(\.offlineRendering, true), to: arguments[index + 1], scale: 2)
            print("Offline layout preview rendered; glass compositing is approximated.")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    /// An animated GIF of one seamless loop of the character at 90 rpm, for the README.
    @MainActor private static func writeLoop(to path: String) {
        let frames = 140
        let seconds = Double(SisyphusPose.loopCycles) / (90.0 / 120)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString, frames, nil)
        else { print("Could not create the animation."); exit(1) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds / Double(frames)]] as CFDictionary
        for frame in 0..<frames {
            let phase = SisyphusPose.restPhases[0] + Double(SisyphusPose.loopCycles) * Double(frame) / Double(frames)
            let scene = Canvas { context, size in SisyphusPose(phase: phase).draw(in: context, size: size) }
                .frame(width: 300, height: 176)
                .padding(.horizontal, 30).padding(.vertical, 22)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.33), Color(red: 0.09, green: 0.13, blue: 0.18)],
                                           startPoint: .top, endPoint: .bottom))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            guard let image = renderer.cgImage else { exit(1) }
            CGImageDestinationAddImage(destination, image, delay)
        }
        guard CGImageDestinationFinalize(destination) else { exit(1) }
    }

    @MainActor private static func writeImage<V: View>(_ content: V, to path: String, scale: CGFloat) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { print("Could not create the rendered image."); exit(1) }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)? {
        get { tracker.onChange }
        set { tracker.onChange = newValue }
    }
    private let tracker = HoverTracker()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackPointer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackPointer()
    }

    private func trackPointer() {
        guard !trackingAreas.contains(where: { $0.owner === tracker }) else { return }
        // Active even while another app is frontmost, which is the usual case mid-ride.
        // `.inVisibleRect` keeps the area matched to the view as the panel resizes.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: tracker, userInfo: nil))
    }
}

final class HoverTracker: NSResponder {
    var onChange: ((Bool) -> Void)?
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = RideModel()
    private lazy var strava = StravaService(store: model.rides)
    private let ridesNavigation = RidesNavigation()
    private var ridesWindow: NSWindow?
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.contains("--demo") { model.enablePreview() }
        else { model.trainer.restoreHeartRateSensor() }
        createPanel()
        createMenu()
        createMainMenu()
        model.onClickThrough = { [weak self] enabled in self?.panel.ignoresMouseEvents = enabled }
        model.onShowRides = { [weak self] in self?.showRides() }
        model.onRideEnded = { [weak self] ride in
            guard let self else { return }
            // Like Apple Watch, finishing a workout shows its summary.
            self.showRides(selecting: ride.id)
            self.strava.load()
            if self.strava.uploadAutomatically, self.strava.isConnected { Task { await self.strava.upload(ride.id) } }
        }
        model.confirm = { title, message, action in
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: action).hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        // @Published emits before the value changes, so use the emitted values.
        model.$compact.dropFirst().removeDuplicates().sink { [weak self] compact in
            if compact {
                // Let the readout finish morphing before the panel shrinks around it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard let self, self.model.compact else { return }
                    self.layoutPanel(compact: true)
                }
            } else {
                self?.layoutPanel(compact: false)
            }
        }.store(in: &subscriptions)
        model.$scale.dropFirst().removeDuplicates().sink { [weak self] scale in
            self?.layoutPanel(scale: scale)
        }.store(in: &subscriptions)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.handleSleep() }
        })
        if arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.model.toggleCompact()
                self.model.changeTarget(5)
                self.model.setClickThrough(true)
                self.model.setClickThrough(false)
                self.model.toggleRide()
                self.model.toggleRide()
                self.model.toggleCompact()
                self.model.updateScale(1.2)
                self.model.updateScale(1)
                print("Smoke check passed: native overlay, compact mode, sizes, ERG preview, pause/resume, click-through.")
                NSApp.terminate(nil)
            }
        }
    }

    private func createPanel() {
        let size = HUDLayout.panelSize(compact: model.compact, scale: model.scale)
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Sisyphus"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // Liquid Glass draws its own.
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        // One long-lived hosting view; SwiftUI observes the model, so layout changes never rebuild it.
        let host = OverlayHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.model.pointer(inside: inside) }
        panel.contentView = host
        panel.setAccessibilityLabel("Sisyphus cycling overlay")
        positionPanel()
        panel.orderFrontRegardless()
    }

    /// Resize around the bottom center, where the layout is anchored, so the readout stays put.
    private func layoutPanel(compact: Bool? = nil, scale: Double? = nil) {
        guard panel != nil else { return }
        let size = HUDLayout.panelSize(compact: compact ?? model.compact, scale: scale ?? model.scale)
        var frame = panel.frame
        frame.origin.x = frame.midX - size.width / 2
        frame.size = size
        if let screen = panel.screen {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - frame.height))
        }
        panel.setFrame(frame, display: true)
    }

    @objc private func positionPanel() {
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 12))
    }

    // MARK: Rides window

    func showRides(selecting id: UUID? = nil) {
        if let id { ridesNavigation.selection = id }
        if ridesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Rides"
            window.contentViewController = NSHostingController(rootView: RidesView(store: model.rides, strava: strava, navigation: ridesNavigation))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("Rides")
            ridesWindow = window
        }
        NSApp.activate()
        ridesWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Dock

    /// Clicking the Dock icon brings the overlay back, ready to use.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.clickThrough { model.setClickThrough(false) }
        showOverlay()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        add(model.isRunning ? "Pause Ride" : model.session.elapsed > 0 ? "Resume Ride" : "Start Ride", action: #selector(toggleRide), to: menu)
        add("Rides", action: #selector(openRides), to: menu)
        add("Connect Devices…", action: #selector(showDevices), to: menu)
        if model.clickThrough { add("Allow Interaction", action: #selector(toggleInteraction), to: menu) }
        return menu
    }

    /// The app's menu bar.
    private func createMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        _ = submenu("Sisyphus", [
            item("About Sisyphus", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Sisyphus", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Sisyphus", #selector(NSApplication.terminate(_:)), "q")
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a")
        ])
        let rides = item("Rides", #selector(openRides), "0")
        rides.target = self
        let overlay = item("Show Overlay", #selector(showOverlay))
        overlay.target = self
        NSApp.windowsMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            rides,
            overlay
        ])
        NSApp.mainMenu = main
    }

    // MARK: Menu bar

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mountain.2", accessibilityDescription: "Sisyphus")
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("Show Overlay", action: #selector(showOverlay), to: menu)
        add(model.clickThrough ? "Allow Interaction" : "Let Clicks Pass Through", action: #selector(toggleInteraction), to: menu)
        add("Move to Bottom of Screen", action: #selector(positionPanel), to: menu)
        menu.addItem(.separator())
        add(model.isRunning ? "Pause Ride" : model.session.elapsed > 0 ? "Resume Ride" : "Start Ride", action: #selector(toggleRide), to: menu)
        add("Connect Devices…", action: #selector(showDevices), to: menu)
        add("Rides…", action: #selector(openRides), to: menu)
        if model.demo { add("Leave Preview", action: #selector(togglePreview), to: menu) }
        else if !model.isRunning && !model.trainer.ready { add("Preview with Simulated Data", action: #selector(togglePreview), to: menu) }
        menu.addItem(.separator())
        add("Quit Sisyphus", action: #selector(quit), to: menu, key: "q")
    }
    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    @objc private func showOverlay() { panel.orderFrontRegardless() }
    @objc private func toggleInteraction() { model.setClickThrough(!model.clickThrough) }
    @objc private func toggleRide() { model.toggleRide() }
    @objc private func showDevices() { model.setClickThrough(false); showOverlay(); model.showDevices = true }
    @objc private func togglePreview() { if model.demo { model.exitPreview() } else { model.enablePreview() } }
    @objc private func openRides() { showRides() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting mid-ride keeps the ride rather than leaving it to crash recovery.
        model.saveRecording()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.demo, model.trainer.ready else { return .terminateNow }
        model.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// Offline review stage: the overlay over an original stand-in for whatever is playing underneath.
private struct PreviewStage: View {
    @ObservedObject var model: RideModel
    var body: some View {
        let size = HUDLayout.panelSize(compact: model.compact, scale: model.scale)
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.20, blue: 0.36), Color(red: 0.55, green: 0.42, blue: 0.52),
                                    Color(red: 0.93, green: 0.58, blue: 0.40)], startPoint: .top, endPoint: .bottom)
            Canvas { context, canvas in
                for layer in 0..<4 {
                    let y = canvas.height * (0.48 + Double(layer) * 0.12)
                    var hill = Path()
                    hill.move(to: CGPoint(x: 0, y: y))
                    hill.addCurve(to: CGPoint(x: canvas.width, y: y - 30 + Double(layer) * 18),
                                  control1: CGPoint(x: canvas.width * 0.3, y: y - 90 + Double(layer * 25)),
                                  control2: CGPoint(x: canvas.width * 0.6, y: y + 70))
                    hill.addLine(to: CGPoint(x: canvas.width, y: canvas.height)); hill.addLine(to: CGPoint(x: 0, y: canvas.height))
                    context.fill(hill, with: .color(Color(red: 0.10, green: 0.10 + Double(layer) * 0.02, blue: 0.18).opacity(0.45 + Double(layer) * 0.17)))
                }
            }
            OverlayView(model: model).frame(width: size.width, height: size.height).padding(.bottom, 12)
        }
        .frame(width: 1100, height: 520)
        .environment(\.colorScheme, .dark)
    }
}
