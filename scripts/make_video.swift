// Renders a short product video for Zest (1920×1080, 30 fps) and encodes it with ffmpeg.
// Every frame is drawn in code, using the app's real wheel geometry, menu bar glyph and icon.
//
// Build & run (from the repo root):
//   swiftc -O -parse-as-library -o build/make_video scripts/make_video.swift \
//     DragWheel/UI/WheelGeometry.swift DragWheel/Core/WheelVisibilityPolicy.swift DragWheel/UI/LemonGlyph.swift
//   build/make_video media/Zest-demo.mp4
import AppKit
import UniformTypeIdentifiers

// MARK: - Canvas & timing

let W = 1920, H = 1080, FPS = 30
let DURATION = 26.0
let CW = CGFloat(W), CH = CGFloat(H)

func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
func prog(_ t: Double, _ start: Double, _ dur: Double) -> Double { clamp((t - start) / dur) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
/// Damped spring 0 → 1 with a little overshoot.
func spring(_ x: Double) -> Double { x <= 0 ? 0 : (x >= 1 ? 1 : 1 - exp(-6 * x) * cos(9 * x)) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
/// 0 → 1 → 0 window with fades of `fade` seconds.
func window(_ t: Double, _ start: Double, _ end: Double, fade: Double = 0.35) -> Double {
    min(prog(t, start, fade), 1 - prog(t, end - fade, fade))
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let accent = rgb(0x0A84FF)
let lemon = rgb(0xFFD21F)

// MARK: - Drawing helpers (context is flipped: origin top-left, y down)

var ctx: CGContext!

func withState(_ body: () -> Void) { ctx.saveGState(); body(); ctx.restoreGState() }

func fillRounded(_ rect: CGRect, radius: CGFloat, color: NSColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color.cgColor); ctx.fillPath()
}

func strokeRounded(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat = 1) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.strokePath()
}

func shadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
}

enum Align { case left, center, right }

@discardableResult
func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
          align: Align = .center, alpha: Double = 1, rounded: Bool = false) -> CGSize {
    guard alpha > 0.001 else { return .zero }
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * CGFloat(alpha))])
    let sz = str.size()
    let x: CGFloat = align == .left ? p.x : (align == .center ? p.x - sz.width / 2 : p.x - sz.width)
    str.draw(at: CGPoint(x: x, y: p.y - sz.height / 2))
    return sz
}

func image(_ img: NSImage, _ rect: CGRect, alpha: Double = 1) {
    guard alpha > 0.001 else { return }
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(alpha), respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

var symbolCache: [String: NSImage] = [:]
func symbol(_ name: String, size: CGFloat, color: NSColor = .white, weight: NSFont.Weight = .semibold) -> NSImage {
    let key = "\(name)|\(size)|\(color)|\(weight.rawValue)"
    if let cached = symbolCache[key] { return cached }
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))!
    let tinted = NSImage(size: base.size, flipped: false) { r in
        base.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
    }
    symbolCache[key] = tinted
    return tinted
}

func drawSymbol(_ name: String, center: CGPoint, size: CGFloat, color: NSColor = .white, alpha: Double = 1, weight: NSFont.Weight = .semibold) {
    let img = symbol(name, size: size, color: color, weight: weight)
    image(img, CGRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2, width: img.size.width, height: img.size.height), alpha: alpha)
}

