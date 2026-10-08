import Foundation
import SisyphusCore

extension SisyphusCoreTests {
    private var start: Date { Date(timeIntervalSince1970: 1_791_396_000) } // 2026-10-07T18:00:00Z

    func testRideSummaryIgnoresGapsAndCoasting() throws {
        var ride = RideLog(start: start)
        for second in 0..<60 {
            ride.record(BikeReading(power: second < 30 ? 100 : 300, cadence: second == 5 ? 0 : 90, heartRate: 120 + second / 10),
                        target: 200, at: start.addingTimeInterval(Double(second)))
        }
        // A paused minute, then a sample with no readings at all.
        ride.record(BikeReading(), target: 200, at: start.addingTimeInterval(120))
        ride.end = start.addingTimeInterval(125)
        let summary = ride.summary
        checkEqual(summary.movingSeconds, 61)
        checkEqual(summary.elapsedSeconds, 125)
        checkEqual(summary.averagePower, 200)
        checkEqual(summary.maximumPower, 300)
        checkEqual(summary.averageCadence, 90)
        checkEqual(summary.averageHeartRate, 123)
        checkEqual(summary.maximumHeartRate, 125)
        checkEqual(summary.workKilojoules, 12)
        // Rolling 30 s averages climb from 100 W to 300 W; NP weights the hard half heavily.
        let np = try requireValue(summary.normalizedPower)
        checkTrue(np > 200 && np < 300)
    }

    func testSteadyPowerNormalizesToItselfAndShortRidesHaveNoNP() {
        var ride = RideLog(start: start)
        for second in 0..<29 { ride.record(BikeReading(power: 250), target: 250, at: start.addingTimeInterval(Double(second))) }
        checkNil(ride.summary.normalizedPower)
        ride.record(BikeReading(power: 250), target: 250, at: start.addingTimeInterval(29))
        checkEqual(ride.summary.normalizedPower, 250)
        // An unended ride finishes at its last sample.
        checkEqual(ride.summary.elapsedSeconds, 29)
    }

    func testRideLogRoundTripsThroughJSON() throws {
        var ride = RideLog(start: start)
        ride.record(BikeReading(power: 210, cadence: 91.5, heartRate: 140), target: 210, at: start.addingTimeInterval(1.25))
        ride.record(BikeReading(), target: 215, at: start.addingTimeInterval(2.25))
        ride.stravaActivityID = 9_876_543_210
        let decoded = try JSONDecoder().decode(RideLog.self, from: JSONEncoder().encode(ride))
        checkEqual(decoded, ride)
    }

    func testTCXCarriesPowerCadenceAndHeartRateWithinSchemaLimits() throws {
        var ride = RideLog(start: start)
        ride.record(BikeReading(power: 184, cadence: 88.4, heartRate: 138), target: 185, at: start.addingTimeInterval(1))
        ride.record(BikeReading(power: -10, cadence: 300, heartRate: 0), target: 185, at: start.addingTimeInterval(2.5))
        ride.record(BikeReading(), target: 185, at: start.addingTimeInterval(3))
        let xml = try requireValue(String(data: TCX.document(for: ride), encoding: .utf8))
        checkTrue(xml.contains("<Activity Sport=\"Biking\">"))
        checkTrue(xml.contains("<Id>2026-10-07T18:00:00.000Z</Id>"))
        checkTrue(xml.contains("<Time>2026-10-07T18:00:02.500Z</Time>"))
        checkTrue(xml.contains("<ns3:Watts>184</ns3:Watts>"))
        checkTrue(xml.contains("<Cadence>88</Cadence>"))
        checkTrue(xml.contains("<HeartRateBpm><Value>138</Value></HeartRateBpm>"))
        // Negative power clamps to zero, cadence to the schema's 254 maximum, and a zero heart rate is omitted.
        checkTrue(xml.contains("<ns3:Watts>0</ns3:Watts>"))
        checkTrue(xml.contains("<Cadence>254</Cadence>"))
        checkFalse(xml.contains("<Value>0</Value>"))
        checkEqual(xml.components(separatedBy: "<Trackpoint>").count - 1, 3)
        // Every trackpoint has a time; the empty one has nothing else.
        checkTrue(xml.contains("<Time>2026-10-07T18:00:03.000Z</Time>\n          </Trackpoint>"))
        // The parser accepts it as well-formed XML.
        checkTrue(XMLParser(data: TCX.document(for: ride)).parse())
    }

