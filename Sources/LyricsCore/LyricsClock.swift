import Foundation

/// Playback position from the last Now Playing snapshot. The 30 Hz tick lives in the UI layer.
public struct LyricsClock: Hashable, Sendable {
    public var elapsedAtTimestamp: TimeInterval
    public var timestamp: Date
    public var rate: Double
    public var isPlaying: Bool
    /// Per-song manual offset (±0.5 s steps). LRC `[offset:]` is already applied by `LRCParser`.
    public var userOffset: TimeInterval

    public init(elapsedAtTimestamp: TimeInterval = 0, timestamp: Date = Date(), rate: Double = 1,
                isPlaying: Bool = false, userOffset: TimeInterval = 0) {
        self.elapsedAtTimestamp = elapsedAtTimestamp
        self.timestamp = timestamp
        self.rate = rate
        self.isPlaying = isPlaying
        self.userOffset = userOffset
    }

    public func position(at now: Date = Date()) -> TimeInterval {
        let live = isPlaying ? now.timeIntervalSince(timestamp) * rate : 0
        return elapsedAtTimestamp + live + userOffset
    }

    /// Index of the last line with `time <= position`, nil before the first line. Lines must be sorted.
    public static func activeIndex(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
