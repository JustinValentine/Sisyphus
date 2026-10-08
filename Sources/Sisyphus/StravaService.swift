import AppKit
import Network
import Security
import SisyphusCore

/// Connects to the rider's own Strava API application and uploads rides to it.
@MainActor
final class StravaService: ObservableObject {
    struct Credentials: Codable {
        var clientID: String
        var clientSecret: String
        var token: Strava.Token?
    }

    enum UploadState: Equatable {
        case uploading
        case failed(String)
    }

    @Published private(set) var credentials: Credentials?
    @Published private(set) var connecting = false
    @Published var connectError: String?
    @Published private(set) var uploads: [UUID: UploadState] = [:]
    @Published var uploadAutomatically = UserDefaults.standard.bool(forKey: "stravaAutoUpload") {
        didSet { UserDefaults.standard.set(uploadAutomatically, forKey: "stravaAutoUpload") }
    }

    private let store: RideStore
    private let keychain: Keychain
    private var loaded = false
    private var pendingRedirect: LoopbackRedirect?

    init(store: RideStore, keychain: Keychain = Keychain(service: "local.sisyphus.cycling.strava", account: "credentials")) {
        self.store = store
        self.keychain = keychain
    }

    var isConnected: Bool { credentials?.token != nil }
    var athleteName: String? { credentials?.token?.athleteName }

    /// Reads the Keychain on first use rather than at launch, so an access prompt only appears
    /// when the rider actually goes looking for Strava.
    func load() {
        guard !loaded else { return }
        loaded = true
        credentials = keychain.read().flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    }

    // MARK: Connecting

    func connect(clientID: String, clientSecret: String) async {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else { connectError = "Enter your Client ID and Client Secret."; return }
        connecting = true
        connectError = nil
        defer { connecting = false; pendingRedirect = nil }
        do {
            let redirect = try await LoopbackRedirect.start()
            pendingRedirect = redirect
            let state = UUID().uuidString
            NSWorkspace.shared.open(Strava.authorizeURL(clientID: clientID, redirectURI: redirect.uri, state: state))
            let query = try await redirect.response(timeout: 300)
            guard query["state"] == state else { throw StravaError("That response wasn’t for this request. Try connecting again.") }
            if query["error"] != nil { throw StravaError("Strava access wasn’t allowed.") }
            guard let code = query["code"] else { throw StravaError("Strava didn’t return an authorization code.") }
            guard Strava.grantsUpload(query["scope"]) else {
                throw StravaError("Sisyphus needs permission to upload activities. Connect again and leave that box checked.")
            }
            let data = try await post(Strava.tokenEndpoint, form: [("client_id", clientID), ("client_secret", clientSecret),
                                                                   ("code", code), ("grant_type", "authorization_code")])
            try save(Credentials(clientID: clientID, clientSecret: clientSecret, token: Strava.token(from: data)))
            NSApp.activate()
        } catch is CancellationError {
        } catch {
            connectError = Self.message(for: error)
        }
    }

    func cancelConnecting() { pendingRedirect?.cancel() }

    /// Revokes access and forgets the tokens, keeping the API application details for next time.
    func disconnect() async {
        guard var credentials, let token = credentials.token else { return }
        var request = URLRequest(url: Strava.revokeEndpoint)
        request.httpMethod = "POST"
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Strava.formBody([("token", token.refreshToken), ("token_type_hint", "refresh_token")])
        _ = try? await URLSession.shared.data(for: request) // Best effort; the tokens are forgotten regardless.
        credentials.token = nil
        try? save(credentials)
    }

    // MARK: Uploading

    func upload(_ id: UUID) async {
        load()
        guard let ride = store.ride(id), ride.stravaActivityID == nil, uploads[id] != .uploading else { return }
        uploads[id] = .uploading
        do {
            let boundary = "Sisyphus-\(UUID().uuidString)"
            var request = URLRequest(url: Strava.uploadsEndpoint)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Strava.multipart(
                fields: [("data_type", "tcx"), ("sport_type", "Ride"), ("trainer", "1"),
                         ("external_id", "sisyphus-\(ride.id.uuidString).tcx")],
                fileField: "file", filename: "sisyphus-\(ride.id.uuidString).tcx",
                contentType: "application/vnd.garmin.tcx+xml", file: TCX.document(for: ride), boundary: boundary)
            var status = try await send(request)
            // Strava processes uploads asynchronously; it suggests polling no more than once a second.
            for _ in 0..<40 {
                switch Strava.outcome(of: status) {
                case .ready(let activity), .duplicate(.some(let activity)):
                    var saved = store.ride(id) ?? ride
                    saved.stravaActivityID = activity
                    try store.save(saved)
                    uploads[id] = nil
                    return
                case .duplicate(nil):
                    throw StravaError("Strava already has this ride.")
                case .failed(let message):
                    throw StravaError(message)
                case .processing:
                    guard let upload = status.id else { throw StravaError("Strava didn’t return an upload to check on.") }
                    try await Task.sleep(for: .seconds(1.5))
                    status = try await send(URLRequest(url: Strava.uploadsEndpoint.appendingPathComponent(String(upload))))
                }
            }
            throw StravaError("Strava is still processing this ride. Check Strava in a few minutes.")
        } catch {
            uploads[id] = .failed(Self.message(for: error))
        }
    }

