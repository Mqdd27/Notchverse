import Foundation

public struct Track: Hashable, Sendable, Codable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public struct LyricLine: Hashable, Sendable, Codable {
    public var time: TimeInterval
    /// Empty text = instrumental gap (UI shows "♪").
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// `.notFound` instead of the spec's `.none`, so `Lyrics?` never confuses it with `Optional.none`.
public enum Lyrics: Hashable, Sendable, Codable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}
