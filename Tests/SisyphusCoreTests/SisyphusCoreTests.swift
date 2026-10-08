import Foundation
import SisyphusCore

struct SisyphusCoreTests {
    func testTypicalTrainerPacketAndHalfRPM() {
        // Speed 31 km/h, cadence 88.5 rpm, instantaneous power 250 W.
        let reading = FTMS.indoorBike(Data([0x44, 0x00, 0x1c, 0x0c, 0xb1, 0x00, 0xfa, 0x00]))
        checkEqual(reading, BikeReading(power: 250, cadence: 88.5))
    }

    func testOptionalFieldsDoNotShiftPowerOrHeartRate() {
        // All fields through remaining time, including distance's unusual three-byte width.
        let data = Data([0xfe, 0x1f,
                         0xe8, 0x03, 0xe8, 0x03, // Instantaneous and average speed.
                         0xb4, 0, 0xaa, 0, // Cadence and average cadence.
                         0x10, 0x27, 0, // Distance.
                         5, 0, // Resistance.
                         0x2c, 1, 0xfa, 0, // Instantaneous and average power.
                         100, 0, 200, 0, 3, // Total energy, per hour, per minute.
                         151, 8, 30, 0, 60, 0])
        checkEqual(FTMS.indoorBike(data), BikeReading(power: 300, cadence: 90, heartRate: 151))
        for length in 0..<data.count {
            checkNil(FTMS.indoorBike(data.prefix(length)), "Truncated packet at byte \(length)")
        }
    }

    func testMoreDataPacketHasNoSpeedAndPowerIsSigned() {
        checkEqual(FTMS.indoorBike(Data([0x41, 0x00, 0xf6, 0xff]))?.power, -10)
        checkEqual(FTMS.indoorBike(Data([0x05, 0, 0xb4, 0]))?.cadence, 90)
    }

    func testUnavailableReadingsAndMissingFieldsAreNotZeros() {
        checkEqual(FTMS.indoorBike(Data([0x45, 0, 0xff, 0xff, 0xff, 0x7f])), BikeReading())
        checkEqual(FTMS.indoorBike(Data([1, 0])), BikeReading())
        checkEqual(FTMS.indoorBike(Data([0x45, 0, 0, 0, 0, 0])), BikeReading(power: 0, cadence: 0))
    }

    func testHeartRateFormatsAndContactLoss() {
        checkEqual(FTMS.heartRate(Data([0, 145])), 145)
        checkEqual(FTMS.heartRate(Data([1, 0x02, 0x01])), 258)
        checkEqual(FTMS.heartRate(Data([6, 145])), 145)
        checkNil(FTMS.heartRate(Data([4, 145])))
        checkNil(FTMS.heartRate(Data([1, 100])))
        checkNil(FTMS.heartRate(Data([0, 0])))
    }

    func testPowerFeatureUsesTargetFlagsNotMeasurementFlags() {
        checkFalse(FTMS.supportsTargetPower(Data([0, 0x40, 0, 0, 0, 0, 0, 0])))
        checkTrue(FTMS.supportsTargetPower(Data([0, 0x40, 0, 0, 8, 0, 0, 0])))
        checkFalse(FTMS.supportsTargetPower(Data([0, 0x40])))
    }

    func testPowerRangeRespectsBoundsAndStep() throws {
        let range = try requireValue(PowerRange(Data([50, 0, 0xf1, 1, 10, 0]))) // 50…497, step 10.
        checkEqual(range.clamped(-100), 50)
        checkEqual(range.clamped(178), 180)
        checkEqual(range.clamped(2000), 490)
        checkNil(PowerRange(Data([100, 0, 50, 0, 1, 0])))
        checkNil(PowerRange(Data([0, 0])))
    }

    func testCommandsUseLittleEndianSignedPowerAndCorrectPause() {
        checkEqual(TrainerCommand.power(300).bytes, Data([5, 0x2c, 1]))
        checkEqual(TrainerCommand.power(-20).bytes, Data([5, 0, 0]))
        checkEqual(TrainerCommand.power(20_000).bytes, Data([5, 0xe8, 3]))
        checkEqual(TrainerCommand.pause.bytes, Data([8, 2]))
        checkEqual(TrainerCommand.stop.bytes, Data([8, 1]))
    }

    func testQueueRequiresMatchingIndicationAndCoalescesTargets() throws {
        var queue = CommandQueue()
        queue.append(.requestControl); queue.append(.power(150)); queue.append(.start)
        checkEqual(queue.next(), .requestControl)
        checkNil(queue.next())
        checkNil(queue.complete(try requireValue(ControlResponse(Data([0x80, 5, 1])))))
        checkEqual(queue.inFlight, .requestControl)
        checkEqual(queue.complete(try requireValue(ControlResponse(Data([0x80, 0, 1])))), .requestControl)
        checkEqual(queue.next(), .power(150))
        _ = queue.complete(try requireValue(ControlResponse(Data([0x80, 5, 1]))))
        checkEqual(queue.next(), .start)
        _ = queue.complete(try requireValue(ControlResponse(Data([0x80, 7, 1]))))
        queue.append(.power(180)); queue.append(.power(185)); queue.append(.power(190))
        checkEqual(queue.next(), .power(190))
        checkTrue(queue.pending.isEmpty)
    }

    func testPauseDiscardsUnsentTargetsAndDenialClearsCommands() throws {
        var queue = CommandQueue()
        queue.append(.power(150)); _ = queue.next()
        queue.append(.power(300)); queue.append(.start)
        queue.replacePending(with: [.pause])
        _ = queue.complete(try requireValue(ControlResponse(Data([0x80, 5, 1]))))
        checkEqual(queue.next(), .pause)
        queue.append(.power(200))
        _ = queue.complete(try requireValue(ControlResponse(Data([0x80, 8, 5]))))
        checkNil(queue.next())
        checkNil(ControlResponse(Data([0x80, 5])))
        checkNil(ControlResponse(Data([5, 5, 1])))
    }

    func testSessionPausesAndNeverInventsMissingPower() {
        var ride = RideSession()
        ride.tick(seconds: 1, reading: BikeReading(power: 200), target: 200)
        checkEqual(ride.elapsed, 0)
        ride.start()
        ride.tick(seconds: 10, reading: BikeReading(power: 200, cadence: 90), target: 200)
        checkEqual(ride.elapsed, 10)
        checkEqual(ride.workJoules, 2000)
        checkEqual(ride.crankRevolutions, 15)
        ride.tick(seconds: 1, reading: BikeReading(), target: 200)
        checkNil(ride.samples.last?.power)
        checkEqual(ride.workJoules, 2000)
        ride.newInterval()
        ride.pause()
        ride.tick(seconds: 15, reading: BikeReading(power: 200), target: 200)
        checkEqual(ride.elapsed, 11)
        checkEqual(ride.interval, 0)
        checkEqual(RideSession.time(3661), "1:01:01")
    }

    func testHistoryIsBoundedAndInvalidTimeIgnored() {
        var ride = RideSession(); ride.start()
        for _ in 0..<500 { ride.tick(seconds: 1, reading: BikeReading(power: 150), target: 150) }
        checkEqual(ride.samples.count, 181)
        ride.tick(seconds: .infinity, reading: BikeReading(), target: 150)
        ride.tick(seconds: -1, reading: BikeReading(), target: 150)
        checkEqual(ride.elapsed, 500)
    }
}
