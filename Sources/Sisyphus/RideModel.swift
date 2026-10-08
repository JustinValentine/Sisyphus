import SwiftUI
import Combine
import SisyphusCore

@MainActor
final class RideModel: ObservableObject {
    let trainer = TrainerConnection()
    let rides: RideStore
    @Published var reading = BikeReading()
    @Published var session = RideSession()
    @Published var target = 150
    @Published var appliedTarget = 150
    @Published var demo = false
    @Published var showDevices = false
    @Published var compact = false
    @Published var clickThrough = false
    @Published var scale: Double = 1
    @Published var transition = false
    @Published var notice: String?
    /// The pointer is over the overlay; controls stay hidden mid-ride until then.
    @Published private(set) var pointerInside = false
    var onClickThrough: ((Bool) -> Void)?
    var onShowRides: (() -> Void)?
    /// Called with each ride the rider ends, after it's saved.
    var onRideEnded: ((RideLog) -> Void)?
    /// Asks the rider to confirm a destructive action: title, message, action button.
    var confirm: ((String, String, String) -> Bool)?
    /// The ride being recorded. Simulated preview rides are never recorded.
    private(set) var recording: RideLog?
    private var recordedSeconds = 0
    private var autosavedSeconds = 0
    private var ticker: Timer?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var powerAt: Double = 0
    private var cadenceAt: Double = 0
    private var heartAt: Double = 0
    private var cancellables = Set<AnyCancellable>()
    private var recordedTick: Double = 0
    private var demoTime: Double = 0
    private var demoSampleAt: Double = 0
    private var quitting: (() -> Void)?
    private var hideControls: DispatchWorkItem?
    private var clearNotice: DispatchWorkItem?

