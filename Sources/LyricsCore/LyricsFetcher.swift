import Foundation

public struct LyricsCache: Sendable {
    public var directory: URL
    public var negativeTTL: TimeInterval = 7 * 86_400

    struct Entry: Codable {
        var lyrics: Lyrics
        var storedAt: Date
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// FNV-1a over (artist, title, album, rounded duration): stable across runs and platforms, no CryptoKit.
    public static func key(for t: Track) -> String {
        let s = [t.artist, t.title, t.album ?? "", String(Int(t.duration.rounded()))]
            .joined(separator: "\u{1F}").lowercased()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    func url(_ t: Track) -> URL { directory.appendingPathComponent(Self.key(for: t) + ".json") }

    public func load(_ t: Track, now: Date = Date()) -> Lyrics? {
        guard let data = try? Data(contentsOf: url(t)),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if e.lyrics == .notFound, now.timeIntervalSince(e.storedAt) > negativeTTL { return nil }
        return e.lyrics
    }

    public func store(_ lyrics: Lyrics, for t: Track, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Entry(lyrics: lyrics, storedAt: now)).write(to: url(t), options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Cache → LRCLIB get → LRCLIB search, per normalizer variant. Cancel the calling Task when the song changes.
public struct LyricsFetcher: Sendable {
    public var client: LRCLIBClient
    public var cache: LyricsCache
    public var tolerance: TimeInterval = 2

    public init(client: LRCLIBClient, cache: LyricsCache) {
        self.client = client
        self.cache = cache
    }

    public func lyrics(for track: Track) async -> Lyrics {
        if let hit = cache.load(track) { return hit }
        do {
            for v in TitleNormalizer.variants(of: track) {
                try Task.checkCancellation()
                if let r = try await client.get(v) { return save(r.lyrics, track) }
                let results = try await client.search(v)
                if let r = LRCLIBClient.bestMatch(results, duration: track.duration, tolerance: tolerance) {
                    return save(r.lyrics, track)
                }
            }
            return save(.notFound, track)
        } catch {
            return .notFound // offline / cancelled / 5xx: not cached, retried next time
        }
    }

    private func save(_ l: Lyrics, _ t: Track) -> Lyrics {
        cache.store(l, for: t)
        return l
    }
}
