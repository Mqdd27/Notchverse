import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LRCLIBRecord: Codable, Hashable, Sendable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public var lyrics: Lyrics {
        if instrumental { return .instrumental }
        if let s = syncedLyrics, case let lines = LRCParser.parse(s).lines, !lines.isEmpty { return .synced(lines) }
        if let p = plainLyrics, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .plain(p) }
        return .notFound
    }
}

public enum LRCLIBError: Error, Equatable {
    case http(Int)
}

public struct LRCLIBClient: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var baseURL = URL(string: "https://lrclib.net/api/")!
    public var userAgent: String
    public var maxRetries = 2
    public var fetch: Fetch
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    /// `userAgent` per spec: "<App>/<version> (<repo url>)".
    public init(userAgent: String, fetch: Fetch? = nil, sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.userAgent = userAgent
        self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
        self.sleep = sleep ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    /// nil when not found. Skipped (nil) when duration is outside LRCLIB's 1–3600 s range.
    public func get(_ t: Track) async throws -> LRCLIBRecord? {
        let seconds = Int(t.duration.rounded())
        guard (1...3600).contains(seconds) else { return nil }
        var q = [URLQueryItem(name: "track_name", value: t.title), URLQueryItem(name: "artist_name", value: t.artist)]
        if let album = t.album { q.append(URLQueryItem(name: "album_name", value: album)) }
        q.append(URLQueryItem(name: "duration", value: String(seconds)))
        let (data, status) = try await request("get", q)
        if (400..<500).contains(status) { return nil }
        return try JSONDecoder().decode(LRCLIBRecord.self, from: data)
    }

    public func search(_ t: Track) async throws -> [LRCLIBRecord] {
        var q = [URLQueryItem(name: "track_name", value: t.title), URLQueryItem(name: "artist_name", value: t.artist)]
        if let album = t.album { q.append(URLQueryItem(name: "album_name", value: album)) }
        let (data, status) = try await request("search", q)
        guard (200..<300).contains(status) else { throw LRCLIBError.http(status) }
        return try JSONDecoder().decode([LRCLIBRecord].self, from: data)
    }

    /// Prefer synced lyrics, then smallest duration difference within `tolerance`. Duration <= 0 disables the filter.
    public static func bestMatch(_ records: [LRCLIBRecord], duration: TimeInterval, tolerance: TimeInterval = 2) -> LRCLIBRecord? {
        func diff(_ r: LRCLIBRecord) -> Double {
            guard duration > 0 else { return 0 }
            return r.duration.map { abs($0 - duration) } ?? .infinity
        }
        return records
            .filter { diff($0) <= tolerance }
            .min { ($0.syncedLyrics == nil ? 1 : 0, diff($0)) < ($1.syncedLyrics == nil ? 1 : 0, diff($1)) }
    }

    func request(_ path: String, _ query: [URLQueryItem]) async throws -> (Data, Int) {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var attempt = 0
        while true {
            let (data, resp) = try await fetch(req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 429, attempt < maxRetries {
                attempt += 1
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt * 2)
                try await sleep(wait + .random(in: 0...1))
                continue
            }
            if status == 429 || status >= 500 { throw LRCLIBError.http(status) }
            return (data, status)
        }
    }
}
