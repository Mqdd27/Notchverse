import Foundation
import Testing
@testable import LyricsCore

// MARK: LRC parser

@Test func parsesTimestampFormatsAndMeta() {
    let lrc = LRCParser.parse("[ti:Song]\r\n[ar: Artist ]\n[00:01.5]a\n[00:02.25]b\n[00:03.125]c\n[01:04]d")
    #expect(lrc.lines.map(\.time) == [1.5, 2.25, 3.125, 64])
    #expect(lrc.lines.map(\.text) == ["a", "b", "c", "d"])
    #expect(lrc.meta["ti"] == "Song")
    #expect(lrc.meta["ar"] == "Artist")
}

@Test func multipleTimestampsAreSorted() {
    let lrc = LRCParser.parse("[00:50.00][00:10.00]x\n[00:20.00]y")
    #expect(lrc.lines == [.init(time: 10, text: "x"), .init(time: 20, text: "y"), .init(time: 50, text: "x")])
}

@Test func offsetShiftsLines() {
    #expect(LRCParser.parse("[offset:+500]\n[00:10.00]x").lines.first?.time == 9.5)
    #expect(LRCParser.parse("[offset:-500]\n[00:10.00]x").lines.first?.time == 10.5)
}

@Test func toleratesGarbageGapsAndEnhancedTags() {
    let lrc = LRCParser.parse("""
    [00:05.00]
    garbage
    [xx:yy]bad
    [00:99.00]bad seconds
    [00:06.00]<00:06.00>Hel <00:06.50>lo
    [00:07
    """)
    #expect(lrc.lines == [.init(time: 5, text: ""), .init(time: 6, text: "Hel lo")])
}

// MARK: Clock

@Test func clockAdvancesFreezesAndOffsets() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var c = LyricsClock(elapsedAtTimestamp: 10, timestamp: t0, rate: 1, isPlaying: true)
    #expect(c.position(at: t0 + 5) == 15)
    c.rate = 2
    #expect(c.position(at: t0 + 5) == 20)
    c.isPlaying = false
    #expect(c.position(at: t0 + 100) == 10)
    c.userOffset = 0.5
    #expect(c.position(at: t0 + 100) == 10.5)
}

@Test func activeIndexBinarySearch() {
    let lines = [5.0, 10, 15].map { LyricLine(time: $0, text: "") }
    #expect(LyricsClock.activeIndex(in: lines, at: 4) == nil)
    #expect(LyricsClock.activeIndex(in: lines, at: 5) == 0)
    #expect(LyricsClock.activeIndex(in: lines, at: 12) == 1)
    #expect(LyricsClock.activeIndex(in: lines, at: 99) == 2)
    #expect(LyricsClock.activeIndex(in: [], at: 1) == nil)
}

// MARK: Normalizer

@Test func normalizerStripsNoise() {
    #expect(TitleNormalizer.clean("Song (feat. X)") == "Song")
    #expect(TitleNormalizer.clean("Song [ft. X & Y]") == "Song")
    #expect(TitleNormalizer.clean("Song - Remastered 2011") == "Song")
    #expect(TitleNormalizer.clean("Song - 2011 Remaster") == "Song")
    #expect(TitleNormalizer.clean("Album (Deluxe Edition)") == "Album")
    #expect(TitleNormalizer.clean("Album - Single") == "Album")
    #expect(TitleNormalizer.clean("Song - Live at Wembley") == "Song")
    #expect(TitleNormalizer.clean("Love + Hate") == "Love + Hate")
    #expect(TitleNormalizer.firstArtist("A, B & C") == "A")
    #expect(TitleNormalizer.firstArtist("A feat. B") == "A")
    #expect(TitleNormalizer.firstArtist("Simon & Garfunkel") == "Simon") // known: fallback only, original tried first
}

@Test func variantsOriginalFirstAndDeduped() {
    let t = Track(title: "Song (feat. B)", artist: "A & B", album: "Al - Single", duration: 200)
    let v = TitleNormalizer.variants(of: t)
    #expect(v.count == 3)
    #expect(v[0] == t)
    #expect(v[2] == Track(title: "Song", artist: "A", album: "Al", duration: 200))
    #expect(TitleNormalizer.variants(of: Track(title: "S", artist: "A", duration: 1)).count == 1)
}

// MARK: Search selection

func record(_ id: Int, _ duration: Double?, synced: Bool) -> LRCLIBRecord {
    LRCLIBRecord(id: id, trackName: "S", artistName: "A", albumName: nil, duration: duration,
                 instrumental: false, plainLyrics: "x", syncedLyrics: synced ? "[00:01.00]x" : nil)
}

