import Foundation
import SisyphusCore

// Drives the app's real model, store and Strava code against a temporary folder, a temporary
// Keychain item and a stubbed Strava, so nothing touches real data or the network.
var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("  ok  \(message)") } else { failures += 1; print("  FAIL (line \(line)) \(message)") }
}
@MainActor func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
@MainActor func wait(timeout: Double = 30, _ work: @escaping @MainActor () async -> Void) {
    var done = false
    Task { @MainActor in await work(); done = true }
    let deadline = Date().addingTimeInterval(timeout)
    while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    if !done { failures += 1; print("  FAIL timed out") }
}

final class StubStrava: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, String))?
    nonisolated(unsafe) static var log: [(String, String, String)] = []   // method, path, auth header
    nonisolated(unsafe) static var bodies: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.strava.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        Self.log.append((request.httpMethod ?? "", request.url?.path ?? "", request.value(forHTTPHeaderField: "Authorization") ?? ""))
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        let (code, json) = Self.handler?(request, body) ?? (500, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum Harness {
    @MainActor static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sisyphus-harness-\(UUID().uuidString)")
        let keychain = Keychain(service: "local.sisyphus.cycling.strava.harness", account: "credentials")
        keychain.delete()
        // exit() skips defers, so clean up explicitly.
        func finish() -> Never {
            try? FileManager.default.removeItem(at: directory)
            keychain.delete()
            print(failures == 0 ? "All harness checks passed." : "\(failures) harness checks failed.")
            exit(failures == 0 ? 0 : 1)
        }

        print("Recording, autosave and crash recovery")
        let store = RideStore(directory: directory)
        let model = RideModel(rides: store)
        let feed = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                model.trainer.onReading?(BikeReading(power: 200, cadence: 90))
                model.trainer.onHeartRate?(140)
            }
        }
        RunLoop.main.add(feed, forMode: .common)
        model.trainer.onCommand?(.start)          // The trainer acknowledges Start.
        check(model.recording != nil && model.isRunning, "starting the ride begins a recording")
        spin(32)
        let file = directory.appendingPathComponent("\(model.recording!.id.uuidString).json")
        check(FileManager.default.fileExists(atPath: file.path), "autosaved after 30 seconds")
        check(store.rides.isEmpty, "the in-progress autosave isn't listed")
        let recovered = RideStore(directory: directory)   // As if the app had crashed here.
        check(recovered.rides.count == 1 && recovered.rides[0].end != nil && recovered.rides[0].samples.count >= 30,
              "a relaunch recovers the autosaved ride (\(recovered.rides.first?.samples.count ?? 0) samples)")

        model.trainer.onCommand?(.pause)
        check(model.canEndRide, "a paused ride can be ended")
        var ended: RideLog?
        model.onRideEnded = { ended = $0 }
        model.endRide()
        let samples = ended?.samples ?? []
        check(ended != nil && store.rides.count == 1 && store.rides[0].id == ended?.id, "ending saves and lists the ride")
        check((31...33).contains(samples.count), "one sample per second of riding (\(samples.count) in ~32 s)")
        check(samples.dropFirst().allSatisfy { $0.power == 200 && $0.heartRate == 140 && $0.cadence == 90 }, "samples carry power, cadence and heart rate")
        let gaps = zip(samples, samples.dropFirst()).map { $1.offset - $0.offset }
        check(gaps.allSatisfy { $0 > 0.7 && $0 < 1.3 }, "samples are about a second apart")
        check(model.session.elapsed == 0 && model.recording == nil, "the readout resets for the next ride")
        check(ended?.end != nil && (ended?.summary.averagePower ?? 0) >= 190, "summary: \(String(describing: ended?.summary))")

        print("Discarding")
        model.trainer.onCommand?(.start); spin(1.6); model.trainer.onCommand?(.pause)
        var asked = false
        model.confirm = { _, _, _ in asked = true; return false }
        model.discardRide()
        check(asked && model.recording != nil, "cancelling the confirmation keeps the ride")
        model.confirm = { _, _, _ in true }
        model.discardRide()
        check(model.recording == nil && store.rides.count == 1 && model.session.elapsed == 0, "confirming discards it")

        print("Connection lost, then preview")
        model.trainer.onCommand?(.start); spin(2.6)
        model.trainer.onLoss?()
        check(!model.isRunning && model.recording != nil, "a lost trainer pauses but keeps the recording")
        model.enablePreview()
        check(model.demo && store.rides.count == 2, "entering the preview saves the paused ride first")
        feed.invalidate()

        print("Strava uploads (stubbed)")
        URLProtocol.registerClass(StubStrava.self)
        let expired = Strava.Token(accessToken: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-10), scope: "read,activity:write", athleteName: "Ada")
        try! keychain.write(JSONEncoder().encode(StravaService.Credentials(clientID: "42", clientSecret: "shh", token: expired)))
        let strava = StravaService(store: store, keychain: keychain)
        strava.load()
        check(strava.isConnected && strava.athleteName == "Ada", "credentials load from the Keychain")

        var polls = 0
        StubStrava.handler = { request, body in
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/oauth/token"):
                return (200, #"{"access_token":"new","refresh_token":"r2","expires_at":\#(Int(Date().timeIntervalSince1970) + 21600)}"#)
            case ("POST", "/api/v3/uploads"):
                return (201, #"{"id":77,"id_str":"77","external_id":"x","error":null,"status":"Your activity is still being processed.","activity_id":null}"#)
            case ("GET", "/api/v3/uploads/77"):
                polls += 1
                return polls < 2 ? (200, #"{"id":77,"error":null,"status":"Your activity is still being processed.","activity_id":null}"#)
                                 : (200, #"{"id":77,"error":null,"status":"Your activity is ready.","activity_id":555}"#)
            default: return (404, "{}")
            }
        }
        let first = store.rides[0].id
        wait { await strava.upload(first) }
        check(store.ride(first)?.stravaActivityID == 555 && strava.uploads[first] == nil, "upload completes with the activity ID")
        check(StubStrava.log.first?.1 == "/oauth/token" && StubStrava.bodies.first?.contains("grant_type=refresh_token") == true, "an expired token refreshes first")
        check(StubStrava.log.dropFirst().allSatisfy { $0.2 == "Bearer new" }, "API calls use the refreshed token")
        let saved = keychain.read().flatMap { try? JSONDecoder().decode(StravaService.Credentials.self, from: $0) }
        check(saved?.token?.refreshToken == "r2" && saved?.token?.athleteName == "Ada", "the rotated refresh token is saved")
        let upload = StubStrava.bodies.first { $0.contains("name=\"data_type\"") } ?? ""
        check(upload.contains("tcx") && upload.contains("name=\"trainer\"\r\n\r\n1") && upload.contains("name=\"sport_type\"\r\n\r\nRide")
              && upload.contains("<Activity Sport=\"Biking\">"), "multipart carries the TCX, trainer=1 and sport_type=Ride")
        check(polls == 2, "polls until Strava finishes processing")

        let second = store.rides[1].id
        StubStrava.handler = { _, _ in (400, #"{"id":78,"error":"sisyphus.tcx duplicate of activity 999","status":"There was an error processing your activity.","activity_id":null}"#) }
        wait { await strava.upload(second) }
        check(store.ride(second)?.stravaActivityID == 999, "a duplicate links to the existing activity")

        var third = RideLog(start: Date()); third.record(BikeReading(power: 100), target: 100, at: Date()); try! store.save(third)
        StubStrava.handler = { _, _ in (400, #"{"id":79,"error":"<b>Malformed</b> file","status":"There was an error processing your activity.","activity_id":null}"#) }
        wait { await strava.upload(third.id) }
        check(strava.uploads[third.id] == .failed("Malformed file"), "errors are reported as plain text")
        StubStrava.handler = { _, _ in (401, #"{"message":"Authorization Error"}"#) }
        wait { await strava.upload(third.id) }
        check(!strava.isConnected && strava.uploads[third.id] == .failed("Strava signed Sisyphus out. Connect again to upload."), "a revoked token signs out")

        print("OAuth redirect listener")
        wait {
            do {
                let redirect = try await LoopbackRedirect.start()
                check(redirect.port > 0 && redirect.uri.hasPrefix("http://127.0.0.1:"), "listens on loopback at \(redirect.uri)")
                let curl = Process()
                curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                let pipe = Pipe(); curl.standardOutput = pipe
                curl.arguments = ["-s", "\(redirect.uri)?state=S1&code=abc123&scope=read,activity:write"]
                try curl.run()
                let query = try await redirect.response(timeout: 10)
                curl.waitUntilExit()
                let page = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                check(query["code"] == "abc123" && query["state"] == "S1" && Strava.grantsUpload(query["scope"]), "captures the code, state and scope")
                check(page.contains("connected to Strava"), "the browser gets a confirmation page")
            } catch { check(false, "redirect listener threw \(error)") }
        }

        finish()
    }
}
