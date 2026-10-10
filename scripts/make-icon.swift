import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var iconChunks = Data()
func encodedSize(_ value: Int) -> Data { var bigEndian = UInt32(value).bigEndian; return withUnsafeBytes(of: &bigEndian) { Data($0) } }
let types = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"], 256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let rect = NSRect(x: 80, y: 80, width: 864, height: 864)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
        NSColor(srgbRed: 0.16, green: 0.36, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 194, yRadius: 194).fill()
        NSShadow().set()
        NSColor(srgbRed: 0.97, green: 0.95, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 286, y: 235, width: 454, height: 572), xRadius: 36, yRadius: 36).fill()
        NSColor(srgbRed: 0.74, green: 0.82, blue: 0.71, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 268, y: 235, width: 40, height: 572), xRadius: 12, yRadius: 12).fill()
        NSColor(srgbRed: 0.30, green: 0.46, blue: 0.36, alpha: 0.5).setStroke()
        for y in [650, 570, 490] {
            let line = NSBezierPath(); line.lineWidth = 16; line.lineCapStyle = .round; line.move(to: NSPoint(x: 366, y: y)); line.line(to: NSPoint(x: y == 490 ? 540 : 646, y: y)); line.stroke()
        }
        let pen = NSBezierPath(); pen.move(to: NSPoint(x: 505, y: 298)); pen.line(to: NSPoint(x: 554, y: 401)); pen.line(to: NSPoint(x: 817, y: 664)); pen.curve(to: NSPoint(x: 755, y: 726), controlPoint1: NSPoint(x: 857, y: 705), controlPoint2: NSPoint(x: 799, y: 769)); pen.line(to: NSPoint(x: 492, y: 463)); pen.close()
        NSColor(srgbRed: 0.83, green: 0.66, blue: 0.36, alpha: 1).setFill(); pen.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)); NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: destination.appendingPathComponent(name))
        iconChunks.append(types[size]![scale - 1].data(using: .ascii)!); iconChunks.append(encodedSize(png.count + 8)); iconChunks.append(png)
    }
}
var icon = "icns".data(using: .ascii)!; icon.append(encodedSize(iconChunks.count + 8)); icon.append(iconChunks)
try icon.write(to: destination.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