var iconCache: [String: NSImage] = [:]
/// Finder-style photo thumbnail (white border, landscape with a sun) for image files.
let photoThumbnail: NSImage = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
    let frame = NSRect(x: 8, y: 22, width: 112, height: 84)
    let sh = NSShadow(); sh.shadowBlurRadius = 4; sh.shadowOffset = NSSize(width: 0, height: -1); sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
    NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.white.setFill(); frame.fill(); NSGraphicsContext.restoreGraphicsState()
    let pic = frame.insetBy(dx: 4, dy: 4)
    NSGradient(starting: rgb(0x7EC8FF), ending: rgb(0xFFE3A3))!.draw(in: pic, angle: -90)
    rgb(0xFFD21F).setFill(); NSBezierPath(ovalIn: NSRect(x: pic.maxX - 34, y: pic.maxY - 30, width: 20, height: 20)).fill()
    let hills = NSBezierPath()
    hills.move(to: NSPoint(x: pic.minX, y: pic.minY)); hills.line(to: NSPoint(x: pic.minX, y: pic.minY + 26))
    hills.curve(to: NSPoint(x: pic.midX, y: pic.minY + 20), controlPoint1: NSPoint(x: pic.minX + 25, y: pic.minY + 48), controlPoint2: NSPoint(x: pic.midX - 20, y: pic.minY + 40))
    hills.curve(to: NSPoint(x: pic.maxX, y: pic.minY + 30), controlPoint1: NSPoint(x: pic.midX + 25, y: pic.minY + 5), controlPoint2: NSPoint(x: pic.maxX - 20, y: pic.minY + 40))
    hills.line(to: NSPoint(x: pic.maxX, y: pic.minY)); hills.close()
    rgb(0x3E9B5C).setFill(); hills.fill()
    return true
}
func fileIcon(_ ext: String) -> NSImage {
    if ["png", "jpg"].contains(ext) { return photoThumbnail }
    if let cached = iconCache[ext] { return cached }
    let type: UTType = ext == "folder" ? .folder : (UTType(filenameExtension: ext) ?? .data)
    let icon = NSWorkspace.shared.icon(for: type)
    iconCache[ext] = icon
    return icon
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIcon = NSImage(contentsOf: root.appendingPathComponent("DragWheel/Resources/AppIcon.icns")) ?? NSImage()

// MARK: - Scene pieces

func wallpaper(dim: Double = 0) {
    let colors = [rgb(0x1B2A4A).cgColor, rgb(0x2D4E7E).cgColor, rgb(0x6A5A8C).cgColor, rgb(0xC98A6B).cgColor] as CFArray
    let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.4, 0.75, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: CW, y: CH), options: [])
    // soft lemon glow
    let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xFFD21F, 0.22).cgColor, rgb(0xFFD21F, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 1500, y: 260), startRadius: 0, endCenter: CGPoint(x: 1500, y: 260), endRadius: 700, options: [])
    if dim > 0 { ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(dim)).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH)) }
}

func menuBar() {
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: CW, height: 34))
    text("Finder", CGPoint(x: 40, y: 17), size: 15, weight: .bold, align: .left)
    var x: CGFloat = 120
    for item in ["File", "Edit", "View", "Go", "Window"] {
        x += text(item, CGPoint(x: x, y: 17), size: 15, align: .left).width + 26
    }
    let glyph = LemonGlyph.menuBarImage(size: 20)
    let white = NSImage(size: glyph.size, flipped: false) { r in glyph.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
    image(white, CGRect(x: CW - 260, y: 7, width: 20, height: 20))
    drawSymbol("wifi", center: CGPoint(x: CW - 205, y: 17), size: 15, weight: .medium)
    drawSymbol("battery.75percent", center: CGPoint(x: CW - 160, y: 17), size: 15, weight: .medium)
    text("Sat 10:41", CGPoint(x: CW - 30, y: 17), size: 15, weight: .medium, align: .right)
}

struct FileItem { let name: String; let ext: String; let position: CGPoint }
let finderFrame = CGRect(x: 260, y: 200, width: 820, height: 560)
let files = [
    FileItem(name: "photo.png", ext: "png", position: CGPoint(x: 560, y: 400)),
    FileItem(name: "report.docx", ext: "docx", position: CGPoint(x: 760, y: 400)),
    FileItem(name: "clip.mov", ext: "mov", position: CGPoint(x: 960, y: 400)),
]
let newFilePosition = CGPoint(x: 560, y: 600)

