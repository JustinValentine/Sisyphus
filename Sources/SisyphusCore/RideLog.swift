import Foundation

/// A ride as recorded for history and export: one sample per second of active riding.
/// Pauses appear as gaps between sample times, never as invented zeros.
public struct RideLog: Codable, Identifiable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        /// Seconds since the ride's start date.
        public var offset: Double
        public var power: Int?
        public var cadence: Double?
        public var heartRate: Int?
        public var target: Int

        public init(offset: Double, power: Int?, cadence: Double?, heartRate: Int?, target: Int) {
            self.offset = offset; self.power = power; self.cadence = cadence; self.heartRate = heartRate; self.target = target
        }

        // Short keys: an hour of riding is 3,600 samples.
        enum CodingKeys: String, CodingKey { case offset = "t", power = "p", cadence = "c", heartRate = "h", target = "g" }
    }

    public var id: UUID
    public var start: Date
    /// Set when the rider ends the ride. Nil while recording, or if the app quit mid-ride.
    public var end: Date?
    public var samples: [Sample]
    /// The Strava activity this ride became, once uploaded.
    public var stravaActivityID: Int64?

    public init(id: UUID = UUID(), start: Date) {
        self.id = id; self.start = start; samples = []
    }

    public mutating func record(_ reading: BikeReading, target: Int, at date: Date) {
        samples.append(Sample(offset: date.timeIntervalSince(start), power: reading.power, cadence: reading.cadence,
                              heartRate: reading.heartRate, target: target))
    }

    /// The end time, or the last sample's time for a ride that was never ended.
    public var finish: Date { end ?? start.addingTimeInterval(samples.last?.offset ?? 0) }

    public var summary: RideSummary { RideSummary(self) }
}

public struct RideSummary: Equatable, Sendable {
    public var movingSeconds: Int
    public var elapsedSeconds: Int
    public var averagePower: Int?
    public var normalizedPower: Int?
    public var maximumPower: Int?
    public var averageCadence: Int?
    public var averageHeartRate: Int?
    public var maximumHeartRate: Int?
    public var workKilojoules: Int

    public init(_ ride: RideLog) {
        let samples = ride.samples
        movingSeconds = samples.count
        elapsedSeconds = max(0, Int(ride.finish.timeIntervalSince(ride.start).rounded()))
        let power = samples.compactMap(\.power).map { max(0, $0) }
        averagePower = Self.mean(power.map(Double.init))
        maximumPower = power.max()
        normalizedPower = Self.normalized(power)
        // Coasting zeros are excluded, as on most head units.
        averageCadence = Self.mean(samples.compactMap(\.cadence).filter { $0 > 0 })
        let heart = samples.compactMap(\.heartRate).filter { $0 > 0 }
        averageHeartRate = Self.mean(heart.map(Double.init))
        maximumHeartRate = heart.max()
        workKilojoules = Int((Double(power.reduce(0, +)) / 1000).rounded())
    }

    private static func mean(_ values: [Double]) -> Int? {
        values.isEmpty ? nil : Int((values.reduce(0, +) / Double(values.count)).rounded())
    }

    /// Fourth-power mean of the 30-second rolling average, per Coggan.
    private static func normalized(_ power: [Int]) -> Int? {
        guard power.count >= 30 else { return nil }
        var window = power.prefix(30).reduce(0, +)
        var total = pow(Double(window) / 30, 4)
        for index in 30..<power.count {
            window += power[index] - power[index - 30]
            total += pow(Double(window) / 30, 4)
        }
        return Int(pow(total / Double(power.count - 29), 0.25).rounded())
    }
}

/// Garmin Training Center (TCX) v2, the format Strava reads for power, cadence and heart rate.
public enum TCX {
    public static func document(for ride: RideLog) -> Data {
        let summary = ride.summary
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = time.string(from: ride.start)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" \
        xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
        xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="Biking">
              <Id>\(start)</Id>
              <Lap StartTime="\(start)">
                <TotalTimeSeconds>\(summary.movingSeconds)</TotalTimeSeconds>
                <DistanceMeters>0</DistanceMeters>
                <Calories>\(min(summary.workKilojoules, Int(UInt16.max)))</Calories>

        """
        // Work in kJ is a good estimate of food calories burned: muscle efficiency (~24%) nearly
        // cancels the kJ-to-kcal conversion (4.184).
        if let average = summary.averageHeartRate { xml += "        <AverageHeartRateBpm><Value>\(byte(average))</Value></AverageHeartRateBpm>\n" }
        if let maximum = summary.maximumHeartRate { xml += "        <MaximumHeartRateBpm><Value>\(byte(maximum))</Value></MaximumHeartRateBpm>\n" }
        xml += "        <Intensity>Active</Intensity>\n"
        if let cadence = summary.averageCadence { xml += "        <Cadence>\(min(cadence, 254))</Cadence>\n" }
        xml += "        <TriggerMethod>Manual</TriggerMethod>\n        <Track>\n"
        for sample in ride.samples {
            xml += "          <Trackpoint>\n            <Time>\(time.string(from: ride.start.addingTimeInterval(sample.offset)))</Time>\n"
            if let bpm = sample.heartRate, bpm > 0 { xml += "            <HeartRateBpm><Value>\(byte(bpm))</Value></HeartRateBpm>\n" }
            if let rpm = sample.cadence { xml += "            <Cadence>\(min(254, max(0, Int(rpm.rounded()))))</Cadence>\n" }
            if let watts = sample.power {
                xml += "            <Extensions><ns3:TPX><ns3:Watts>\(min(Int(UInt16.max), max(0, watts)))</ns3:Watts></ns3:TPX></Extensions>\n"
            }
            xml += "          </Trackpoint>\n"
        }
        xml += "        </Track>\n"
        if let average = summary.averagePower, let maximum = summary.maximumPower {
            xml += "        <Extensions><ns3:LX><ns3:AvgWatts>\(average)</ns3:AvgWatts><ns3:MaxWatts>\(maximum)</ns3:MaxWatts></ns3:LX></Extensions>\n"
        }
        xml += """
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return Data(xml.utf8)
    }

    private static func byte(_ value: Int) -> Int { min(255, max(1, value)) }
}
