// Renders the app icon (blue squircle + cube + bandage) into an .iconset folder.
// Usage: swift make_icon.swift OUT.iconset
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with a soft shadow
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.80, blue: 0.80, alpha: 1),
                        NSColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1)])!
        .draw(in: path, angle: -60)

    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, in rect: NSRect, colors: [NSColor]) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: colors))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let r = img.size.width / img.size.height
        let fit = r > 1 ? NSSize(width: rect.width, height: rect.width / r)
                        : NSSize(width: rect.height * r, height: rect.height)
        img.draw(in: NSRect(x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2,
                            width: fit.width, height: fit.height))
    }
    symbol("cube.transparent", size: s * 0.5, weight: .light,
           in: NSRect(x: s * 0.22, y: s * 0.24, width: s * 0.56, height: s * 0.56), colors: [.white])
    symbol("bandage.fill", size: s * 0.25, weight: .regular,
           in: NSRect(x: s * 0.52, y: s * 0.16, width: s * 0.32, height: s * 0.32),
           colors: [NSColor(red: 1, green: 0.85, blue: 0.6, alpha: 1)])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