func finderWindow(selected: Bool, newFileAppear: Double, alpha: Double) {
    withState {
        ctx.setAlpha(CGFloat(alpha))
        withState { shadow(40, 18, 0.45); fillRounded(finderFrame, radius: 16, color: rgb(0xFFFFFF)) }
        // sidebar + title bar
        withState {
            ctx.addPath(CGPath(roundedRect: finderFrame, cornerWidth: 16, cornerHeight: 16, transform: nil)); ctx.clip()
            ctx.setFillColor(rgb(0xF0F0F3).cgColor); ctx.fill(CGRect(x: finderFrame.minX, y: finderFrame.minY, width: 200, height: finderFrame.height))
            ctx.setFillColor(rgb(0xE4E4E8).cgColor); ctx.fill(CGRect(x: finderFrame.minX + 200, y: finderFrame.minY + 64, width: finderFrame.width - 200, height: 1))
        }
        for (i, c) in [rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840)].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: finderFrame.minX + 22 + CGFloat(i) * 22, y: finderFrame.minY + 24, width: 14, height: 14))
        }
        text("Desktop", CGPoint(x: finderFrame.minX + 226, y: finderFrame.minY + 32), size: 17, weight: .bold, color: rgb(0x1D1D1F), align: .left)
        for (i, item) in [("Recents", "clock"), ("Applications", "square.grid.2x2"), ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle")].enumerated() {
            let y = finderFrame.minY + 100 + CGFloat(i) * 36
            if item.0 == "Desktop" { fillRounded(CGRect(x: finderFrame.minX + 10, y: y - 15, width: 180, height: 30), radius: 7, color: rgb(0xDCDCE2)) }
            drawSymbol(item.1, center: CGPoint(x: finderFrame.minX + 34, y: y), size: 14, color: accent, weight: .medium)
            text(item.0, CGPoint(x: finderFrame.minX + 54, y: y), size: 14, color: rgb(0x1D1D1F), align: .left)
        }
        for (i, f) in files.enumerated() {
            let isSel = selected && i == 0
            if isSel { fillRounded(CGRect(x: f.position.x - 70, y: f.position.y - 70, width: 140, height: 136), radius: 10, color: rgb(0x000000, 0.07)) }
            image(fileIcon(f.ext), CGRect(x: f.position.x - 56, y: f.position.y - 66, width: 112, height: 112))
            if isSel {
                let w = text(f.name, CGPoint(x: -1000, y: -1000), size: 14).width
                fillRounded(CGRect(x: f.position.x - w / 2 - 8, y: f.position.y + 52, width: w + 16, height: 22), radius: 6, color: accent)
            }
            text(f.name, CGPoint(x: f.position.x, y: f.position.y + 63), size: 14, color: isSel ? .white : rgb(0x1D1D1F))
        }
        if newFileAppear > 0 {
            let s = CGFloat(spring(newFileAppear))
            let p = newFilePosition
            withState {
                ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: s, y: s); ctx.translateBy(x: -p.x, y: -p.y)
                image(fileIcon("jpg"), CGRect(x: p.x - 56, y: p.y - 66, width: 112, height: 112))
                text("photo.jpg", CGPoint(x: p.x, y: p.y + 63), size: 14, color: rgb(0x1D1D1F))
            }
        }
    }
}

func cursor(_ p: CGPoint, ghost: String? = nil, ghostAlpha: Double = 0.8, copyBadge: Bool = false) {
    if let ghost {
        // Drag image sits below-right of the pointer so it doesn't hide what's being pointed at.
        image(fileIcon(ghost), CGRect(x: p.x + 16, y: p.y + 18, width: 72, height: 72), alpha: ghostAlpha)
        if copyBadge {
            ctx.setFillColor(rgb(0x30D158).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x + 70, y: p.y + 72, width: 28, height: 28))
            text("+", CGPoint(x: p.x + 84, y: p.y + 85), size: 22, weight: .bold)
        }
    }
    // macOS-style arrow: black with a white outline; tip at p.
    let pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4, y: 13.2), CGPoint(x: 6.8, y: 19.6),
                          CGPoint(x: 9.4, y: 18.5), CGPoint(x: 6.7, y: 12.3), CGPoint(x: 12, y: 12.3)]
    let arrow = CGMutablePath()
    arrow.addLines(between: pts.map { CGPoint(x: p.x + $0.x * 1.9, y: p.y + $0.y * 1.9) }); arrow.closeSubpath()
    withState {
        shadow(4, 2, 0.35)
        ctx.addPath(arrow); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(4); ctx.setLineJoin(.round); ctx.strokePath()
    }
    ctx.addPath(arrow); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
}