    init(rides: RideStore? = nil) {
        self.rides = rides ?? RideStore()
        let saved = UserDefaults.standard.integer(forKey: "targetWatts")
        if saved > 0 { target = min(1000, saved); appliedTarget = target }
        trainer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        trainer.onReading = { [weak self] packet in self?.receive(packet) }
        trainer.onHeartRate = { [weak self] bpm in
            guard let self, !self.demo else { return }
            self.reading.heartRate = bpm
            self.heartAt = ProcessInfo.processInfo.systemUptime
        }
        trainer.onCommand = { [weak self] command in self?.didComplete(command) }
        trainer.onLoss = { [weak self] in
            guard let self else { return }
            self.session.pause(); self.transition = false; self.reading = BikeReading()
            self.finishQuitting()
        }
        // The character animates on its own display-linked timeline, so this only drives timers and readings.
        ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    var isRunning: Bool { session.running }
    var canStart: Bool { demo || trainer.ready }
    var statusText: String {
        if demo { return "Preview · simulated ride" }
        if transition { return "Waiting for trainer…" }
        if isRunning { return "ERG · \(trainer.trainerName ?? "Connected")" }
        if session.elapsed > 0, trainer.ready { return "Paused" }
        return trainer.status
    }
    var powerText: String { reading.power.map(String.init) ?? "--" }
    var cadenceText: String { reading.cadence.map { String(Int($0.rounded())) } ?? "--" }
    var heartText: String { reading.heartRate.map(String.init) ?? "--" }
    var elapsedText: String { RideSession.time(session.elapsed) }
    var intervalText: String { RideSession.time(session.interval) }
    /// Cadence that drives the character: zero unless riding and actually producing power.
    var animationCadence: Double {
        guard isRunning, (reading.power ?? 0) > 0 else { return 0 }
        return min(150, max(0, reading.cadence ?? 0))
    }
    var controlsVisible: Bool { !isRunning || transition || pointerInside || showDevices }
    var canEndRide: Bool { !isRunning && !transition && session.elapsed > 0 }

    func pointer(inside: Bool) {
        hideControls?.cancel()
        if inside { pointerInside = true; return }
        // Linger so the controls don't flicker while the pointer crosses the gap below the readout.
        let work = DispatchWorkItem { [weak self] in self?.pointerInside = false }
        hideControls = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func show(_ message: String, for seconds: Double) {
        notice = message
        clearNotice?.cancel()
        let work = DispatchWorkItem { [weak self] in if self?.notice == message { self?.notice = nil } }
        clearNotice = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func toggleRide() {
        guard !transition else { return }
        notice = nil
        guard canStart else { showDevices = true; return }
        if demo {
            if isRunning { session.pause(); reading = BikeReading() }
            else { session.start() }
        } else {
            transition = true
            if isRunning { trainer.pause() }
            else {
                target = trainer.powerRange?.clamped(target) ?? target
                trainer.start(watts: target)
            }
        }
    }

    func changeTarget(_ amount: Int) { setTarget(target + amount) }
    func setTarget(_ watts: Int) {
        let requested = min(1000, max(0, watts))
        let value = demo ? requested : trainer.powerRange?.clamped(requested) ?? requested
        guard value != target else { return }
        target = value
        UserDefaults.standard.set(value, forKey: "targetWatts")
        if demo || !isRunning {
            if appliedTarget != value { session.newInterval() }
            appliedTarget = value
        } else if !transition { trainer.setPower(value) }
    }

    /// Saves the paused ride and clears the readout for the next one.
    func endRide() {
        guard canEndRide else { return }
        guard !demo, recording != nil else {
            session = RideSession()
            if demo { show("Preview rides aren’t saved.", for: 4) }
            return
        }
        guard let ride = saveRecording() else { return }
        session = RideSession()
        show("Ride saved.", for: 4)
        onRideEnded?(ride)
    }

    func discardRide() {
        guard canEndRide else { return }
        if recording != nil, confirm?("Discard this ride?", "\(elapsedText) of riding won’t be saved.", "Discard") == false { return }
        if let ride = recording { rides.delete(ride.id) }
        recording = nil
        session = RideSession()
    }

    /// Ends and saves the recording, if any. Used when ending a ride and when quitting mid-ride.
    @discardableResult func saveRecording() -> RideLog? {
        guard var ride = recording else { return nil }
        recording = nil
        guard !ride.samples.isEmpty else { rides.delete(ride.id); return nil }
        ride.end = Date()
        do {
            try rides.save(ride)
            return ride
        } catch {
            recording = ride
            notice = "Couldn’t save this ride: \(error.localizedDescription)"
            return nil
        }
    }

    func enablePreview() {
        guard !isRunning, !transition, !trainer.ready else { return }
        // A ride paused by a lost connection is kept, not overwritten by the simulation.
        if saveRecording() != nil { show("Your paused ride was saved.", for: 4) }
        trainer.disconnect()
        demo = true; target = 185; appliedTarget = 185
        session = RideSession(); session.start()
        for index in 0..<728 {
            let t = Double(index)
            if index == 540 { session.newInterval() }
            session.tick(seconds: 1, reading: BikeReading(power: Int(185 + sin(t * 0.19) * 7 + sin(t * 0.57) * 3), cadence: 88, heartRate: 138), target: 185)
        }
        reading = BikeReading(power: 184, cadence: 88, heartRate: 138)
        notice = nil
    }

    func exitPreview() {
        guard demo else { return }
        session = RideSession(); reading = BikeReading(); demo = false
        target = max(0, min(1000, UserDefaults.standard.integer(forKey: "targetWatts")))
        if target == 0 { target = 150 }
        appliedTarget = target
    }

    func toggleCompact() { compact.toggle() }
    func updateScale(_ value: Double) { scale = value }
    func setClickThrough(_ value: Bool) {
        clickThrough = value
        onClickThrough?(value)
        if value { show("Clicks now pass through. Use the menu bar icon to interact again.", for: 5) }
        else if notice?.hasPrefix("Clicks now pass through") == true { notice = nil }
    }

    func handleSleep() {
        if !demo, trainer.ready, isRunning || transition { trainer.pause(); transition = true }
        session.pause()
        if !demo { notice = "Ride paused while your Mac was asleep." }
    }

    /// Finish the FTMS stop/reset sequence before closing the Bluetooth connection.
    func prepareToQuit(_ completion: @escaping () -> Void) {
        guard !demo, trainer.ready else { completion(); return }
        quitting = completion
        session.pause(); transition = true
        trainer.stop()
    }

    private func finishQuitting() {
        let action = quitting; quitting = nil; action?()
    }

    private func didComplete(_ command: TrainerCommand) {
        switch command {
        case .power(let watts):
            if appliedTarget != watts { session.newInterval() }
            appliedTarget = watts
        case .start:
            session.start(); transition = false
            powerAt = ProcessInfo.processInfo.systemUptime
            if recording == nil {
                recording = RideLog(start: Date())
                recordedSeconds = Int(session.elapsed)
                autosavedSeconds = recordedSeconds
            }
        case .pause, .stop:
            session.pause(); transition = false
        case .reset: finishQuitting()
        default: break
        }
    }

    private func receive(_ packet: BikeReading) {
        guard !demo else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let watts = packet.power { reading.power = watts; powerAt = now }
        if let rpm = packet.cadence { reading.cadence = rpm; cadenceAt = now }
        if let bpm = packet.heartRate, trainer.heartRateName == nil { reading.heartRate = bpm; heartAt = now }
    }

    /// Logs one sample per second of active riding, autosaving every 30 seconds so a crash or
    /// power cut loses at most that much.
    private func record() {
        // Include riding time not yet handed to the session, which it takes in half-second steps.
        let active = session.elapsed + recordedTick
        guard isRunning, !demo, recording != nil, Int(active) > recordedSeconds else { return }
        recordedSeconds = Int(active)
        // Stamp the moment the second elapsed rather than the tick that noticed it, so samples sit
        // a second apart. Mutate in place to avoid copying the samples.
        recording?.record(reading, target: appliedTarget, at: Date().addingTimeInterval(Double(recordedSeconds) - active))
        if recordedSeconds - autosavedSeconds >= 30, let ride = recording {
            autosavedSeconds = recordedSeconds
            try? rides.write(ride)
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - previousTick
        previousTick = now
        guard dt > 0 else { return }
        if dt > 3 {
            // A sleeping Mac must never silently resume an old ERG session.
            if isRunning {
                session.pause()
                if !demo { trainer.disconnect(); notice = "Ride paused while your Mac was asleep." }
            }
            return
        }
        if demo, isRunning {
            demoTime += dt
            // Report once a second, like a trainer's Indoor Bike Data notifications.
            if demoTime - demoSampleAt >= 1 {
                demoSampleAt = demoTime
                reading = BikeReading(power: max(0, Int(Double(target) + sin(demoTime * 0.8) * 5 + sin(demoTime * 2.1) * 2)),
                                      cadence: 88 + sin(demoTime * 0.25) * 2, heartRate: 138 + Int(sin(demoTime * 0.1) * 2))
            }
        } else if !demo {
            if now - powerAt > 3, reading.power != nil { reading.power = nil }
            if now - cadenceAt > 3, reading.cadence != nil { reading.cadence = nil }
            if now - heartAt > 5, reading.heartRate != nil { reading.heartRate = nil }
            if isRunning, now - powerAt > 8, !transition {
                trainer.pause(); transition = true
                notice = "Power readings stopped. The ride is pausing."
            }
        }
        recordedTick += dt
        if recordedTick >= 0.5 {
            if isRunning { session.tick(seconds: recordedTick, reading: reading, target: appliedTarget) }
            recordedTick = 0
        }
        record()
    }
}