    func testStravaAuthorizationAndScopes() throws {
        let url = Strava.authorizeURL(clientID: "12345", redirectURI: "http://127.0.0.1:52011/strava", state: "s t")
        let query = try requireValue(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        checkEqual(query.first { $0.name == "redirect_uri" }?.value, "http://127.0.0.1:52011/strava")
        checkEqual(query.first { $0.name == "scope" }?.value, "read,activity:write")
        checkEqual(query.first { $0.name == "state" }?.value, "s t")
        checkTrue(Strava.grantsUpload("read,activity:write"))
        checkTrue(Strava.grantsUpload("read activity:write"))
        checkFalse(Strava.grantsUpload("read,activity:read"))
        checkFalse(Strava.grantsUpload(nil))
        checkEqual(String(data: Strava.formBody([("code", "a+b/c"), ("grant_type", "authorization_code")]), encoding: .utf8),
                   "code=a%2Bb%2Fc&grant_type=authorization_code")
    }

    func testStravaRedirectParsing() throws {
        let request = "GET /strava?state=xyz&code=abc123&scope=read,activity:write HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let redirect = try requireValue(Strava.redirect(fromRequest: request))
        checkEqual(redirect.path, "/strava")
        checkEqual(redirect.query["code"], "abc123")
        checkEqual(redirect.query["scope"], "read,activity:write")
        checkEqual(Strava.redirect(fromRequest: "GET /strava?error=access_denied HTTP/1.1")?.query["error"], "access_denied")
        checkNil(Strava.redirect(fromRequest: "POST /strava HTTP/1.1"))
        checkNil(Strava.redirect(fromRequest: ""))
    }

    func testStravaTokensCarryAthleteAndScopeAcrossRefresh() throws {
        let initial = Data("""
        {"token_type":"Bearer","expires_at":1791417600,"expires_in":21600,"refresh_token":"r1","access_token":"a1",
         "scope":"read,activity:write","athlete":{"id":1,"firstname":"Ada","lastname":"Lovelace"}}
        """.utf8)
        let token = try Strava.token(from: initial)
        checkEqual(token.athleteName, "Ada Lovelace")
        checkEqual(token.expiresAt, Date(timeIntervalSince1970: 1_791_417_600))
        checkFalse(token.needsRefresh(at: token.expiresAt.addingTimeInterval(-600)))
        checkTrue(token.needsRefresh(at: token.expiresAt.addingTimeInterval(-60)))
        let refreshed = try Strava.token(from: Data(#"{"access_token":"a2","refresh_token":"r2","expires_at":1791439200,"expires_in":21600}"#.utf8),
                                         previous: token)
        checkEqual(refreshed, Strava.Token(accessToken: "a2", refreshToken: "r2", expiresAt: Date(timeIntervalSince1970: 1_791_439_200),
                                           scope: "read,activity:write", athleteName: "Ada Lovelace"))
    }

    func testStravaUploadOutcomes() throws {
        func status(_ json: String) throws -> Strava.UploadStatus { try JSONDecoder().decode(Strava.UploadStatus.self, from: Data(json.utf8)) }
        checkEqual(Strava.outcome(of: try status(#"{"id":1,"id_str":"1","external_id":"x","error":null,"status":"Your activity is still being processed.","activity_id":null}"#)),
                   .processing)
        checkEqual(Strava.outcome(of: try status(#"{"id":1,"error":null,"status":"Your activity is ready.","activity_id":9876543210123}"#)),
                   .ready(activityID: 9_876_543_210_123))
        checkEqual(Strava.outcome(of: Strava.UploadStatus(error: "ride.tcx duplicate of activity 21234316")), .duplicate(activityID: 21_234_316))
        checkEqual(Strava.outcome(of: Strava.UploadStatus(error: "ride.tcx duplicate of <a href='/activities/42' target='_blank'>activity 42</a>")),
                   .duplicate(activityID: 42))
        checkEqual(Strava.outcome(of: Strava.UploadStatus(error: "<b>Time</b> information is missing")), .failed("Time information is missing"))
    }

    func testMultipartBody() throws {
        let body = Strava.multipart(fields: [("data_type", "tcx"), ("trainer", "1")], fileField: "file", filename: "ride.tcx",
                                    contentType: "application/vnd.garmin.tcx+xml", file: Data("<xml/>".utf8), boundary: "B")
        let text = try requireValue(String(data: body, encoding: .utf8))
        checkEqual(text, "--B\r\nContent-Disposition: form-data; name=\"data_type\"\r\n\r\ntcx\r\n"
                   + "--B\r\nContent-Disposition: form-data; name=\"trainer\"\r\n\r\n1\r\n"
                   + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ride.tcx\"\r\nContent-Type: application/vnd.garmin.tcx+xml\r\n\r\n<xml/>\r\n"
                   + "--B--\r\n")
    }
}