struct Slice { let title: String; let symbol: String; var enabled = true }

/// The wheel, drawn exactly like the app's (WheelGeometry), as a dark glass HUD.
func wheel(center: CGPoint, slices: [Slice], hovered: Int?, appear: Double, title: String, subtitle: String, scale: CGFloat = 1.3) {
    guard appear > 0.001 else { return }
    let g = WheelGeometry(scale: scale)
    let n = slices.count
    let s = CGFloat(0.45 + 0.55 * spring(appear))
    withState {
        ctx.setAlpha(CGFloat(clamp(appear * 2.5)))
        ctx.translateBy(x: center.x, y: center.y); ctx.scaleBy(x: s, y: s)
        withState {
            shadow(36, 14, 0.5)
            ctx.setFillColor(rgb(0x1C1C20, 0.9).cgColor)
            for i in 0..<n { ctx.addPath(g.slicePath(ring: .primary, index: i, count: n, center: .zero).cgPath) }
            ctx.addEllipse(in: CGRect(x: -g.hubRadius, y: -g.hubRadius, width: g.hubRadius * 2, height: g.hubRadius * 2))
            ctx.fillPath()
        }
        for (i, slice) in slices.enumerated() {
            let isHover = hovered == i
            withState {
                if isHover { ctx.scaleBy(x: 1.07, y: 1.07) }
                let path = g.slicePath(ring: .primary, index: i, count: n, center: .zero).cgPath
                ctx.addPath(path)
                ctx.setFillColor((isHover ? accent.withAlphaComponent(0.95) : NSColor.white.withAlphaComponent(0.07)).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(isHover ? 0.6 : 0.16).cgColor); ctx.setLineWidth(1.2); ctx.strokePath()
                let lp = g.labelCenter(ring: .primary, index: i, count: n, center: .zero)
                let a = slice.enabled ? 1.0 : 0.35
                drawSymbol(slice.symbol, center: CGPoint(x: lp.x, y: lp.y - 12 * scale), size: 22 * scale, alpha: a)
                text(slice.title, CGPoint(x: lp.x, y: lp.y + 17 * scale), size: 12.5 * scale, weight: .semibold, alpha: a)
            }
        }
        text(title, CGPoint(x: 0, y: -9 * scale), size: 13 * scale, weight: .semibold)
        text(subtitle, CGPoint(x: 0, y: 11 * scale), size: 10.5 * scale, color: NSColor.white.withAlphaComponent(0.7))
    }
}

/// Where the cursor aims inside a slice: just outside the label, so the label stays readable.
func slicePoint(center: CGPoint, index: Int, count: Int, scale: CGFloat = 1.3) -> CGPoint {
    let g = WheelGeometry(scale: scale)
    let label = g.labelCenter(ring: .primary, index: index, count: count, center: center)
    // Same slice, rotated a bit clockwise and pushed towards the rim: beside the label, not on it.
    let angle = Double(atan2(label.x - center.x, -(label.y - center.y))) + (count == 1 ? 0.6 : min(0.24, Double.pi / Double(count) * 0.6))
    let r = g.outerRadius * 0.9
    return CGPoint(x: center.x + r * CGFloat(sin(angle)), y: center.y - r * CGFloat(cos(angle)))
}

func caption(step: Int?, _ s: String, alpha: Double) {
    guard alpha > 0.001 else { return }
    let size = text(s, CGPoint(x: -5000, y: -5000), size: 30, weight: .semibold)
    let extra: CGFloat = step == nil ? 0 : 58
    let w = size.width + 64 + extra
    let rect = CGRect(x: CW / 2 - w / 2, y: CH - 130, width: w, height: 70)
    let rise = CGFloat((1 - easeOut(alpha)) * 20)
    withState {
        ctx.setAlpha(CGFloat(alpha))
        ctx.translateBy(x: 0, y: rise)
        withState { shadow(24, 8, 0.35); fillRounded(rect, radius: 35, color: rgb(0x111114, 0.82)) }
        strokeRounded(rect, radius: 35, color: NSColor.white.withAlphaComponent(0.12))
        var x = rect.minX + 32
        if let step {
            ctx.setFillColor(lemon.cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: rect.midY - 22, width: 44, height: 44))
            text("\(step)", CGPoint(x: x + 22, y: rect.midY), size: 24, weight: .heavy, color: rgb(0x1D1D1F), rounded: true)
            x += 58
        }
        text(s, CGPoint(x: x, y: rect.midY), size: 30, weight: .semibold, align: .left)
    }
}

