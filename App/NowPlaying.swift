import AppKit
import LyricsCore

struct NowPlayingState: Equatable {
    var track: Track
    var bundleID: String?
    var isPlaying: Bool
    var elapsedAtTimestamp: TimeInterval
    var timestamp: Date
    var rate: Double
    var artwork: NSImage?
}

enum PlayerCommand: Int {
    case togglePlayPause = 2, next = 4, previous = 5 // mediaremote-adapter `send` IDs
}

@MainActor protocol NowPlayingSource: AnyObject {
    var onChange: ((NowPlayingState?) -> Void)? { get set }
    func start()
    func stop()
    func send(_ command: PlayerCommand)
}

// MARK: mediaremote-adapter (primary)

struct AdapterPaths: Sendable {
    let script: String, framework: String, testClient: String

    /// Inside the .app bundle, or `NOTCHVERSE_ADAPTER=<dir>` for `swift run`.
    static func locate() -> AdapterPaths? {
        let p: AdapterPaths
        if let dir = ProcessInfo.processInfo.environment["NOTCHVERSE_ADAPTER"] {
            p = AdapterPaths(script: dir + "/mediaremote-adapter.pl", framework: dir + "/MediaRemoteAdapter.framework",
                             testClient: dir + "/MediaRemoteAdapterTestClient")
        } else {
            let c = Bundle.main.bundlePath + "/Contents"
            p = AdapterPaths(script: c + "/Resources/mediaremote-adapter.pl", framework: c + "/Frameworks/MediaRemoteAdapter.framework",
                             testClient: c + "/MacOS/MediaRemoteAdapterTestClient")
        }
        return [p.script, p.framework, p.testClient].allSatisfy(FileManager.default.fileExists) ? p : nil
    }

    func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework] + args
        p.standardError = FileHandle.nullDevice
        return p
    }

    /// Blocking; call off the main thread.
    func test() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, testClient, "test"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

@MainActor final class AdapterSource: NowPlayingSource {
    var onChange: ((NowPlayingState?) -> Void)?
    private let paths: AdapterPaths
    private var process: Process?
    private var payload: [String: Any] = [:]
    private var artwork: NSImage?
    private var buffer = Data()
    private var backoff: TimeInterval = 1
    private var stopped = false

    init(paths: AdapterPaths) { self.paths = paths }

    func start() {
        stopped = false
        buffer = Data()
        let p = paths.process(["stream", "--micros", "--debounce=50"])
        let out = Pipe()
        p.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(d) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didTerminate() } }
        }
        do { try p.run(); process = p } catch { didTerminate() }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }

    func send(_ command: PlayerCommand) {
        try? paths.process(["send", String(command.rawValue)]).run()
    }

    private func didTerminate() {
        process = nil
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            MainActor.assumeIsolated { if self?.stopped == false { self?.start() } }
        }
        backoff = min(backoff * 2, 30)
    }

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let new = obj["payload"] as? [String: Any] else { continue }
            backoff = 1
            let isDiff = obj["diff"] as? Bool ?? false
            if isDiff {
                for (k, v) in new { payload[k] = v is NSNull ? nil : v }
            } else {
                payload = new
            }
            // Decode artwork only when it changes, not on every diff.
            if !isDiff || new.keys.contains("artworkData") {
                artwork = (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            }
            onChange?(Self.state(from: payload, artwork: artwork))
        }
    }

    private static func state(from p: [String: Any], artwork: NSImage?) -> NowPlayingState? {
        guard let title = p["title"] as? String, !title.isEmpty else { return nil }
        let num = { (k: String) in (p[k] as? NSNumber)?.doubleValue ?? 0 }
        let album = (p["album"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rate = num("playbackRate")
        return NowPlayingState(
            track: Track(title: title, artist: p["artist"] as? String ?? "", album: album, duration: num("durationMicros") / 1e6),
            bundleID: p["bundleIdentifier"] as? String,
            isPlaying: p["playing"] as? Bool ?? false,
            elapsedAtTimestamp: num("elapsedTimeMicros") / 1e6,
            timestamp: p["timestampEpochMicros"] == nil ? Date() : Date(timeIntervalSince1970: num("timestampEpochMicros") / 1e6),
            rate: rate > 0 ? rate : 1,
            artwork: artwork)
    }
}

// MARK: AppleScript fallback (Music, Spotify)

@MainActor final class AppleScriptSource: NowPlayingSource {
    var onChange: ((NowPlayingState?) -> Void)?
    private var timer: Timer?
    private var activeApp: String?
    // (app name, bundle ID, duration unit in seconds)
    private let players = [("Music", "com.apple.Music", 1.0), ("Spotify", "com.spotify.client", 0.001)]

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() { timer?.invalidate() }

    func send(_ command: PlayerCommand) {
        guard let app = activeApp else { return }
        let verb = [.togglePlayPause: "playpause", .next: "next track", .previous: "previous track"][command]!
        NSAppleScript(source: "tell application \"\(app)\" to \(verb)")?.executeAndReturnError(nil)
    }

    private func poll() {
        for (app, bundle, unit) in players where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            let src = """
            tell application "\(app)"
              if player state is stopped then return {}
              return {name of current track, artist of current track, album of current track, duration of current track, player position, player state is playing}
            end tell
            """
            guard let d = NSAppleScript(source: src)?.executeAndReturnError(nil), d.numberOfItems == 6,
                  let title = d.atIndex(1)?.stringValue else { continue }
            activeApp = app
            onChange?(NowPlayingState(
                track: Track(title: title, artist: d.atIndex(2)?.stringValue ?? "", album: d.atIndex(3)?.stringValue,
                             duration: (d.atIndex(4)?.doubleValue ?? 0) * unit),
                bundleID: bundle, isPlaying: d.atIndex(6)?.booleanValue ?? false,
                elapsedAtTimestamp: d.atIndex(5)?.doubleValue ?? 0, timestamp: Date(), rate: 1, artwork: nil))
            return
        }
        activeApp = nil
        onChange?(nil)
    }
}
