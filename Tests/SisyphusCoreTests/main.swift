import Foundation

// A dependency-free runner so the command line tools are sufficient; XCTest requires full Xcode.
private var failures = 0
func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { failures += 1; print("FAIL \(file):\(line): \(actual) != \(expected) \(message)") }
}
func checkNil<T>(_ actual: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if actual != nil { failures += 1; print("FAIL \(file):\(line): expected nil. \(message)") }
}
func checkTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { checkEqual(actual, true, file: file, line: line) }
func checkFalse(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { checkEqual(actual, false, file: file, line: line) }
func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "SisyphusChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a non-nil fixture value"]) }
    return value
}

let suite = SisyphusCoreTests()
let cases: [(String, () throws -> Void)] = [
    ("Trainer readings and half-RPM cadence", suite.testTypicalTrainerPacketAndHalfRPM),
    ("Optional fields and all truncated packet lengths", suite.testOptionalFieldsDoNotShiftPowerOrHeartRate),
    ("Split data records and signed power", suite.testMoreDataPacketHasNoSpeedAndPowerIsSigned),
    ("Unavailable values versus real zero readings", suite.testUnavailableReadingsAndMissingFieldsAreNotZeros),
    ("Heart rate width and contact loss", suite.testHeartRateFormatsAndContactLoss),
    ("ERG feature negotiation", suite.testPowerFeatureUsesTargetFlagsNotMeasurementFlags),
    ("Power range bounds and alignment", suite.testPowerRangeRespectsBoundsAndStep),
    ("Control encoding", suite.testCommandsUseLittleEndianSignedPowerAndCorrectPause),
    ("Acknowledgement sequencing and coalescing", suite.testQueueRequiresMatchingIndicationAndCoalescesTargets),
    ("Pause priority and command denial", suite.testPauseDiscardsUnsentTargetsAndDenialClearsCommands),
    ("Session timing, work and missing readings", suite.testSessionPausesAndNeverInventsMissingPower),
    ("Bounded history and invalid time", suite.testHistoryIsBoundedAndInvalidTimeIgnored),
    ("Ride summary, gaps and coasting", suite.testRideSummaryIgnoresGapsAndCoasting),
    ("Normalized power", suite.testSteadyPowerNormalizesToItselfAndShortRidesHaveNoNP),
    ("Ride log storage", suite.testRideLogRoundTripsThroughJSON),
    ("TCX export", suite.testTCXCarriesPowerCadenceAndHeartRateWithinSchemaLimits),
    ("Strava authorization and scopes", suite.testStravaAuthorizationAndScopes),
    ("Strava redirect parsing", suite.testStravaRedirectParsing),
    ("Strava token refresh", suite.testStravaTokensCarryAthleteAndScopeAcrossRefresh),
    ("Strava upload outcomes", suite.testStravaUploadOutcomes),
    ("Strava multipart upload", suite.testMultipartBody)
]
for (name, run) in cases {
    let before = failures
    do { try run() } catch { failures += 1; print("FAIL \(name): \(error)") }
    if before == failures { print("PASS \(name)") }
}
print("\(cases.count) checks completed; \(failures) failures.")
exit(failures == 0 ? 0 : 1)
