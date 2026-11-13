import AppKit
import LyricsCore
import Observation
import ServiceManagement

@MainActor @Observable final class AppModel {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var state: NowPlayingState?
    var lyrics: Lyrics? // nil = still searching
    var expanded = false
    var userVisible = true
    var adapterOK = true
    var candidates: [LRCLIBRecord]? // non-nil = manual picker open
    var userOffset: TimeInterval = 0
    var notchInset: CGFloat = 0
    var loginError: String?

    // Settings (UserDefaults-backed)
    @ObservationIgnored private let defaults = UserDefaults.standard
    var displayMode = UserDefaults.standard.string(forKey: "displayMode") ?? "auto" { didSet { defaults.set(displayMode, forKey: "displayMode") } }
    var screenChoice = UserDefaults.standard.string(forKey: "screenChoice") ?? "main" { didSet { defaults.set(screenChoice, forKey: "screenChoice") } }
    var hideInFullscreen = UserDefaults.standard.bool(forKey: "hideInFullscreen") { didSet { defaults.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    var blacklistText = UserDefaults.standard.string(forKey: "blacklist") ?? "" { didSet { defaults.set(blacklistText, forKey: "blacklist") } }
    var tolerance = UserDefaults.standard.object(forKey: "tolerance") as? Double ?? 2 { didSet { defaults.set(tolerance, forKey: "tolerance") } }
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    @ObservationIgnored private var fetcher: LyricsFetcher
    @ObservationIgnored private var source: NowPlayingSource?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchverse/cache")
        fetcher = LyricsFetcher(client: LRCLIBClient(userAgent: "Notchverse/\(Self.version) (https://github.com/Mqdd/Notchverse)"),
                                cache: LyricsCache(directory: dir))
    }

    func start() async {
        let source: NowPlayingSource
        if let paths = AdapterPaths.locate(), await Task.detached(operation: { paths.test() }).value {
            source = AdapterSource(paths: paths)
        } else {
            adapterOK = false
            source = AppleScriptSource()
        }
        source.onChange = { [weak self] in self?.update($0) }
        source.start()
        self.source = source
    }

    func stop() { source?.stop() }

    func send(_ c: PlayerCommand) { source?.send(c) }

    private var blacklist: Set<String> {
        Set(blacklistText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private func update(_ new: NowPlayingState?) {
        let s = new.flatMap { blacklist.contains($0.bundleID ?? "") ? nil : $0 }
        let changed = s?.track != state?.track
        state = s
        if changed { trackChanged() }
    }

    private func trackChanged() {
        fetchTask?.cancel()
        lyrics = nil
        candidates = nil
        guard let t = state?.track else { return }
        userOffset = defaults.double(forKey: offsetKey(t))
        var f = fetcher
        f.tolerance = tolerance
        fetchTask = Task {
            let l = await f.lyrics(for: t)
            if !Task.isCancelled, state?.track == t { lyrics = l }
        }
    }

    var clock: LyricsClock? {
        state.map { LyricsClock(elapsedAtTimestamp: $0.elapsedAtTimestamp, timestamp: $0.timestamp, rate: $0.rate,
                                isPlaying: $0.isPlaying, userOffset: userOffset) }
    }

    private func offsetKey(_ t: Track) -> String { "offset." + LyricsCache.key(for: t) }

    func nudgeOffset(_ delta: TimeInterval) {
        guard let t = state?.track else { return }
        userOffset += delta
        defaults.set(userOffset, forKey: offsetKey(t))
    }

    func loadCandidates() {
        guard let t = state?.track else { return }
        candidates = []
        let client = fetcher.client
        Task {
            var seen = Set<Int>(), all: [LRCLIBRecord] = []
            for v in TitleNormalizer.variants(of: t) {
                for r in (try? await client.search(v)) ?? [] where seen.insert(r.id).inserted { all.append(r) }
            }
            if state?.track == t, candidates != nil { candidates = all }
        }
    }

    func choose(_ r: LRCLIBRecord) {
        guard let t = state?.track else { return }
        fetcher.cache.store(r.lyrics, for: t)
        lyrics = r.lyrics
        candidates = nil
    }

    func clearCache() {
        fetcher.cache.clear()
        trackChanged()
    }
}
