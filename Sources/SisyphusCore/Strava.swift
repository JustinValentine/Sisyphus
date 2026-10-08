import Foundation

/// Request building and response interpretation for Strava's OAuth and upload APIs.
/// Networking lives in the app; everything here is pure so it can be checked offline.
public enum Strava {
    public static let authorizeEndpoint = URL(string: "https://www.strava.com/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://www.strava.com/oauth/token")!
    public static let revokeEndpoint = URL(string: "https://www.strava.com/oauth/revoke")!
    public static let uploadsEndpoint = URL(string: "https://www.strava.com/api/v3/uploads")!
    public static let uploadScope = "activity:write"

    public static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "read,\(uploadScope)"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    public static func activityURL(_ id: Int64) -> URL { URL(string: "https://www.strava.com/activities/\(id)")! }

    /// Strava returns granted scopes comma- or space-delimited; the rider may untick any of them.
    public static func grantsUpload(_ scope: String?) -> Bool {
        (scope ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).contains { $0 == uploadScope }
    }

    public static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    // MARK: Tokens

    public struct Token: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var scope: String?
        public var athleteName: String?

        public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String? = nil, athleteName: String? = nil) {
            self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
            self.scope = scope; self.athleteName = athleteName
        }

        /// Refresh a little early so a token never expires mid-upload.
        public func needsRefresh(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) < 300 }
    }

    private struct TokenResponse: Decodable {
        struct Athlete: Decodable { var firstname: String?; var lastname: String? }
        var access_token: String
        var refresh_token: String
        var expires_at: Double
        var scope: String?
        var athlete: Athlete?
    }

    /// Decodes an authorization or refresh response. Refresh responses omit the athlete and may
    /// omit the scope, so those carry over from `previous`.
    public static func token(from data: Data, previous: Token? = nil) throws -> Token {
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        let name = response.athlete.map { [$0.firstname, $0.lastname].compactMap { $0 }.joined(separator: " ") }
        return Token(accessToken: response.access_token, refreshToken: response.refresh_token,
                     expiresAt: Date(timeIntervalSince1970: response.expires_at),
                     scope: response.scope ?? previous?.scope,
                     athleteName: (name?.isEmpty == false ? name : nil) ?? previous?.athleteName)
    }

    // MARK: Uploads

    public struct UploadStatus: Decodable, Equatable, Sendable {
        public var id: Int64?
        public var error: String?
        public var status: String?
        public var activityID: Int64?

        enum CodingKeys: String, CodingKey { case id, error, status, activityID = "activity_id" }

        public init(id: Int64? = nil, error: String? = nil, status: String? = nil, activityID: Int64? = nil) {
            self.id = id; self.error = error; self.status = status; self.activityID = activityID
        }
    }

    public enum UploadOutcome: Equatable, Sendable {
        case processing
        case ready(activityID: Int64)
        /// Strava already has this ride. The existing activity's ID, when the message includes it.
        case duplicate(activityID: Int64?)
        case failed(String)
    }

    public static func outcome(of upload: UploadStatus) -> UploadOutcome {
        if let error = upload.error, !error.isEmpty {
            if error.range(of: "duplicate of", options: .caseInsensitive) != nil {
                return .duplicate(activityID: lastNumber(in: error))
            }
            return .failed(plainText(error))
        }
        if let activity = upload.activityID { return .ready(activityID: activity) }
        return .processing
    }

    public static func multipart(fields: [(String, String)], fileField: String, filename: String,
                                 contentType: String, file: Data, boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"")
        line("Content-Type: \(contentType)")
        line("")
        body.append(file)
        line("")
        line("--\(boundary)--")
        return body
    }

    // MARK: OAuth redirect

    /// Parses the request line the browser sends to the loopback redirect, such as
    /// `GET /strava?code=abc&scope=read,activity:write&state=xyz HTTP/1.1`.
    public static func redirect(fromRequest request: String) -> (path: String, query: [String: String])? {
        guard let line = request.components(separatedBy: .newlines).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return (components.path, query)
    }

    private static func lastNumber(in text: String) -> Int64? {
        let digits = text.split(whereSeparator: { !$0.isNumber })
        return digits.last.flatMap { Int64($0) }
    }

    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
