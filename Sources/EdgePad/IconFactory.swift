import AppKit

enum IconFactory {
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let s = size
            let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
            let body = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)

            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
            shadow.shadowBlurRadius = s * 0.025
            shadow.set()
            NSColor.black.setFill()
            body.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.28, alpha: 1),
                       ending: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1))?
                .draw(in: body, angle: -90)

            let pad = NSRect(x: s * 0.22, y: s * 0.28, width: s * 0.56, height: s * 0.44)
            let padPath = NSBezierPath(roundedRect: pad, xRadius: s * 0.05, yRadius: s * 0.05)
            NSColor(white: 1, alpha: 0.09).setFill()
            padPath.fill()
            NSColor(white: 1, alpha: 0.2).setStroke()
            padPath.lineWidth = max(1, s * 0.006)
            padPath.stroke()

            let barW = s * 0.04
            let inset = s * 0.035
            let trackH = pad.height - inset * 2
            func bar(x: CGFloat, fill: CGFloat, color: NSColor) {
                let track = NSRect(x: x, y: pad.minY + inset, width: barW, height: trackH)
                NSColor(white: 1, alpha: 0.12).setFill()
                NSBezierPath(roundedRect: track, xRadius: barW / 2, yRadius: barW / 2).fill()
                let level = NSRect(x: x, y: pad.minY + inset, width: barW, height: trackH * fill)
                color.setFill()
                NSBezierPath(roundedRect: level, xRadius: barW / 2, yRadius: barW / 2).fill()
            }
            bar(x: pad.minX + inset, fill: 0.55, color: NSColor(calibratedRed: 1, green: 0.72, blue: 0.2, alpha: 1))
            bar(x: pad.maxX - inset - barW, fill: 0.8, color: NSColor(calibratedRed: 0.25, green: 0.6, blue: 1, alpha: 1))
            return true
        }
    }

    /// 18pt template image: a trackpad outline with a level bar on each side.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.2
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 3.4, y: 5.4, width: 1.8, height: 5), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(roundedRect: NSRect(x: 12.8, y: 5.4, width: 1.8, height: 7.2), xRadius: 0.9, yRadius: 0.9).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func writeIconset(to path: String) throws {
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try png(appIcon(size: CGFloat(px)), pixels: px).write(to: dir.appendingPathComponent(name))
            }
        }
    }

    static func png(_ image: NSImage, pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