    // MARK: Requests

    /// Sends an authorized API request, refreshing the access token first if it's about to expire.
    private func send(_ request: URLRequest) async throws -> Strava.UploadStatus {
        var request = request
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            credentials?.token = nil
            if let credentials { try? save(credentials) }
            throw StravaError("Strava signed Sisyphus out. Connect again to upload.")
        }
        // Upload errors, including duplicates, arrive as a 400 with the usual status body.
        if let status = try? JSONDecoder().decode(Strava.UploadStatus.self, from: data), status.id != nil || status.error != nil {
            return status
        }
        throw StravaError("Strava returned an unexpected response (HTTP \(code)).")
    }

    private func accessToken() async throws -> String {
        guard var credentials, let token = credentials.token else { throw StravaError("Connect Strava to upload rides.") }
        guard token.needsRefresh(at: Date()) else { return token.accessToken }
        let data = try await post(Strava.tokenEndpoint, form: [("client_id", credentials.clientID), ("client_secret", credentials.clientSecret),
                                                               ("grant_type", "refresh_token"), ("refresh_token", token.refreshToken)])
        // Strava invalidates the old refresh token as soon as it issues a new one, so save immediately.
        credentials.token = try Strava.token(from: data, previous: token)
        try save(credentials)
        return credentials.token!.accessToken
    }

    private func post(_ url: URL, form: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Strava.formBody(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 400 || code == 401 {
                throw StravaError("Strava didn’t accept those details. Check the Client ID and Client Secret.")
            }
            throw StravaError("Strava returned an error (HTTP \(code)).")
        }
        return data
    }

    private func save(_ credentials: Credentials) throws {
        try keychain.write(JSONEncoder().encode(credentials))
        self.credentials = credentials
        loaded = true
    }

    private static func message(for error: Error) -> String {
        if let error = error as? StravaError { return error.message }
        if let error = error as? URLError {
            return error.code == .notConnectedToInternet ? "You’re offline. Try again when you’re connected." : error.localizedDescription
        }
        return error.localizedDescription
    }
}

struct StravaError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One generic-password Keychain item.
struct Keychain {
    let service: String
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        var result: AnyObject?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    func delete() { SecItemDelete(query as CFDictionary) }

    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Sisyphus Strava connection"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StravaError("Couldn’t save to the Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw StravaError("Couldn’t save to the Keychain (\(status)).")
        }
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that catches Strava's OAuth redirect from the browser.
/// Strava allow-lists loopback redirects, so no web server or custom URL scheme is needed.
final class LoopbackRedirect: @unchecked Sendable {
    private let listener: NWListener
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var started = false // All callbacks arrive on the main queue.
    private(set) var port: UInt16 = 0

    var uri: String { "http://127.0.0.1:\(port)/strava" }

    private init(listener: NWListener) { self.listener = listener }

    @MainActor static func start() async throws -> LoopbackRedirect {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let redirect = LoopbackRedirect(listener: try NWListener(using: parameters))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            redirect.listener.stateUpdateHandler = { state in
                guard !redirect.started else { return }
                switch state {
                case .ready:
                    redirect.started = true
                    redirect.port = redirect.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    redirect.started = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            redirect.listener.newConnectionHandler = { [weak redirect] connection in redirect?.handle(connection) }
            redirect.listener.start(queue: .main)
        }
        return redirect
    }

    /// Waits for the browser to arrive at the redirect, returning its query parameters.
    func response(timeout seconds: Double) async throws -> [String: String] {
        defer { listener.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.main.async {
                    if let result = self.result { continuation.resume(with: result); return }
                    self.waiter = continuation
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                        self.finish(.failure(StravaError("Strava didn’t respond in time. Try connecting again.")))
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { self.finish(.failure(CancellationError())) }
        }
    }

    func cancel() { DispatchQueue.main.async { self.finish(.failure(CancellationError())) } }

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            guard let self, let redirect = Strava.redirect(fromRequest: request), redirect.path == "/strava" else {
                Self.reply(connection, status: "404 Not Found", body: "")
                return
            }
            let approved = redirect.query["code"] != nil
            Self.reply(connection, status: "200 OK", body: Self.page(approved ? "You’re connected to Strava." : "Strava wasn’t connected.",
                                                                       detail: "You can close this tab and return to Sisyphus."))
            self.finish(.success(redirect.query))
        }
    }

    private static func reply(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ title: String, detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Sisyphus</title>
        <style>body{font:15px -apple-system,system-ui;display:grid;place-items:center;height:90vh;margin:0;color:#1d1d1f;background:#f5f5f7}
        @media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}}h1{font-size:22px;font-weight:600;margin:0 0 6px}p{margin:0;opacity:.6}</style>
        </head><body><div><h1>\(title)</h1><p>\(detail)</p></div></body></html>
        """
    }
}
