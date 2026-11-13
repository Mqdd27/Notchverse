import AppKit
import CoreLocation
import LyricsCore
import Observation

/// Runs a CLI off the main thread. nil when missing or non-zero exit.
func runCommand(_ path: String, _ args: [String]) async -> Data? {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }.value
}

/// Finder-launched apps get a minimal PATH, so look in the usual install dirs.
func findBinary(_ name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/go/bin", "/usr/bin"]
        .map { "\($0)/\(name)" }
        .first(where: FileManager.default.isExecutableFile)
}

// MARK: tuios agents

@MainActor @Observable final class AgentsService {
    struct Agent: Decodable, Identifiable, Equatable {
        let window_id: String
        let name: String
        let state: String
        let needs_you: Bool
        let session: String
        let harness_id: String?
        let cwd: String?
        var id: String { window_id }
        var folder: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
    }

    var agents: [Agent] = []
    @ObservationIgnored let binary = findBinary("tuios")

    var needsYou: Agent? { agents.first(where: \.needs_you) }
    var working: Int { agents.filter { $0.state == "working" }.count }

    func refresh() async {
        guard let binary, let data = await runCommand(binary, ["list-agents", "--json"]) else { return }
        struct List: Decodable { let agents: [Agent]? }
        let new = (try? JSONDecoder().decode(List.self, from: data))?.agents ?? []
        if new != agents { agents = new }
    }

    func focus(_ a: Agent) {
        guard let binary else { return }
        Task { _ = await runCommand(binary, ["focus-window", "-s", a.session, a.window_id]) }
    }
}

// MARK: Location (shared by weather and prayer times)

@MainActor @Observable final class LocationStore: NSObject, CLLocationManagerDelegate {
    struct Place: Codable, Equatable {
        var name: String, lat: Double, lng: Double, tz: String
        var timeZone: TimeZone { TimeZone(identifier: tz) ?? .current }
    }

    var place: Place
    var automatic: Bool
    var results: [Place] = []
    var denied = false
    var query = "" { didSet { search(query) } }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    override init() {
        let saved = UserDefaults.standard.data(forKey: "place").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        place = saved ?? Place(name: "Jakarta", lat: -6.21, lng: 106.85, tz: "Asia/Jakarta")
        automatic = UserDefaults.standard.object(forKey: "autoLocation") as? Bool ?? true
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if automatic { manager.requestWhenInUseAuthorization(); manager.requestLocation() }
    }

    private func set(_ p: Place) {
        place = p
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "place")
        onChange?()
    }

    func setAutomatic(_ on: Bool) {
        automatic = on
        UserDefaults.standard.set(on, forKey: "autoLocation")
        guard on else { return }
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func choose(_ p: Place) {
        automatic = false
        UserDefaults.standard.set(false, forKey: "autoLocation")
        query = ""
        set(p)
    }

    /// Open-Meteo geocoding, debounced. Only the typed text is sent.
    func search(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            url.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "8"), .init(name: "language", value: "en")]
            struct Geo: Decodable {
                struct R: Decodable { let name: String; let latitude, longitude: Double; let country, timezone: String? }
                let results: [R]?
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
                  let geo = try? JSONDecoder().decode(Geo.self, from: data), !Task.isCancelled else { return }
            results = (geo.results ?? []).map {
                Place(name: [$0.name, $0.country].compactMap { $0 }.joined(separator: ", "),
                      lat: $0.latitude, lng: $0.longitude, tz: $0.timezone ?? TimeZone.current.identifier)
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in
            guard self.automatic else { return }
            self.denied = false
            self.set(Place(name: "Current location", lat: c.latitude, lng: c.longitude, tz: TimeZone.current.identifier))
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.denied = m.authorizationStatus == .denied }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            self.denied = m.authorizationStatus == .denied
            if self.automatic, ![.denied, .restricted, .notDetermined].contains(m.authorizationStatus) { m.requestLocation() }
        }
    }
}

// MARK: Weather (Open-Meteo, no key)

@MainActor @Observable final class WeatherService {
    struct Now: Equatable {
        var temp: Double, feels: Double, high: Double, low: Double, wind: Double, code: Int, isDay: Bool
        var symbol: String { WeatherService.describe(code, isDay).symbol }
        var label: String { WeatherService.describe(code, isDay).label }
    }

    var now: Now?
    var failed = false

    func refresh(_ p: LocationStore.Place) async {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", p.lat)),
            .init(name: "longitude", value: String(format: "%.2f", p.lng)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        struct F: Decodable {
            struct C: Decodable { let temperature_2m, apparent_temperature, wind_speed_10m: Double; let weather_code, is_day: Int }
            struct D: Decodable { let temperature_2m_max, temperature_2m_min: [Double] }
            let current: C
            let daily: D
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let f = try? JSONDecoder().decode(F.self, from: data) else { failed = true; return }
        failed = false
        now = Now(temp: f.current.temperature_2m, feels: f.current.apparent_temperature,
                  high: f.daily.temperature_2m_max.first ?? f.current.temperature_2m,
                  low: f.daily.temperature_2m_min.first ?? f.current.temperature_2m,
                  wind: f.current.wind_speed_10m, code: f.current.weather_code, isDay: f.current.is_day == 1)
    }

    /// WMO weather codes.
    nonisolated static func describe(_ code: Int, _ day: Bool) -> (symbol: String, label: String) {
        switch code {
        case 0: (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Overcast")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...57: ("cloud.drizzle.fill", "Drizzle")
        case 61...67: ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 80...82: ("cloud.heavyrain.fill", "Showers")
        case 95...99: ("cloud.bolt.rain.fill", "Thunderstorm")
        default: ("cloud.fill", "—")
        }
    }
}

// MARK: Timer

@MainActor @Observable final class TimerModel {
    var end: Date?
    var total: TimeInterval = 0
    static let presets = [1, 5, 10, 15, 25, 45]

    func start(minutes: Int) {
        total = TimeInterval(minutes * 60)
        end = Date().addingTimeInterval(total)
    }

    func cancel() { end = nil }

    func remaining(at now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(now)) }

    /// Called every second by the app tick.
    func tick(_ now: Date) {
        guard let end, now >= end else { return }
        self.end = nil
        NSSound(named: "Glass")?.play()
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: Apple `container` runtime

@MainActor @Observable final class ContainersService {
    struct Container: Identifiable, Equatable {
        let id: String, image: String, status: String
        var running: Bool { status == "running" }
    }

    var containers: [Container] = []
    @ObservationIgnored let binary = findBinary("container")

    func refresh() async {
        guard let binary, let data = await runCommand(binary, ["list", "--all", "--format", "json"]),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        containers = arr.compactMap { o in
            let cfg = o["configuration"] as? [String: Any]
            guard let id = cfg?["id"] as? String else { return nil }
            return Container(id: id, image: (cfg?["image"] as? [String: Any])?["reference"] as? String ?? "",
                             status: o["status"] as? String ?? "unknown")
        }
    }

    func toggle(_ c: Container) {
        guard let binary else { return }
        Task {
            _ = await runCommand(binary, [c.running ? "stop" : "start", c.id])
            await refresh()
        }
    }
}
