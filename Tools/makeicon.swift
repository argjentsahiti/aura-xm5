import AppKit
import Foundation

// Generates Aura.icns.
//
// Draws the macOS icon shape as a true superellipse (|x|^n + |y|^n = 1, n ≈ 5)
// rather than a rounded rectangle — circular corners read subtly wrong against
// the rest of the Dock.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// Apple's icon grid: the shape occupies ~80% of the canvas, the rest is the
/// breathing room the Dock expects.
let shapeRatio: CGFloat = 0.804

func superellipse(in rect: CGRect, n: CGFloat = 5.0, samples: Int = 720) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY

    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        // Signed power keeps the curve continuous through all four quadrants.
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
        else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Renders a template symbol as solid white on transparency.
func whiteGlyph(_ symbol: NSImage, size: CGSize) -> NSBitmapImageRep? {
    let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = size

    let previous = NSGraphicsContext.current
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = gc
    let full = CGRect(origin: .zero, size: size)
    symbol.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1.0)
    // Destination alpha here is the glyph's own, so this recolours it cleanly.
    NSColor.white.set()
    full.fill(using: .sourceAtop)
    NSGraphicsContext.current = previous
    return rep
}

/// Draws at exactly `size` × `size` device pixels.
///
/// `NSImage.lockFocus()` inherits the main display's backing scale, which on a
/// Retina Mac silently produces 2× assets — `iconutil` then rejects the set. An
/// explicitly-sized bitmap rep guarantees 1:1.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    let previous = NSGraphicsContext.current
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
    NSGraphicsContext.current = gc
    defer { NSGraphicsContext.current = previous }

    let ctx = gc.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = size * (1 - shapeRatio) / 2
    let shapeRect = CGRect(x: inset, y: inset,
                           width: size - inset * 2, height: size - inset * 2)
    let shape = superellipse(in: shapeRect)

    // Soft contact shadow so the icon sits on the Dock rather than floating.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.035,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    // Body gradient — the app's accent, deepened so white sits cleanly on it.
    ctx.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.42, green: 0.68, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.44, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.29, blue: 0.78, alpha: 1),
    ], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)
    gradient?.draw(in: shapeRect, angle: -90)

    // Gloss: a soft falloff from the top edge. An elliptical highlight leaves a
    // visible boundary where the curve ends; a linear fade doesn't.
    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.20),
        NSColor.white.withAlphaComponent(0.0),
    ], atLocations: [0.0, 1.0], colorSpace: .sRGB)
    gloss?.draw(in: CGRect(x: shapeRect.minX,
                           y: shapeRect.minY + shapeRect.height * 0.45,
                           width: shapeRect.width,
                           height: shapeRect.height * 0.55),
                angle: -90)
    ctx.restoreGState()

    // Inner top highlight — the 1px light edge Apple icons carry.
    ctx.saveGState()
    shape.addClip()
    let rim = superellipse(in: shapeRect.insetBy(dx: size * 0.004, dy: size * 0.004))
    rim.lineWidth = max(1, size * 0.006)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    rim.stroke()
    ctx.restoreGState()

    // Headphones glyph, matching the menu-bar symbol.
    let glyphSize = size * 0.50
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {

        let s = symbol.size
        let scale = min(glyphSize / max(s.width, s.height), 4)
        let w = s.width * scale, h = s.height * scale
        let rect = CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                      blur: size * 0.02,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)

        // Tint in a transparent scratch bitmap first. Filling `.sourceAtop`
        // straight onto the icon would use the gradient's alpha — which is fully
        // opaque — and paint a solid white block instead of the glyph.
        if let glyph = whiteGlyph(symbol, size: rect.size) {
            glyph.draw(in: rect, from: .zero, operation: .sourceOver,
                       fraction: 1.0, respectFlipped: true, hints: nil)
        }
        ctx.restoreGState()
    }

    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data? {
    rep.representation(using: .png, properties: [:])
}

// Standard .iconset contents.
let variants: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("Aura.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for v in variants {
    // Redrawn at each size rather than downsampled, so small sizes stay crisp.
    let rep = drawIcon(size: v.px)
    guard let data = png(rep) else {
        FileHandle.standardError.write("failed: \(v.name)\n".data(using: .utf8)!)
        continue
    }
    try data.write(to: iconset.appendingPathComponent(v.name))
}

print("wrote \(iconset.path)")
