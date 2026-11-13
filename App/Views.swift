import AppKit
import LyricsCore
import SwiftUI

struct PillView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Redraw once a second plus exactly when a lyric line starts, instead of 30 Hz.
        TimelineView(LineSchedule(lineDates: lineDates)) { ctx in
            let pos = model.clock?.position(at: ctx.date) ?? 0
            Group {
                if model.expanded { expanded(pos, now: ctx.date) } else { compact(pos, now: ctx.date) }
            }
            .padding(.horizontal, model.attached ? 22 : 14)
            .padding(.top, model.notchInset + (model.expanded ? 12 : 0))
            .padding(.bottom, model.expanded ? 12 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(shape.fill(.black))
            .clipShape(shape)
            .foregroundStyle(.white)
        }
        .contentShape(shape)
        .onHover { model.expanded = $0 }
        .onTapGesture { model.expanded.toggle() }
    }

    private var shape: NotchShape {
        if model.attached { return NotchShape(flare: 6, topRadius: 0, bottomRadius: model.expanded ? 24 : 12) }
        let r: CGFloat = model.expanded ? 22 : 19
        return NotchShape(flare: 0, topRadius: r, bottomRadius: r)
    }

    /// Wall-clock dates at which each lyric line starts, while playing.
    private var lineDates: [Date] {
        guard model.showLyrics, let s = model.state, s.isPlaying, let lines = syncedLines else { return [] }
        return lines.map { s.timestamp.addingTimeInterval(($0.time - s.elapsedAtTimestamp - model.userOffset) / s.rate) }
    }

    private var syncedLines: [LyricLine]? {
        if case .synced(let l) = model.lyrics { return l }
        return nil
    }

    private var titleLine: String {
        guard let t = model.state?.track else { return "" }
        return t.artist.isEmpty ? t.title : "\(t.title) — \(t.artist)"
    }

    private func animation<V: Equatable>(_ v: V) -> Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }

    // MARK: Compact

    @ViewBuilder private func compact(_ pos: TimeInterval, now: Date) -> some View {
        switch model.compactKind {
        case .music:
            musicCompact(pos)
        case .timer:
            compactRow("timer", TimerModel.format(model.timer.remaining(at: now)), tint: .orange)
        case .agentNeedsYou:
            compactRow("exclamationmark.bubble.fill", "\(model.agents.needsYou?.name ?? "Agent") needs you", tint: .orange)
        case .idle:
            idle(now)
        }
    }

    private func idle(_ now: Date) -> some View {
        let slots = model.idleSlots
        let shown = slots.filter { $0 != .none }
        return HStack(spacing: 8) {
            if shown.count == 1 {
                idleItem(shown[0], now) // one item: centered
            } else {
                idleItem(slots[0], now)
                Spacer(minLength: 8)
                idleItem(slots[1], now)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func idleItem(_ item: IdleItem, _ now: Date) -> some View {
        let p = model.location.place
        switch item {
        case .none:
            EmptyView()
        case .prayer:
            let next = nextPrayer(lat: p.lat, lng: p.lng, tz: p.timeZone, now: now)
            Label("\(next.0.rawValue) \(PrayerPage.time(next.1, p.timeZone))", systemImage: next.0.icon)
        case .clock:
            Text(PrayerPage.time(now, .current)).monospacedDigit()
        case .weather:
            if let w = model.weather.now {
                HStack(spacing: 4) {
                    Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                    Text("\(Int(w.temp.rounded()))°")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Int(w.temp.rounded())) degrees, \(w.label)")
            }
        case .agents:
            let a = model.agents
            let idle = a.agents.count - a.working
            let text = a.agents.isEmpty ? "No agents"
                : a.working == 1 ? a.agents.first { $0.state == "working" }!.name + (idle > 0 ? " · \(idle) idle" : "")
                : "\(a.working) working · \(idle) idle"
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(a.working > 0 ? .green : .gray)
                Marquee(text: text, size: 13, weight: .semibold)
            }
        case .containers:
            let up = model.containers.containers.filter(\.running).count
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").foregroundStyle(up > 0 ? .green : .gray)
                Text(model.containers.reachable ? "\(up) running" : "Docker off")
            }
        }
    }

    private func compactRow(_ symbol: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Marquee(text: text, size: 13, weight: .semibold).monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(maxHeight: .infinity)
    }

    private func musicCompact(_ pos: TimeInterval) -> some View {
        let idx = model.showLyrics ? syncedLines.flatMap { LyricsClock.activeIndex(in: $0, at: pos) } : nil
        let text = idx.map { syncedLines![$0].text.isEmpty ? "♪" : syncedLines![$0].text } ?? titleLine
        return HStack(spacing: 10) {
            Artwork(image: model.state?.artwork, size: 22)
            Marquee(text: text, size: 13, weight: .semibold)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            Image(systemName: "waveform")
                .font(.system(size: 13))
                .opacity(model.state?.isPlaying == true ? 1 : 0.4)
                .accessibilityLabel(model.state?.isPlaying == true ? "Playing" : "Paused")
        }
        .frame(maxHeight: .infinity)
        .animation(animation(text), value: text)
    }

    // MARK: Expanded

    private func expanded(_ pos: TimeInterval, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(model.pages, id: \.self) { p in
                    Button { model.page = p } label: {
                        Image(systemName: p.icon)
                            .font(.system(size: 12))
                            .frame(width: 30, height: 22)
                            .background(Capsule().fill(.white.opacity(p == model.visiblePage ? 0.2 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(p == model.visiblePage ? 1 : 0.55)
                    .accessibilityLabel(p.label)
                }
                Spacer()
                Text(model.visiblePage.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            Group {
                switch model.visiblePage {
                case .music: musicPage(pos)
                case .agents: AgentsPage(agents: model.agents)
                case .weather: WeatherPage(weather: model.weather, place: model.location.place, now: now)
                case .prayer: PrayerPage(place: model.location.place, now: now)
                case .timer: TimerPage(timer: model.timer, now: now)
                case .containers: ContainersPage(containers: model.containers)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func musicPage(_ pos: TimeInterval) -> some View {
        let t = model.state?.track
        if t == nil {
            Note(text: "Nothing playing")
        } else {
            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Artwork(image: model.state?.artwork, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Marquee(text: t?.title ?? "", size: 14, weight: .bold)
                    Marquee(text: t?.artist ?? "", size: 12).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                controls
            }
            if let d = t?.duration, d > 0 {
                ProgressView(value: min(max(pos - model.userOffset, 0), d), total: d)
                    .progressViewStyle(.linear).tint(.white).controlSize(.mini)
            }
            if let c = model.candidates {
                candidateList(c)
                footer
            } else if model.showLyrics {
                lyricsBody(pos)
                footer
            } else {
                Note(text: "Lyrics hidden · menu bar ♪ › Show Lyrics")
            }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            button("backward.fill", "Previous track") { model.send(.previous) }
            button(model.state?.isPlaying == true ? "pause.fill" : "play.fill",
                   model.state?.isPlaying == true ? "Pause" : "Play") { model.send(.togglePlayPause) }
            button("forward.fill", "Next track") { model.send(.next) }
        }
        .font(.system(size: 16))
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 20).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    @ViewBuilder private func lyricsBody(_ pos: TimeInterval) -> some View {
        switch model.lyrics {
        case nil:
            Note(text: "Searching lyrics…")
        case .instrumental:
            Note(text: "♪ Instrumental")
        case .notFound:
            Note(text: "No lyrics found")
        case .plain(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("NOT SYNCED").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                ScrollView { Text(text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxHeight: .infinity)
        case .synced(let lines):
            let idx = LyricsClock.activeIndex(in: lines, at: pos)
            let start = max(0, (idx ?? 0) - 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(start..<min(lines.count, start + 5), id: \.self) { i in
                    Text(lines[i].text.isEmpty ? "♪" : lines[i].text)
                        .font(.system(size: i == idx ? 15 : 13, weight: i == idx ? .bold : .regular))
                        .foregroundStyle(.white.opacity(i == idx ? 1 : 0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(animation(idx), value: idx)
        }
    }

    private func candidateList(_ c: [LRCLIBRecord]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if c.isEmpty { Note(text: "Loading results…") }
                ForEach(c, id: \.id) { r in
                    Button { model.choose(r) } label: {
                        HStack {
                            Text("\(r.trackName) — \(r.artistName)").lineLimit(1)
                            Spacer()
                            Text(r.syncedLyrics != nil ? "synced" : r.instrumental ? "instr." : "plain")
                                .foregroundStyle(.white.opacity(0.5))
                            Text(r.duration.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "")
                                .monospacedDigit().foregroundStyle(.white.opacity(0.5))
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            button("minus.circle", "Show lyrics later by 0.5 seconds") { model.nudgeOffset(-0.5) }
            Text(String(format: "%+.1fs", model.userOffset)).monospacedDigit()
            button("plus.circle", "Show lyrics earlier by 0.5 seconds") { model.nudgeOffset(0.5) }
            Spacer()
            Button(model.candidates == nil ? "Wrong lyrics?" : "Cancel") {
                if model.candidates == nil { model.loadCandidates() } else { model.candidates = nil }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 11))
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if !model.adapterOK {
                Label("MediaRemote adapter failed its self-test. Using AppleScript fallback (Music and Spotify only).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            if let e = model.loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Picker("Display mode", selection: $model.displayMode) {
                Text("Notch (top edge)").tag("auto")
                Text("Floating pill").tag("floating")
            }
            Section("When nothing is playing (both Nothing hides the pill)") {
                Picker("Left", selection: $model.idleLeft) {
                    ForEach(model.idleOptions, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Right", selection: $model.idleRight) {
                    ForEach(model.idleOptions, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Picker("Show on", selection: $model.screenChoice) {
                Text("Main display").tag("main")
                Text("Display with cursor").tag("mouse")
            }
            Toggle("Hide over full-screen apps", isOn: $model.hideInFullscreen)
            Stepper(value: $model.tolerance, in: 0.5...10, step: 0.5) {
                Text("Duration tolerance: \(model.tolerance, specifier: "%.1f") s")
            }
            TextField("Ignored players (bundle IDs, comma-separated)", text: $model.blacklistText)
            if let id = model.state?.bundleID { Text("Current player: \(id)").font(.caption).textSelection(.enabled) }
            Button("Clear lyrics cache") { model.clearCache() }
            Section("Location (weather, prayer times)") {
                Toggle("Automatic location", isOn: Binding(get: { model.location.automatic },
                                                            set: { model.location.setAutomatic($0) }))
                Text("Now: \(model.location.place.name)").font(.caption)
                if model.location.denied {
                    Text("Location access is off. Allow it in System Settings › Privacy & Security › Location Services, or search a city.")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Search city", text: Bindable(model.location).query)
                ForEach(Array(model.location.results.enumerated()), id: \.offset) { _, p in
                    Button(p.name) { model.location.choose(p) }
                }
            }
            Text("Lyrics: lrclib.net (title, artist, album, duration). Weather: Open-Meteo (rounded coordinates).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 1 Hz ticks merged with lyric line start dates (sorted).
struct LineSchedule: TimelineSchedule {
    let lineDates: [Date]

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        var i = lineDates.firstIndex { $0 > start } ?? lineDates.count
        return AnyIterator {
            let current = next
            let tick = current.addingTimeInterval(1)
            if i < lineDates.count, lineDates[i] <= tick {
                next = lineDates[i]
                i += 1
            } else {
                next = tick
            }
            return current
        }
    }
}

/// Notch outline: square top with small outward flares into the menu bar, rounded bottom.
/// flare 0 + topRadius gives a plain rounded pill.
struct NotchShape: Shape {
    var flare: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, f = flare
        let t = min(topRadius, h / 2), b = min(bottomRadius, h / 2)
        let l = f, r = w - f
        var p = Path()
        if f > 0 {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addQuadCurve(to: CGPoint(x: r, y: f), control: CGPoint(x: r, y: 0))
        } else {
            p.move(to: CGPoint(x: l + t, y: 0))
            p.addLine(to: CGPoint(x: r - t, y: 0))
            p.addQuadCurve(to: CGPoint(x: r, y: t), control: CGPoint(x: r, y: 0))
        }
        p.addLine(to: CGPoint(x: r, y: h - b))
        p.addQuadCurve(to: CGPoint(x: r - b, y: h), control: CGPoint(x: r, y: h))
        p.addLine(to: CGPoint(x: l + b, y: h))
        p.addQuadCurve(to: CGPoint(x: l, y: h - b), control: CGPoint(x: l, y: h))
        if f > 0 {
            p.addLine(to: CGPoint(x: l, y: f))
            p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: l, y: 0))
        } else {
            p.addLine(to: CGPoint(x: l, y: t))
            p.addQuadCurve(to: CGPoint(x: l + t, y: 0), control: CGPoint(x: l, y: 0))
        }
        p.closeSubpath()
        return p
    }
}