@Test func bestMatchPrefersSyncedWithinTolerance() {
    let rs = [record(1, 200, synced: false), record(2, 201.5, synced: true), record(3, 210, synced: true), record(4, 200.5, synced: true)]
    #expect(LRCLIBClient.bestMatch(rs, duration: 200)?.id == 4)
    #expect(LRCLIBClient.bestMatch([record(1, 200, synced: false), record(3, 210, synced: true)], duration: 200)?.id == 1)
    #expect(LRCLIBClient.bestMatch([record(3, 210, synced: true)], duration: 200) == nil)
    #expect(LRCLIBClient.bestMatch([record(1, nil, synced: false), record(3, 210, synced: true)], duration: 0)?.id == 3)
}

// MARK: Client + fetcher + cache (stubbed HTTP)

actor RequestLog {
    var paths: [String] = []
    func add(_ p: String) -> Int { paths.append(p); return paths.count }
}

@Test func fetcherRetries429FallsBackToSearchAndCaches() async throws {
    let log = RequestLog()
    let json = #"[{"id":1,"trackName":"Song","artistName":"A","albumName":"Al","duration":200.5,"instrumental":false,"plainLyrics":"hi","syncedLyrics":"[00:01.00]hi"}]"#
    let client = LRCLIBClient(userAgent: "Notchverse/test", fetch: { req in
        let path = req.url!.lastPathComponent
        let n = await log.add(path)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Notchverse/test")
        let status = path == "get" ? (n == 1 ? 429 : 404) : 200
        let body = path == "search" ? Data(json.utf8) : Data()
        return (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "0"])!)
    }, sleep: { _ in })

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fetcher = LyricsFetcher(client: client, cache: LyricsCache(directory: dir))
    let track = Track(title: "Song", artist: "A", album: "Al", duration: 200)

    #expect(await fetcher.lyrics(for: track) == .synced([LyricLine(time: 1, text: "hi")]))
    #expect(await log.paths == ["get", "get", "search"])
    #expect(await fetcher.lyrics(for: track) == .synced([LyricLine(time: 1, text: "hi")]))
    #expect(await log.paths.count == 3) // served from cache
}

@Test func offlineIsNotCached() async {
    let client = LRCLIBClient(userAgent: "t", fetch: { _ in throw URLError(.notConnectedToInternet) })
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fetcher = LyricsFetcher(client: client, cache: LyricsCache(directory: dir))
    let track = Track(title: "S", artist: "A", duration: 100)
    #expect(await fetcher.lyrics(for: track) == .notFound)
    #expect(fetcher.cache.load(track) == nil)
}

@Test func negativeCacheExpiresAfterTTL() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = LyricsCache(directory: dir)
    let miss = Track(title: "M", artist: "A", duration: 100)
    let hit = Track(title: "H", artist: "A", duration: 100)
    let old = Date().addingTimeInterval(-8 * 86_400)
    cache.store(.notFound, for: miss, now: old)
    cache.store(.plain("x"), for: hit, now: old)
    #expect(cache.load(miss) == nil)
    #expect(cache.load(hit) == .plain("x"))
    #expect(cache.load(miss, now: old) == .notFound)
}

// MARK: Live (opt-in): LRCLIB_LIVE=1 swift test --filter live

@Test(.enabled(if: ProcessInfo.processInfo.environment["LRCLIB_LIVE"] != nil))
func liveFetchFromLRCLIB() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fetcher = LyricsFetcher(client: LRCLIBClient(userAgent: "Notchverse/0.1 (test)"), cache: LyricsCache(directory: dir))
    let lyrics = await fetcher.lyrics(for: Track(title: "Bohemian Rhapsody - Remastered 2011", artist: "Queen",
                                                 album: "A Night At The Opera (2011 Remaster)", duration: 355))
    guard case .synced(let lines) = lyrics else { Issue.record("got \(lyrics)"); return }
    #expect(lines.count > 20)
}

// MARK: Sky

@Test func jakartaPrayerTimesAreOrderedAndPlausible() {
    let tz = TimeZone(identifier: "Asia/Jakarta")!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    let times = prayerTimes(lat: -6.21, lng: 106.85, tz: tz, day: day)
    #expect(times.map(\.0) == Prayer.allCases)
    #expect(zip(times, times.dropFirst()).allSatisfy { $0.1 < $1.1 })
    let dhuhr = cal.dateComponents([.hour, .minute], from: times[1].1)
    #expect(dhuhr.hour == 11 && (30...50).contains(dhuhr.minute!))
    let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 23))!
    #expect(nextPrayer(lat: -6.21, lng: 106.85, tz: tz, now: late).0 == .fajr)
}

@Test func moonPhaseFromReferenceNewMoon() {
    let newMoon = Date(timeIntervalSince1970: 947_182_440) // 2000-01-06 18:14 UTC
    #expect(MoonPhase(date: newMoon).name == "New Moon")
    let full = MoonPhase(date: newMoon.addingTimeInterval(14.77 * 86400))
    #expect(full.name == "Full Moon")
    #expect(full.illumination > 0.99)
    #expect(MoonPhase(date: newMoon.addingTimeInterval(7.4 * 86400)).name == "First Quarter")
}
