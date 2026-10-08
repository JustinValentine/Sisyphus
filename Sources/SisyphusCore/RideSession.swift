import Foundation

public struct PowerSample: Sendable {
    public let seconds: Double
    public let power: Double?
    public let target: Int
    public init(seconds: Double, power: Double?, target: Int) {
        self.seconds = seconds; self.power = power; self.target = target
    }
}

public struct RideSession {
    public private(set) var elapsed: Double = 0
    public private(set) var interval: Double = 0
    public private(set) var workJoules: Double = 0
    public private(set) var crankRevolutions: Double = 0
    public private(set) var running = false
    public private(set) var samples: [PowerSample] = []
    public init() {}
    public mutating func start() { running = true }
    public mutating func pause() { running = false }
    public mutating func newInterval() { interval = 0 }
    public mutating func tick(seconds: Double, reading: BikeReading, target: Int) {
        guard running, seconds > 0, seconds.isFinite else { return }
        elapsed += seconds; interval += seconds
        if let power = reading.power { workJoules += Double(max(0, power)) * seconds }
        if let cadence = reading.cadence { crankRevolutions += max(0, cadence) / 60 * seconds }
        samples.append(PowerSample(seconds: elapsed, power: reading.power.map(Double.init), target: target))
        samples.removeAll { $0.seconds < elapsed - 180 }
    }
    public static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
