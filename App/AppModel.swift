import AppKit
import LyricsCore
import Observation
import ServiceManagement

enum Page: String, CaseIterable {
    case music, agents, weather, prayer, timer, containers

    var icon: String {
        switch self {
        case .music: "music.note"
        case .agents: "terminal"
        case .weather: "cloud.sun"
        case .prayer: "sun.horizon"
        case .timer: "timer"
        case .containers: "shippingbox"
        }
    }

    var label: String { rawValue.capitalized }
}

/// What the closed pill shows, highest priority first.
enum CompactKind: Equatable {
    case timer, agentNeedsYou, music, idle
}

/// One slot of the closed pill when nothing is playing (Settings › left / right).
enum IdleItem: String, CaseIterable {
    case none, prayer, clock, weather, agents, containers

    var label: String {
        switch self {
        case .none: "Nothing"
        case .prayer: "Next prayer"
        case .clock: "Clock"
        case .weather: "Weather"
        case .agents: "Coding agents"
        case .containers: "Docker containers"
        }
    }
}

@MainActor @Observable final class AppModel {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var state: NowPlayingState?
    var lyrics: Lyrics? // nil = still searching
    var expanded = false {
        didSet {
            guard expanded, !oldValue else { return }
            prayerInstalled = Self.isPrayerAppInstalled()
            Task { await refreshVisiblePage() }
        }
    }
    var showLyrics = UserDefaults.standard.object(forKey: "showLyrics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLyrics, forKey: "showLyrics") }
    }
    var adapterOK = true
    var candidates: [LRCLIBRecord]? // non-nil = manual picker open
    var userOffset: TimeInterval = 0
    var notchInset: CGFloat = 0
    var loginError: String?
    var page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .music {
        didSet {
            UserDefaults.standard.set(page.rawValue, forKey: "page")
            Task { await refreshVisiblePage() }
        }
    }

    let agents = AgentsService()
    let location = LocationStore()
    let weather = WeatherService()
    let timer = TimerModel()
    let containers = ContainersService()

    /// The prayer page only appears when github.com/Mqdd27/prayer-times is installed.
    var prayerInstalled = AppModel.isPrayerAppInstalled()
    static func isPrayerAppInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "id.mqdd.prayertimes") != nil
    }

    var idleLeft = IdleItem(rawValue: UserDefaults.standard.string(forKey: "idleLeft") ?? "")
        ?? (AppModel.isPrayerAppInstalled() ? .prayer : .clock) {
        didSet { defaults.set(idleLeft.rawValue, forKey: "idleLeft") }
    }
    var idleRight = IdleItem(rawValue: UserDefaults.standard.string(forKey: "idleRight") ?? "") ?? .weather {
        didSet { defaults.set(idleRight.rawValue, forKey: "idleRight") }
    }

    /// Items that make sense on this Mac.
    var idleOptions: [IdleItem] {
        IdleItem.allCases.filter { ($0 != .prayer || prayerInstalled) && ($0 != .containers || containers.binary != nil) }
    }

    /// The two slots, unavailable choices shown as nothing.
    var idleSlots: [IdleItem] { [idleLeft, idleRight].map { idleOptions.contains($0) ? $0 : .none } }

    var pages: [Page] {
        Page.allCases.filter { ($0 != .prayer || prayerInstalled) && ($0 != .containers || containers.binary != nil) }
    }
    var visiblePage: Page { pages.contains(page) ? page : .music }

    var compactKind: CompactKind {
        if timer.end != nil { return .timer }
        if agents.needsYou != nil { return .agentNeedsYou }
        if state?.isPlaying == true { return .music }
        return .idle
    }

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
        fetcher = LyricsFetcher(client: LRCLIBClient(userAgent: "Notchverse/\(Self.version) (https://github.com/Mqdd27/Notchverse)"),
                                cache: LyricsCache(directory: dir))
    }

    func start() async {
        let source: NowPlayingSource
        let paths = AdapterPaths.locate()
        if let paths { _ = await runCommand("/usr/bin/pkill", ["-f", paths.script]) } // adapters orphaned by a crash or kill
        if let paths, await Task.detached(operation: { paths.test() }).value {
            source = AdapterSource(paths: paths)
        } else {
            adapterOK = false
            source = AppleScriptSource()
        }
        source.onChange = { [weak self] in self?.update($0) }
        source.start()
        self.source = source

        location.onChange = { [weak self] in
            guard let self else { return }
            Task { await self.weather.refresh(self.location.place) }
        }
        await weather.refresh(location.place)
        startTicking()
    }

    /// One 1 Hz loop drives timer, agents and the polled pages (only while visible).
    private func startTicking() {
        Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                timer.tick(Date())
                if tick % 3 == 0 { await agents.refresh() }
                if tick % 900 == 0 { await weather.refresh(location.place) }
                if !expanded, idleSlots.contains(.containers), tick % 10 == 0 { await containers.refresh() }
                if expanded, page == .containers, tick % 3 == 0 {
                    await refreshVisiblePage()
                }
            }
        }
    }

    func refreshVisiblePage() async {
        switch page {
        case .containers: await containers.refresh()
        case .agents: await agents.refresh()
        case .weather where weather.now == nil: await weather.refresh(location.place)
        default: break
        }
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
