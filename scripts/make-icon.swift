// Draws the app icon. Run: swift scripts/make-icon.swift  → scripts/AppIcon.icns
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt rounded square centered in 1024, with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.12, blue: 0.42, alpha: 1),
                        NSColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 1)])!.draw(in: body, angle: -90)

    // The island: a black pill hanging from the top edge, with artwork dot + waveform.
    let pill = NSRect(x: 252, y: 700, width: 520, height: 118)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: 59, yRadius: 59).fill()
    NSGradient(colors: [NSColor(red: 1, green: 0.42, blue: 0.55, alpha: 1), NSColor(red: 1, green: 0.66, blue: 0.30, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: NSRect(x: 290, y: 724, width: 70, height: 70), xRadius: 18, yRadius: 18), angle: -45)
    NSColor.white.setFill()
    for (i, h) in [26, 52, 36, 60, 30].enumerated() {
        let x = 610 + CGFloat(i) * 25
        NSBezierPath(roundedRect: NSRect(x: x, y: 759 - CGFloat(h) / 2, width: 13, height: CGFloat(h)), xRadius: 6.5, yRadius: 6.5).fill()
    }
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 384, y: 750, width: 190, height: 18), xRadius: 9, yRadius: 9).fill()

    // Lyric lines: the active one bright, the rest fading.
    let lines: [(CGFloat, CGFloat, CGFloat)] = [(560, 520, 1.0), (470, 420, 0.45), (380, 470, 0.25), (290, 340, 0.12)]
    for (y, w, a) in lines {
        let r = NSRect(x: 512 - w / 2, y: y, width: w, height: 44)
        let p = NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22)
        if a == 1 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40, color: NSColor(red: 1, green: 0.5, blue: 0.6, alpha: 0.8).cgColor)
            NSGradient(colors: [NSColor(red: 1, green: 0.42, blue: 0.55, alpha: 1), NSColor(red: 1, green: 0.66, blue: 0.30, alpha: 1)])!
                .draw(in: p, angle: 0)
            ctx.restoreGState()
        } else {
            NSColor.white.withAlphaComponent(a).setFill(); p.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
print(dir.path)
