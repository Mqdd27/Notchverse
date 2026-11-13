import AppKit
import LyricsCore
import SwiftUI

struct PillView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(model.state?.isPlaying ?? false))) { ctx in
            let pos = model.clock?.position(at: ctx.date) ?? 0
            Group {
                if model.expanded { expanded(pos) } else { compact(pos) }
            }
            .padding(.horizontal, 14)
            .padding(.top, model.notchInset + (model.expanded ? 14 : 0))
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

    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = model.expanded ? 22 : 19
        let top: CGFloat = model.notchInset > 0 ? 0 : r // flush with the screen edge in notch mode
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: top)
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

    private func compact(_ pos: TimeInterval) -> some View {
        let idx = model.showLyrics ? syncedLines.flatMap { LyricsClock.activeIndex(in: $0, at: pos) } : nil
        let text = idx.map { syncedLines![$0].text.isEmpty ? "♪" : syncedLines![$0].text } ?? titleLine
        return HStack(spacing: 10) {
            Artwork(image: model.state?.artwork, size: 22)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .id(text)
                .transition(.opacity)
            Image(systemName: "waveform")
                .font(.system(size: 13))
                .symbolEffect(.variableColor.iterative, isActive: model.state?.isPlaying == true && !reduceMotion)
                .opacity(model.state?.isPlaying == true ? 1 : 0.4)
                .accessibilityLabel(model.state?.isPlaying == true ? "Playing" : "Paused")
        }
        .frame(maxHeight: .infinity)
        .animation(animation(text), value: text)
    }

    // MARK: Expanded

    private func expanded(_ pos: TimeInterval) -> some View {
        let t = model.state?.track
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Artwork(image: model.state?.artwork, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t?.title ?? "").font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(t?.artist ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
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
            note("Searching lyrics…")
        case .instrumental:
            note("♪ Instrumental")
        case .notFound:
            note("No lyrics found")
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

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateList(_ c: [LRCLIBRecord]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if c.isEmpty { note("Loading results…") }
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
                Text("Automatic").tag("auto")
                Text("Notch").tag("notch")
                Text("Floating pill").tag("floating")
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
            Text("Lyrics come from lrclib.net. Only title, artist, album and duration are sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
