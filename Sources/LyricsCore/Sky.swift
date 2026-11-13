import Foundation

// MARK: Prayer times
// Ported from github.com/Mqdd27/prayer-times (Kemenag RI: Fajr 20°, Isha 18°, Asr Shafi'i, +2 min ihtiyat).

public enum Prayer: String, CaseIterable, Sendable {
    case fajr = "Fajr", dhuhr = "Dhuhr", asr = "Asr", maghrib = "Maghrib", isha = "Isha"

    public var icon: String {
        switch self {
        case .fajr: "sunrise"
        case .dhuhr: "sun.max"
        case .asr: "sun.min"
        case .maghrib: "sunset"
        case .isha: "moon.stars"
        }
    }
}

public func prayerTimes(lat: Double, lng: Double, tz: TimeZone, day: Date) -> [(Prayer, Date)] {
    let rad = Double.pi / 180
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day], from: day)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let midnightUTC = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
    let jd = midnightUTC.timeIntervalSince1970 / 86400 + 2440587.5

    // Sun position at local noon
    let d = jd + 0.5 - lng / 360 - 2451545.0
    let g = (357.529 + 0.98560028 * d) * rad
    let q = 280.459 + 0.98564736 * d
    let L = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
    let e = (23.439 - 0.00000036 * d) * rad
    var ra = atan2(cos(e) * sin(L), cos(L)) / rad / 15
    ra = (ra + 24).truncatingRemainder(dividingBy: 24)
    var eqt = q / 15 - ra
    eqt -= 24 * (eqt / 24).rounded()
    let decl = asin(sin(e) * sin(L))
    let phi = lat * rad

    let noon = 12 - lng / 15 - eqt // UTC hours
    func hourAngle(_ altitude: Double) -> Double {
        acos((sin(altitude * rad) - sin(phi) * sin(decl)) / (cos(phi) * cos(decl))) / rad / 15
    }
    let asrAlt = atan(1 / (1 + tan(abs(phi - decl)))) / rad
    let sunrise = noon - hourAngle(-0.833), sunset = noon + hourAngle(-0.833)
    // High latitudes: the sun may never reach -20°/-18°, fall back to a share of the night.
    let night = 24 - (sunset - sunrise)
    var fajr = noon - hourAngle(-20), isha = noon + hourAngle(-18)
    if fajr.isNaN || sunrise - fajr > night * 20 / 60 { fajr = sunrise - night * 20 / 60 }
    if isha.isNaN || isha - sunset > night * 18 / 60 { isha = sunset + night * 18 / 60 }
    let hours: [(Prayer, Double)] = [(.fajr, fajr), (.dhuhr, noon), (.asr, noon + hourAngle(asrAlt)), (.maghrib, sunset), (.isha, isha)]
    return hours.map { p, h in
        let t = midnightUTC.addingTimeInterval((h + 2.0 / 60) * 3600).timeIntervalSince1970
        return (p, Date(timeIntervalSince1970: (t / 60).rounded(.down) * 60))
    }
}

/// The next prayer after `now`, rolling over to tomorrow's Fajr.
public func nextPrayer(lat: Double, lng: Double, tz: TimeZone, now: Date = Date()) -> (Prayer, Date) {
    prayerTimes(lat: lat, lng: lng, tz: tz, day: now).first { $0.1 > now }
        ?? prayerTimes(lat: lat, lng: lng, tz: tz, day: now.addingTimeInterval(86400))[0]
}

// MARK: Moon phase

/// Mean synodic month from a reference new moon. ponytail: ±~0.5 day error, use a full lunar theory if exact times matter.
public struct MoonPhase: Sendable {
    public static let synodicMonth = 29.530588853
    /// Days since the last new moon.
    public let age: Double

    public init(date: Date = Date()) {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let a = (jd - 2451550.25972).truncatingRemainder(dividingBy: Self.synodicMonth) // new moon 2000-01-06 18:14 UTC
        age = a < 0 ? a + Self.synodicMonth : a
    }

    public var fraction: Double { age / Self.synodicMonth }
    public var illumination: Double { (1 - cos(2 * .pi * fraction)) / 2 }

    private static let phases: [(upTo: Double, name: String, symbol: String)] = [
        (0.0339, "New Moon", "moonphase.new.moon"),
        (0.216, "Waxing Crescent", "moonphase.waxing.crescent"),
        (0.284, "First Quarter", "moonphase.first.quarter"),
        (0.466, "Waxing Gibbous", "moonphase.waxing.gibbous"),
        (0.534, "Full Moon", "moonphase.full.moon"),
        (0.716, "Waning Gibbous", "moonphase.waning.gibbous"),
        (0.784, "Last Quarter", "moonphase.last.quarter"),
        (0.966, "Waning Crescent", "moonphase.waning.crescent"),
        (1.01, "New Moon", "moonphase.new.moon"),
    ]
    private var phase: (upTo: Double, name: String, symbol: String) { Self.phases.first { fraction < $0.upTo }! }
    public var name: String { phase.name }
    public var symbol: String { phase.symbol }
}