func keycap(_ p: CGPoint, pressed: Double, alpha: Double) {
    guard alpha > 0.001 else { return }
    let down = CGFloat(pressed * 5)
    let rect = CGRect(x: p.x, y: p.y + down, width: 170, height: 74)
    withState {
        ctx.setAlpha(CGFloat(alpha))
        withState { shadow(down > 2 ? 4 : 14, down > 2 ? 2 : 7, 0.45); fillRounded(rect, radius: 14, color: rgb(0xF5F5F7)) }
        strokeRounded(rect.insetBy(dx: 1, dy: 1), radius: 13, color: rgb(0xD1D1D6), width: 2)
        text("⇧", CGPoint(x: rect.minX + 30, y: rect.minY + 24), size: 26, weight: .medium, color: rgb(0x3A3A3C))
        text("shift", CGPoint(x: rect.maxX - 20, y: rect.maxY - 20), size: 20, weight: .medium, color: rgb(0x3A3A3C), align: .right)
    }
}

func notification(progress p: Double) {
    guard p > 0.001 else { return }
    let x = lerp(CW + 20, CW - 520, easeOut(p))
    let rect = CGRect(x: x, y: 56, width: 480, height: 104)
    withState {
        withState { shadow(30, 10, 0.35); fillRounded(rect, radius: 22, color: rgb(0xF2F2F5, 0.97)) }
        image(appIcon, CGRect(x: rect.minX + 14, y: rect.minY + 18, width: 68, height: 68))
        text("Zest", CGPoint(x: rect.minX + 96, y: rect.minY + 28), size: 17, weight: .bold, color: rgb(0x1D1D1F), align: .left)
        text("now", CGPoint(x: rect.maxX - 20, y: rect.minY + 28), size: 15, color: rgb(0x8E8E93), align: .right)
        text("Converted to JPEG", CGPoint(x: rect.minX + 96, y: rect.minY + 54), size: 17, weight: .semibold, color: rgb(0x1D1D1F), align: .left)
        text("photo.jpg — click to reveal.", CGPoint(x: rect.minX + 96, y: rect.minY + 79), size: 16, color: rgb(0x3A3A3C), align: .left)
    }
}

func appTitle(center: CGPoint, appear: Double, tagline: String, iconSize: CGFloat = 300) {
    let s = CGFloat(spring(appear))
    withState {
        ctx.translateBy(x: center.x, y: center.y - 90); ctx.scaleBy(x: s, y: s)
        image(appIcon, CGRect(x: -iconSize / 2, y: -iconSize / 2, width: iconSize, height: iconSize), alpha: clamp(appear * 3))
    }
    let ta = prog(appear, 0.35, 0.4)
    text("Zest", CGPoint(x: center.x, y: center.y + 120 + CGFloat((1 - easeOut(ta)) * 20)), size: 110, weight: .heavy, alpha: ta, rounded: true)
    let tb = prog(appear, 0.55, 0.4)
    text(tagline, CGPoint(x: center.x, y: center.y + 210), size: 38, weight: .medium, color: NSColor.white.withAlphaComponent(0.85), alpha: tb)
}

// MARK: - Timeline

let imageSlices = [Slice(title: "JPEG", symbol: "photo.fill"), Slice(title: "PDF", symbol: "doc.richtext"), Slice(title: "TXT", symbol: "doc.plaintext"),
                   Slice(title: "HEIC", symbol: "photo.on.rectangle"), Slice(title: "GIF", symbol: "play.square.stack"), Slice(title: "WebP", symbol: "globe"),
                   Slice(title: "TIFF", symbol: "photo.stack"), Slice(title: "More…", symbol: "ellipsis.circle")]

