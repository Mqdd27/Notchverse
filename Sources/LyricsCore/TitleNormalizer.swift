import Foundation

public enum TitleNormalizer {
    /// Strips feat./remaster/single/live/deluxe noise from a title or album name.
    public static func clean(_ s: String) -> String {
        var r = s
        r = r.replacing(/\s*[\(\[](?:feat\.?|ft\.?|featuring)\s[^\)\]]*[\)\]]/.ignoresCase(), with: "")
        r = r.replacing(/\s*[\(\[][^\)\]]*(?:deluxe|remaster)[^\)\]]*[\)\]]/.ignoresCase(), with: "")
        r = r.replacing(/\s+-\s+(?:\d{4}\s+)?remaster(?:ed)?\b.*$/.ignoresCase(), with: "")
        r = r.replacing(/\s+-\s+(?:single|live)\b.*$/.ignoresCase(), with: "")
        return r.trimmingCharacters(in: .whitespaces)
    }

    public static func firstArtist(_ s: String) -> String {
        let first = s.split(separator: /\s*(?:,|&|;|\s(?:feat|ft)\.?\s)\s*/.ignoresCase()).first ?? Substring(s)
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// Query order: original first, then cleaned, then cleaned + first artist. Deduplicated.
    public static func variants(of t: Track) -> [Track] {
        var cleaned = t
        cleaned.title = clean(t.title)
        cleaned.album = t.album.map(clean)
        var firstOnly = cleaned
        firstOnly.artist = firstArtist(t.artist)
        var seen = Set<Track>()
        return [t, cleaned, firstOnly].filter { seen.insert($0).inserted }
    }
}
