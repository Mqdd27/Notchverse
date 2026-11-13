import LyricsCore
import SwiftUI

struct Note: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private let secondary = Color.white.opacity(0.55)

// MARK: Agents (tuios)

struct AgentsPage: View {
    let agents: AgentsService

    var body: some View {
        if agents.binary == nil {
            Note(text: "tuios not found")
        } else if agents.agents.isEmpty {
            Note(text: "No agents running")
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(agents.agents) { a in
                        Button { agents.focus(a) } label: { row(a) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(a.name), \(a.needs_you ? "needs you" : a.state). Focus pane")
                    }
                }
            }
        }
    }

    private func row(_ a: AgentsService.Agent) -> some View {
        HStack(spacing: 10) {
            Circle().fill(a.needs_you ? .orange : a.state == "working" ? .green : .gray).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Marquee(text: a.name, size: 13, weight: .semibold)
                Text([a.harness_id, a.folder, a.session].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer()
            Text(a.needs_you ? "needs you" : a.state).font(.system(size: 11, weight: .medium))
                .foregroundStyle(a.needs_you ? .orange : secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
        .contentShape(Rectangle())
    }
}

// MARK: Weather + moon

struct WeatherPage: View {
    let weather: WeatherService
    let place: LocationStore.Place
    let now: Date

    var body: some View {
        let moon = MoonPhase(date: now)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(place.name, systemImage: "location.fill").font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                if let w = weather.now {
                    HStack(spacing: 10) {
                        Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 38))
                        Text("\(Int(w.temp.rounded()))°").font(.system(size: 44, weight: .light))
                    }
                    Text(w.label).font(.system(size: 14, weight: .semibold))
                    Text("H \(Int(w.high.rounded()))°  L \(Int(w.low.rounded()))°  ·  Feels \(Int(w.feels.rounded()))°")
                        .font(.system(size: 11)).foregroundStyle(secondary)
                    Text("Wind \(Int(w.wind.rounded())) km/h").font(.system(size: 11)).foregroundStyle(secondary)
                } else {
                    Note(text: weather.failed ? "Weather unavailable" : "Loading weather…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                Image(systemName: moon.symbol).font(.system(size: 44)).padding(.top, 10)
                Text(moon.name).font(.system(size: 13, weight: .semibold))
                Text("\(Int((moon.illumination * 100).rounded()))% lit · day \(Int(moon.age))")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
            .frame(width: 140)
            .accessibilityElement(children: .combine)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(LinearGradient(
                colors: weather.now?.isDay == false ? [.indigo.opacity(0.5), .black] : [.blue.opacity(0.45), .cyan.opacity(0.15)],
                startPoint: .top, endPoint: .bottom))
        )
    }
}

// MARK: Prayer times

struct PrayerPage: View {
    let place: LocationStore.Place
    let now: Date

    static func time(_ d: Date, _ tz: TimeZone) -> String {
        var f = Date.FormatStyle(date: .omitted, time: .shortened)
        f.timeZone = tz
        return d.formatted(f)
    }

    var body: some View {
        let tz = place.timeZone
        let times = prayerTimes(lat: place.lat, lng: place.lng, tz: tz, day: now)
        let next = nextPrayer(lat: place.lat, lng: place.lng, tz: tz, now: now)
        let mins = Int(next.1.timeIntervalSince(now) / 60) + 1
        VStack(spacing: 4) {
            HStack {
                Label(place.name, systemImage: "location.fill").lineLimit(1)
                Spacer()
                Text("\(next.0.rawValue) in " + (mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"))
            }
            .font(.system(size: 11)).foregroundStyle(secondary)
            ForEach(Array(times.enumerated()), id: \.offset) { _, item in
                let isNext = item.0 == next.0 && item.1 == next.1
                HStack {
                    Image(systemName: item.0.icon).frame(width: 22)
                    Text(item.0.rawValue)
                    Spacer()
                    Text(Self.time(item.1, tz)).monospacedDigit()
                }
                .font(.system(size: 14, weight: isNext ? .bold : .regular))
                .foregroundStyle(isNext ? .white : .white.opacity(item.1 < now ? 0.4 : 0.75))
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isNext ? 0.15 : 0)))
            }
        }
    }
}

// MARK: Timer

struct TimerPage: View {
    let timer: TimerModel
    let now: Date

    var body: some View {
        let running = timer.end != nil
        let rem = timer.remaining(at: now)
        HStack(spacing: 24) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: running && timer.total > 0 ? rem / timer.total : 0)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(running ? TimerModel.format(rem) : "Ready").font(.system(size: 24, weight: .medium)).monospacedDigit()
            }
            .frame(width: 140, height: 140)
            .accessibilityElement(children: .combine)
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(56)), count: 3), spacing: 8) {
                    ForEach(TimerModel.presets, id: \.self) { m in
                        Button("\(m)m") { timer.start(minutes: m) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 56, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                            .accessibilityLabel("Start \(m) minute timer")
                    }
                }
                if running {
                    Button("Cancel") { timer.cancel() }.buttonStyle(.plain).foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Containers (docker CLI)

struct ContainersPage: View {
    let containers: ContainersService

    var body: some View {
        if !containers.reachable {
            Note(text: "Docker isn't reachable. Is Colima running? (colima start)")
        } else if containers.containers.isEmpty {
            Note(text: "No containers")
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(containers.containers) { c in
                        HStack(spacing: 10) {
                            Circle().fill(c.running ? .green : .gray).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Marquee(text: c.name, size: 13, weight: .semibold)
                                Text("\(c.image) · \(c.status)").font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(c.running ? "Stop" : "Start") { containers.toggle(c) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(c.running ? .orange : .green)
                                .accessibilityLabel("\(c.running ? "Stop" : "Start") \(c.name)")
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
                    }
                }
            }
        }
    }
}

// MARK: Running text

/// Single-line text that scrolls when it doesn't fit (static under Reduce Motion).
/// Width is measured with AppKit because @State needs the SwiftUI macro plugin, missing without Xcode.
struct Marquee: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var alignment: Alignment = .leading // when it fits
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nsFont: NSFont {
        let w: NSFont.Weight = switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
        return NSFont.systemFont(ofSize: size, weight: w)
    }

    var body: some View {
        let font = nsFont
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        GeometryReader { geo in
            if textWidth <= geo.size.width || reduceMotion {
                Text(text).lineLimit(1).frame(maxWidth: .infinity, alignment: alignment)
            } else {
                let gap: CGFloat = 40, speed: CGFloat = 30 // points per second
                let cycle = textWidth + gap
                HStack(spacing: gap) { Text(text); Text(text) }
                    .fixedSize()
                    .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { content, x in
                        content.offset(x: x)
                    } keyframes: { _ in
                        LinearKeyframe(0, duration: 1.5) // pause at the start of each loop
                        LinearKeyframe(-cycle, duration: cycle / speed)
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                                 .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .accessibilityLabel(text)
            }
        }
        .font(.system(size: size, weight: weight))
        .frame(height: ceil(NSLayoutManager().defaultLineHeight(for: font)))
        .id(text) // restart the scroll when the text changes
    }
}