struct MontageCard { let title: String; let subtitle: String; let ghost: String; let slices: [Slice]; let hover: Int; let caption: String }
let montage = [
    MontageCard(title: "3 files", subtitle: "Drop on a format", ghost: "pdf",
                slices: [Slice(title: "Merge PDF", symbol: "doc.on.doc"), Slice(title: "JPEG", symbol: "photo.fill"), Slice(title: "TXT", symbol: "doc.plaintext"), Slice(title: "ZIP All", symbol: "archivebox.fill")],
                hover: 0, caption: "Several PDFs or images → one merged PDF"),
    MontageCard(title: "report.docx", subtitle: "Drop on a format", ghost: "docx",
                slices: [Slice(title: "PDF", symbol: "doc.richtext"), Slice(title: "TXT", symbol: "doc.plaintext"), Slice(title: "HTML", symbol: "chevron.left.forwardslash.chevron.right"), Slice(title: "RTF", symbol: "doc.text"), Slice(title: "ODT", symbol: "doc")],
                hover: 0, caption: "Documents → PDF with searchable text"),
    MontageCard(title: "Vacation", subtitle: "Drop on a format", ghost: "folder",
                slices: [Slice(title: "ZIP", symbol: "doc.zipper")], hover: 0, caption: "Folders → ZIP · archives are extracted"),
    MontageCard(title: "clip.mov", subtitle: "Drop on a format", ghost: "mov",
                slices: [Slice(title: "MP4", symbol: "film"), Slice(title: "MP3", symbol: "music.note"), Slice(title: "M4A", symbol: "music.note.list"), Slice(title: "GIF", symbol: "play.square.stack"), Slice(title: "WAV", symbol: "waveform"), Slice(title: "MKV", symbol: "rectangle.stack"), Slice(title: "WebM", symbol: "play.rectangle")],
                hover: 3, caption: "Video → MP4, GIF, or audio only (MP3, M4A, WAV)"),
    MontageCard(title: "screenshot.png", subtitle: "Drop on a format", ghost: "png",
                slices: imageSlices, hover: 2, caption: "Images and scanned PDFs → text (OCR)"),
]

