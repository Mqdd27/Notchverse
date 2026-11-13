import Foundation

public struct LRC: Sendable {
    /// Sorted by time, with `[offset:]` already applied (spec's `lrcOffset` is baked in here).
    public var lines: [LyricLine]
    public var meta: [String: String]
}

public enum LRCParser {
    public static func parse(_ text: String) -> LRC {
        var stamped: [(line: LyricLine, order: Int)] = []
        var meta: [String: String] = [:]

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = raw.drop(while: \.isWhitespace)
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = parseTime(tag) {
                    times.append(t)
                } else if let colon = tag.firstIndex(of: ":") {
                    let key = tag[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    meta[key] = tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            guard !times.isEmpty else { continue } // meta-only or malformed line
            // Enhanced LRC word tags are out of scope for v0.1: drop them.
            let body = String(rest)
                .replacing(/<\d+:\d{1,2}(?:[.:]\d{1,3})?>/, with: "")
                .trimmingCharacters(in: .whitespaces)
            for t in times { stamped.append((LyricLine(time: t, text: body), stamped.count)) }
        }

        // LRC convention: positive offset (ms) shows lyrics earlier.
        let offset = (meta["offset"].flatMap(Double.init) ?? 0) / 1000
        let lines = stamped
            .sorted { ($0.line.time, $0.order) < ($1.line.time, $1.order) }
            .map { LyricLine(time: $0.line.time - offset, text: $0.line.text) }
        return LRC(lines: lines, meta: meta)
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx` (also `mm:ss:xx`).
    static func parseTime(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var sec = parts[1]
        var frac: Substring = ""
        if parts.count == 3 {
            frac = parts[2]
        } else if let dot = sec.firstIndex(of: ".") {
            frac = sec[sec.index(after: dot)...]
            sec = sec[..<dot]
        }
        let digits = { (s: Substring) in !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
        guard digits(parts[0]), digits(sec), frac.isEmpty || (digits(frac) && frac.count <= 3),
              let m = Int(parts[0]), let s = Int(sec), s < 60 else { return nil }
        return Double(m * 60 + s) + (frac.isEmpty ? 0 : Double("0." + frac)!)
    }
}
