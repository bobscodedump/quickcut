// Draws the app icon (a lemon slice whose 8 segments mirror the wheel, one segment "popped" like a
// highlighted slice) and writes DragWheel/Resources/AppIcon.icns.
// Usage: swift scripts/make_icon.swift [preview.png]
import CoreGraphics
import Foundation
import ImageIO

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func point(_ c: CGPoint, _ r: CGFloat, _ angle: CGFloat) -> CGPoint {
    // angle 0 = 12 o'clock, clockwise (y-up coordinates)
    CGPoint(x: c.x + r * sin(angle), y: c.y + r * cos(angle))
}

/// Annular sector from `inner` to `outer` between two angles.
func wedge(_ c: CGPoint, inner: CGFloat, outer: CGFloat, from a0: CGFloat, to a1: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 48
    for i in 0...steps {
        let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
        i == 0 ? path.move(to: point(c, outer, a)) : path.addLine(to: point(c, outer, a))
    }
    for i in stride(from: steps, through: 0, by: -1) {
        path.addLine(to: point(c, inner, a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)))
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // Squircle background (macOS icon grid: 824 pt body inside 1024 canvas), with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bg = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(bg); ctx.setFillColor(rgb(0x1E6FD9)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let bgGradient = CGGradient(colorsSpace: nil, colors: [rgb(0x5BC0FF), rgb(0x1E6FD9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // subtle top sheen
    let sheen = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 500)
    let rind: CGFloat = 318, pith: CGFloat = 292, flesh: CGFloat = 276
    let segments = 8
    let span = 2 * CGFloat.pi / CGFloat(segments)
    let gap: CGFloat = 0.075          // membrane between segments (radians)
    let popped = 1                    // the "highlighted" segment
    let pop: CGFloat = 40

    // Slice shadow + rind (gradient yellow → deeper yellow at the edge).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x0A3D7A, 0.45))
    ctx.addEllipse(in: CGRect(x: c.x - rind, y: c.y - rind, width: rind * 2, height: rind * 2))
    ctx.setFillColor(rgb(0xF2C200)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - rind, y: c.y - rind, width: rind * 2, height: rind * 2)); ctx.clip()
    let rindGradient = CGGradient(colorsSpace: nil, colors: [rgb(0xFFE14D), rgb(0xF5B800)] as CFArray, locations: [0.82, 1])!
    ctx.drawRadialGradient(rindGradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: rind, options: [])
    ctx.restoreGState()

    // Pith (white ring + membranes).
    ctx.addEllipse(in: CGRect(x: c.x - pith, y: c.y - pith, width: pith * 2, height: pith * 2))
    ctx.setFillColor(rgb(0xFFF8DC)); ctx.fillPath()

    func drawSegment(_ i: Int, offset: CGFloat) {
        let a0 = CGFloat(i) * span - span / 2 + gap / 2
        let a1 = CGFloat(i + 1) * span - span / 2 - gap / 2
        let mid = (a0 + a1) / 2
        let cc = point(c, offset, mid)
        let path = wedge(cc, inner: 34, outer: flesh - 10, from: a0, to: a1)
        ctx.saveGState()
        if offset > 0 { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x7A5A00, 0.45)) }
        // Rounded corners: fill, then stroke with a round join in the same colour.
        ctx.addPath(path); ctx.setFillColor(rgb(0xFFD21F)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(rgb(0xFFD21F)); ctx.setLineWidth(18); ctx.setLineJoin(.round); ctx.strokePath()
        ctx.restoreGState()
        // Juicy gradient (brighter towards the centre) + vesicle streaks.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let juice = CGGradient(colorsSpace: nil, colors: [rgb(0xFFF3A0), rgb(0xFFDA2E), rgb(0xFFC800)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(juice, startCenter: cc, startRadius: 20, endCenter: cc, endRadius: flesh, options: [])
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.38)); ctx.setLineCap(.round); ctx.setLineWidth(7)
        for k in 0..<3 {
            let a = a0 + (a1 - a0) * (0.28 + 0.22 * CGFloat(k))
            ctx.move(to: point(cc, 110 + CGFloat(k % 2) * 30, a))
            ctx.addLine(to: point(cc, 190 + CGFloat(k % 2) * 40, a))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    for i in 0..<segments where i != popped { drawSegment(i, offset: 0) }

    // Centre pith.
    ctx.addEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
    ctx.setFillColor(rgb(0xFFF8DC)); ctx.fillPath()

    // The popped segment leaves its socket showing pith, and floats outward with a shadow.
    drawSegment(popped, offset: pop)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(drawIcon(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = root.appendingPathComponent("DragWheel/Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let icns = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run(); iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("Wrote \(icns.path)")
if CommandLine.arguments.count > 1 {
    writePNG(drawIcon(size: 1024), to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Preview: \(CommandLine.arguments[1])")
}