func drawFrame(_ t: Double) {
    ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH))

    // 1. Intro (0 – 3.4)
    if t < 3.8 {
        let a = 1 - prog(t, 3.2, 0.6)
        withState {
            ctx.setAlpha(CGFloat(a))
            let g = CGGradient(colorsSpace: nil, colors: [rgb(0x5BC0FF).cgColor, rgb(0x1E6FD9).cgColor, rgb(0x0E3C8C).cgColor] as CFArray, locations: [0, 0.6, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: CH), options: [])
            appTitle(center: CGPoint(x: CW / 2, y: CH / 2), appear: prog(t, 0.2, 1.6), tagline: "A macOS menu bar app that converts files by dragging.")
        }
    }

    // 2. Main demo (3.2 – 13.4)
    if t >= 3.2 && t < 13.8 {
        let sceneAlpha = min(prog(t, 3.2, 0.6), 1 - prog(t, 13.2, 0.6))
        withState {
            ctx.setAlpha(CGFloat(sceneAlpha))
            wallpaper()
            menuBar()
            let dragStart = files[0].position
            let dragPoint = CGPoint(x: 1360, y: 470)
            let jpeg = slicePoint(center: dragPoint, index: 0, count: imageSlices.count)
            var cur = CGPoint(x: 1500, y: 900)
            cur = lerp(cur, dragStart, easeInOut(prog(t, 4.0, 1.0)))
            cur = lerp(cur, dragPoint, easeInOut(prog(t, 5.5, 1.1)))
            cur = lerp(cur, jpeg, easeInOut(prog(t, 7.8, 0.9)))
            let dragging = t >= 5.4 && t < 9.4
            let hovering = t >= 8.55 && t < 9.4
            finderWindow(selected: t >= 5.2, newFileAppear: prog(t, 9.7, 0.6), alpha: 1)

            let wheelAppear = prog(t, 7.1, 0.9) * (1 - prog(t, 9.4, 0.25))
            let subtitle = hovering ? "Convert to JPEG" : "Drop on a format"
            wheel(center: dragPoint, slices: imageSlices, hovered: hovering ? 0 : nil, appear: wheelAppear, title: "photo.png", subtitle: subtitle)

            keycap(CGPoint(x: dragPoint.x + 240, y: dragPoint.y + 250), pressed: prog(t, 6.95, 0.12) * (1 - prog(t, 9.3, 0.1)), alpha: window(t, 6.75, 9.6, fade: 0.25))
            cursor(cur, ghost: dragging ? "png" : nil, copyBadge: hovering)
            notification(progress: prog(t, 10.0, 0.45) * (1 - prog(t, 12.6, 0.4)))

            caption(step: 1, "Start dragging a file", alpha: window(t, 3.9, 6.75))
            caption(step: 2, "Press Shift while dragging — the wheel opens", alpha: window(t, 6.75, 8.55))
            caption(step: 3, "Drop it on a format", alpha: window(t, 8.55, 10.0))
            caption(step: nil, "photo.jpg is saved next to the original", alpha: window(t, 10.0, 13.0))
        }
    }

    // 3. Montage (13.2 – 20.6), 1.45 s per card
    let montageStart = 13.4, card = 1.45
    if t >= montageStart - 0.2 && t < montageStart + card * Double(montage.count) + 0.4 {
        let alpha = min(prog(t, montageStart - 0.2, 0.4), 1 - prog(t, montageStart + card * Double(montage.count) - 0.1, 0.4))
        withState {
            ctx.setAlpha(CGFloat(alpha))
            wallpaper(dim: 0.25)
            let idx = min(montage.count - 1, max(0, Int((t - montageStart) / card)))
            let local = t - montageStart - Double(idx) * card
            let m = montage[idx]
            let center = CGPoint(x: CW / 2, y: CH / 2 - 40)
            let appear = prog(local, 0, 0.55)
            let hovering = local > 0.55
            let target = slicePoint(center: center, index: m.hover, count: m.slices.count)
            let cur = lerp(CGPoint(x: center.x + 40, y: center.y + 20), target, easeInOut(prog(local, 0.2, 0.4)))
            let sub = hovering ? (m.slices[m.hover].title == "ZIP" ? "Convert to ZIP" : "Convert to \(m.slices[m.hover].title)") : m.subtitle
            wheel(center: center, slices: m.slices, hovered: hovering ? m.hover : nil, appear: appear, title: m.title, subtitle: sub)
            cursor(cur, ghost: m.ghost, copyBadge: hovering)
            caption(step: nil, m.caption, alpha: min(prog(local, 0.1, 0.25), 1 - prog(local, card - 0.15, 0.15)))
        }
    }

    // 4. Features (20.4 – 23.4)
    if t >= 20.3 && t < 23.6 {
        let a = window(t, 20.3, 23.5, fade: 0.4)
        withState {
            ctx.setAlpha(CGFloat(a))
            wallpaper(dim: 0.45)
            text("What it converts", CGPoint(x: CW / 2, y: 210), size: 60, weight: .bold)
            let tiles: [(String, String, String)] = [
                ("photo", "Images", "PNG · JPEG · HEIC · WebP · AVIF · ICNS"),
                ("doc.richtext", "PDF", "Pages to images · merge · text"),
                ("doc.text", "Documents", "DOCX · RTF · HTML · Markdown → PDF"),
                ("film", "Video & audio", "MP4 · MOV · GIF · MP3 · FLAC (needs ffmpeg)"),
                ("archivebox", "Archives", "Zip folders · extract ZIP, TAR, 7z"),
                ("text.viewfinder", "Text recognition", "Screenshots and scans → text"),
            ]
            for (i, tile) in tiles.enumerated() {
                let col = i % 3, row = i / 3
                let appear = easeOut(prog(t, 20.5 + Double(i) * 0.08, 0.45))
                let rect = CGRect(x: 250 + CGFloat(col) * 480, y: 330 + CGFloat(row) * 250 + CGFloat((1 - appear) * 30), width: 440, height: 210)
                withState {
                    ctx.setAlpha(CGFloat(a * appear))
                    fillRounded(rect, radius: 26, color: rgb(0x111114, 0.75))
                    strokeRounded(rect, radius: 26, color: NSColor.white.withAlphaComponent(0.12))
                    ctx.setFillColor(lemon.cgColor)
                    ctx.fillEllipse(in: CGRect(x: rect.minX + 30, y: rect.minY + 30, width: 64, height: 64))
                    drawSymbol(tile.0, center: CGPoint(x: rect.minX + 62, y: rect.minY + 62), size: 28, color: rgb(0x1D1D1F))
                    text(tile.1, CGPoint(x: rect.minX + 30, y: rect.minY + 128), size: 32, weight: .bold, align: .left)
                    text(tile.2, CGPoint(x: rect.minX + 30, y: rect.minY + 170), size: 19, color: NSColor.white.withAlphaComponent(0.75), align: .left)
                }
            }
            text("Converts locally on your Mac. Output goes next to the original; existing files are never overwritten.", CGPoint(x: CW / 2, y: 900), size: 28, weight: .medium,
                 color: NSColor.white.withAlphaComponent(0.85), alpha: prog(t, 21.0, 0.5))
        }
    }

    // 5. Outro (23.3 – 26)
    if t >= 23.3 {
        let a = prog(t, 23.3, 0.5) * (1 - prog(t, DURATION - 0.4, 0.4))
        withState {
            ctx.setAlpha(CGFloat(a))
            let g = CGGradient(colorsSpace: nil, colors: [rgb(0x5BC0FF).cgColor, rgb(0x1E6FD9).cgColor, rgb(0x0E3C8C).cgColor] as CFArray, locations: [0, 0.6, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: CH), options: [])
            appTitle(center: CGPoint(x: CW / 2, y: CH / 2), appear: prog(t, 23.4, 1.4), tagline: "Drag a file  ·  press Shift  ·  drop on a format")
            text("To cancel: release Shift, press Esc, or drop anywhere else.", CGPoint(x: CW / 2, y: CH - 130), size: 24, color: NSColor.white.withAlphaComponent(0.8), alpha: prog(t, 24.2, 0.5))
            text("macOS 14 or later  ·  Optional: ffmpeg (video/audio), LibreOffice (Office files)", CGPoint(x: CW / 2, y: CH - 85), size: 22, color: NSColor.white.withAlphaComponent(0.65), alpha: prog(t, 24.4, 0.5))
        }
    }
}

