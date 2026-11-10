// Generates the ppaste app icon (1024x1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt rounded square centred in the 1024 canvas
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
NSColor.black.setFill(); bodyPath.fill()
ctx.restoreGState()

ctx.saveGState(); bodyPath.addClip()
NSGradient(colors: [NSColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 1),
                    NSColor(red: 0.18, green: 0.10, blue: 0.55, alpha: 1)])!.draw(in: body, angle: -60)
// soft highlight
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
ctx.restoreGState()

// A fanned row of history cards (the shelf), the front one is a clipboard
func card(_ r: NSRect, fill: NSColor, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: angle * .pi / 180); ctx.translateBy(x: -r.midX, y: -r.midY)
    let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.3); s.shadowBlurRadius = 18
    s.shadowOffset = NSSize(width: 0, height: -8); s.set()
    fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44).fill()
    ctx.restoreGState()
}
card(NSRect(x: 212, y: 262, width: 330, height: 440), fill: NSColor(red: 1.0, green: 0.55, blue: 0.30, alpha: 1), angle: 11)
card(NSRect(x: 482, y: 262, width: 330, height: 440), fill: NSColor(red: 0.30, green: 0.80, blue: 0.95, alpha: 1), angle: -11)

let front = NSRect(x: 352, y: 232, width: 320, height: 470)
card(front, fill: .white, angle: 0)
// clip
NSColor(white: 0.25, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: front.midX - 70, y: front.maxY - 38, width: 140, height: 70), xRadius: 26, yRadius: 26).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: front.midX - 34, y: front.maxY - 12, width: 68, height: 26), xRadius: 13, yRadius: 13).fill()
// text lines
NSColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 0.9).setFill()
for (i, w) in [220.0, 220.0, 150.0].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: front.minX + 50, y: front.maxY - 150 - CGFloat(i) * 62, width: w, height: 28), xRadius: 14, yRadius: 14).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
