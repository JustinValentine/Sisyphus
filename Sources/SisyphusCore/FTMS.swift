import Foundation

public struct BikeReading: Equatable, Sendable {
    public var power: Int?
    public var cadence: Double?
    public var heartRate: Int?
    public init(power: Int? = nil, cadence: Double? = nil, heartRate: Int? = nil) {
        self.power = power; self.cadence = cadence; self.heartRate = heartRate
    }
}

/// Bluetooth SIG Fitness Machine Service 1.0, Indoor Bike Data (0x2AD2).
/// Parse every flagged field, including ones the overlay does not display.
public enum FTMS {
    public static func indoorBike(_ data: Data) -> BikeReading? {
        var reader = ByteReader(data)
        guard let flags = reader.u16() else { return nil }
        var result = BikeReading()
        if flags & 1 == 0 && !reader.skip(2) { return nil } // Speed is absent when More Data is set.
        if flags & (1 << 1) != 0 && !reader.skip(2) { return nil }
        if flags & (1 << 2) != 0 {
            guard let raw = reader.u16() else { return nil }
            if raw != .max { result.cadence = Double(raw) / 2 }
        }
        for (bit, length) in [(3, 2), (4, 3), (5, 2)] {
            if flags & (1 << bit) != 0 && !reader.skip(length) { return nil }
        }
        if flags & (1 << 6) != 0 {
            guard let raw = reader.u16() else { return nil }
            let watts = Int16(bitPattern: raw)
            if watts != .max { result.power = Int(watts) }
        }
        if flags & (1 << 7) != 0 && !reader.skip(2) { return nil }
        if flags & (1 << 8) != 0 && !reader.skip(5) { return nil }
        if flags & (1 << 9) != 0 {
            guard let raw = reader.u8() else { return nil }
            if raw != 0 { result.heartRate = Int(raw) }
        }
        for (bit, length) in [(10, 1), (11, 2), (12, 2)] {
            if flags & (1 << bit) != 0 && !reader.skip(length) { return nil }
        }
        return result
    }

    public static func supportsTargetPower(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return Array(data)[4] & 0x08 != 0
    }

    public static func heartRate(_ data: Data) -> Int? {
        var reader = ByteReader(data)
        guard let flags = reader.u8() else { return nil }
        // If contact detection is supported, do not display a lost-contact reading.
        if flags & 0x04 != 0 && flags & 0x02 == 0 { return nil }
        let value = flags & 1 == 0 ? reader.u8().map(Int.init) : reader.u16().map(Int.init)
        return value.flatMap { $0 > 0 ? $0 : nil }
    }
}

public struct PowerRange: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public let increment: Int
    public init?(_ data: Data) {
        var reader = ByteReader(data)
        guard let lo = reader.u16(), let hi = reader.u16(), let step = reader.u16() else { return nil }
        minimum = max(0, Int(Int16(bitPattern: lo)))
        maximum = min(1000, Int(Int16(bitPattern: hi)))
        increment = max(1, Int(step))
        guard maximum >= minimum else { return nil }
    }
    public func clamped(_ value: Int) -> Int {
        let steps = (Double(min(max(value, minimum), maximum) - minimum) / Double(increment)).rounded()
        return minimum + min((maximum - minimum) / increment, Int(steps)) * increment
    }
}

public enum TrainerCommand: Equatable, Sendable {
    case requestControl, power(Int), start, pause, stop, reset
    public var bytes: Data {
        switch self {
        case .requestControl: return Data([0x00])
        case .reset: return Data([0x01])
        case .power(let watts):
            let value = UInt16(clamping: max(0, min(1000, watts)))
            return Data([0x05, UInt8(value & 0xff), UInt8(value >> 8)])
        case .start: return Data([0x07])
        case .pause: return Data([0x08, 0x02])
        case .stop: return Data([0x08, 0x01])
        }
    }
    public var opcode: UInt8 { bytes.first! }
    public var isPower: Bool { if case .power = self { return true }; return false }
}

public struct ControlResponse: Equatable, Sendable {
    public let opcode: UInt8
    public let result: UInt8
    public var succeeded: Bool { result == 1 }
    public init?(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count == 3, bytes[0] == 0x80 else { return nil }
        opcode = bytes[1]; result = bytes[2]
    }
    public var message: String {
        switch result {
        case 2: return "This trainer does not support that control."
        case 3: return "The trainer rejected this power target."
        case 5: return "Trainer control was lost. Close other training apps and reconnect."
        default: return "The trainer could not complete the command. Reconnect to try again."
        }
    }
}

/// Only a matching FTMS indication completes a command; a BLE write acknowledgement does not.
public struct CommandQueue {
    public private(set) var inFlight: TrainerCommand?
    public private(set) var pending: [TrainerCommand] = []
    public init() {}
    public mutating func append(_ command: TrainerCommand) {
        if command.isPower { pending.removeAll { $0.isPower } }
        pending.append(command)
    }
    public mutating func replacePending(with commands: [TrainerCommand]) { pending = commands }
    public mutating func next() -> TrainerCommand? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        inFlight = pending.removeFirst()
        return inFlight
    }
    public mutating func complete(_ response: ControlResponse) -> TrainerCommand? {
        guard let command = inFlight, command.opcode == response.opcode else { return nil }
        inFlight = nil
        if !response.succeeded { pending.removeAll() }
        return command
    }
    public mutating func clear() { inFlight = nil; pending.removeAll() }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func u16() -> UInt16? {
        guard let lo = u8(), let hi = u8() else { return nil }
        return UInt16(lo) | UInt16(hi) << 8
    }
    mutating func skip(_ count: Int) -> Bool {
        guard offset + count <= bytes.count else { return false }
        offset += count; return true
    }
}