// MARK: - Render & encode

@main
struct MakeVideo {
    static func main() throws {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "media/Zest-demo.mp4"
        let posterPath = (out as NSString).deletingPathExtension + "-poster.png"
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
        let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpegPath else { fatalError("ffmpeg not found (brew install ffmpeg)") }

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpeg.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(W)x\(H)", "-r", "\(FPS)", "-i", "-",
                            "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
        let pipe = Pipe()
        ffmpeg.standardInput = pipe
        try ffmpeg.run()

        let bytesPerRow = W * 4
        let context = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CH)
        context.scaleBy(x: 1, y: -1)
        ctx = context
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let total = Int(DURATION * Double(FPS))
        for frame in 0..<total {
            let t = Double(frame) / Double(FPS)
            withState { drawFrame(t) }
            pipe.fileHandleForWriting.write(Data(bytes: context.data!, count: bytesPerRow * H))
            if frame == Int(9.0 * Double(FPS)) {   // poster: wheel open, JPEG highlighted
                let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: posterPath))
            }
            if frame % 150 == 0 { print("frame \(frame)/\(total)") }
        }
        try pipe.fileHandleForWriting.close()
        ffmpeg.waitUntilExit()
        guard ffmpeg.terminationStatus == 0 else { fatalError("ffmpeg failed") }
        print("Wrote \(out) and \(posterPath)")
    }
}
