import AppKit

func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                  bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.21, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 190, yRadius: 190).fill()
    let cards: [(NSRect, NSColor)] = [
        (NSRect(x: 200, y: 468, width: 282, height: 310), NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.82, alpha: 1)),
        (NSRect(x: 524, y: 360, width: 280, height: 310), NSColor(calibratedRed: 0.91, green: 0.53, blue: 0.42, alpha: 1)),
        (NSRect(x: 200, y: 220, width: 282, height: 204), NSColor(calibratedRed: 0.63, green: 0.73, blue: 0.61, alpha: 1))
    ]
    for (rect, color) in cards {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 34, y: rect.maxY - 68, width: rect.width - 100, height: 15), xRadius: 7, yRadius: 7).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func block(_ type: String, _ content: Data) -> Data {
    var length = UInt32(content.count + 8).bigEndian
    var data = Data(type.utf8)
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(content)
    return data
}

var icons = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    icons.append(block(type, render(size)))
}
try block("icns", icons).write(to: URL(fileURLWithPath: "build/AppIcon.icns"))
