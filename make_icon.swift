// Copyright (c) 2026 Ahmed Abokhalil. All rights reserved.

import AppKit
import Foundation

// Macindows icon: macOS squircle with a blue→indigo gradient, four white window
// panes (the Windows nod) floating over a translucent Dock pill (the Mac nod).
func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

    // macOS icon grid: artwork sits inside ~82% of the canvas
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); bg.fill()
    ctx.restoreGState()

    // Gradient body
    ctx.saveGState()
    bg.addClip()
    let grad = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.29, green: 0.62, blue: 1.00, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.95, alpha: 1), 0.55),
        (NSColor(calibratedRed: 0.24, green: 0.20, blue: 0.75, alpha: 1), 1.0))!
    grad.draw(in: rect, angle: -65)

    // Top-left highlight sheen
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    sheen.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // Dock pill near the bottom
    let dockH = rect.height * 0.11
    let dockRect = NSRect(x: rect.minX + rect.width * 0.17, y: rect.minY + rect.height * 0.12,
                          width: rect.width * 0.66, height: dockH)
    let dock = NSBezierPath(roundedRect: dockRect, xRadius: dockH / 2, yRadius: dockH / 2)
    NSColor.white.withAlphaComponent(0.28).setFill(); dock.fill()
    NSColor.white.withAlphaComponent(0.45).setStroke()
    dock.lineWidth = max(1, s * 0.004); dock.stroke()

    // Four window panes, slight gap, floating above the dock
    let paneArea = NSRect(x: rect.minX + rect.width * 0.24, y: dockRect.maxY + rect.height * 0.08,
                          width: rect.width * 0.52, height: rect.width * 0.52)
    let gap = paneArea.width * 0.08
    let pane = (paneArea.width - gap) / 2
    let radius = pane * 0.2
    let paneColors: [NSColor] = [
        NSColor.white,
        NSColor.white.withAlphaComponent(0.92),
        NSColor.white.withAlphaComponent(0.92),
        NSColor.white.withAlphaComponent(0.84),
    ]
    let origins = [
        NSPoint(x: paneArea.minX, y: paneArea.minY + pane + gap),   // top-left
        NSPoint(x: paneArea.minX + pane + gap, y: paneArea.minY + pane + gap), // top-right
        NSPoint(x: paneArea.minX, y: paneArea.minY),                // bottom-left
        NSPoint(x: paneArea.minX + pane + gap, y: paneArea.minY),   // bottom-right
    ]
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)
    for (i, o) in origins.enumerated() {
        let p = NSBezierPath(roundedRect: NSRect(origin: o, size: NSSize(width: pane, height: pane)),
                             xRadius: radius, yRadius: radius)
        paneColors[i].setFill(); p.fill()
    }
    ctx.restoreGState()

    // Title-bar strip on each pane
    for o in origins {
        let bar = NSRect(x: o.x + pane * 0.12, y: o.y + pane * 0.72, width: pane * 0.5, height: pane * 0.1)
        let b = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
        NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.95, alpha: 0.55).setFill(); b.fill()
    }

    img.unlockFocus()
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments[1]
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for s in sizes {
    if let png = renderIcon(size: s.px) {
        try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(s.name))
    }
}
