// Draws Andeville's app icon, the one in the site's footer (.foot-icon in site/index.html), and packs it into
// Andeville.icns beside this file. Run after changing it: swift make-icon.swift
import CoreGraphics
import Foundation
import ImageIO

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// The macOS icon shape, a superellipse (n = 5), filling `r`.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<360 {
        let t = CGFloat(i) * .pi / 180, c = cos(t), s = sin(t)
        let at = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 0.4),
                         y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 0.4))
        if i == 0 { p.move(to: at) } else { p.addLine(to: at) }
    }
    p.closeSubpath()
    return p
}

/// The brand mark, in its 668.1 box (illustrator/SVG/5.svg).
let mark: [[CGFloat]] = [
    [205.86, 305.25, 33.23, 669.54, 0, 668.1, 208.1, 245.56, 205.86, 305.25],
    [205.86, 305.25, 342.79, 668.1, 355.78, 668.1, 323.15, 320.05, 208.14, 244.44, 205.86, 305.25],
    [481.53, 411.32, 350.62, 283.23, 323.4, 321.66, 370.24, 668.1, 445.68, 668.1, 481.53, 411.32],
    [489.22, 668.1, 440.13, 371.17, 576.88, 210.25, 668.1, 668.1],
]

func icon(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    // Apple's icon grid: an 824 body centred on a 1024 canvas. Drawn in the site SVG's frame, a 100 box with y running down.
    ctx.translateBy(x: 100 * k, y: 924 * k)
    ctx.scaleBy(x: 8.24 * k, y: -8.24 * k)
    let body = squircle(CGRect(x: 0, y: 0, width: 100, height: 100))

    ctx.saveGState() // The drop shadow, under the body (shadow sizes are in pixels, whatever the scale).
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 24 * k, color: color(0, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0x121212))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState() // Lit from above, with a soft sheen across the top.
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x3C3C3A)), (0.48, color(0x1E1E1D)), (1, color(0x121212))]),
                           start: .zero, end: CGPoint(x: 0, y: 100), options: [])
    let top = CGPoint(x: 50, y: -15)
    ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.16)), (1, color(0xFFFFFF, 0))]),
                           startCenter: top, startRadius: 0, endCenter: top, endRadius: 85, options: [])
    ctx.restoreGState()

    ctx.saveGState() // A thin rim of light inside the edge: bright on top, nearly gone on the sides, back a little below.
    ctx.addPath(squircle(CGRect(x: 0.75, y: 0.75, width: 98.5, height: 98.5)))
    ctx.setLineWidth(1.5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.5)), (0.3, color(0xFFFFFF, 0.1)), (0.75, color(0xFFFFFF, 0.06)), (1, color(0xFFFFFF, 0.22))]),
                           start: .zero, end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    ctx.translateBy(x: 22, y: 13.5)
    ctx.scaleBy(x: 0.084, y: 0.084)
    ctx.setFillColor(color(0xFF5B14))
    for polygon in mark {
        ctx.addLines(between: stride(from: 0, to: polygon.count, by: 2).map { CGPoint(x: polygon[$0], y: polygon[$0 + 1]) })
        ctx.closePath()
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Andeville.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = set.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
        let out = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(out, icon(points * scale), nil)
        guard CGImageDestinationFinalize(out) else { fatalError("could not write \(file.path)") }
    }
}
let pack = Process()
pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", "-o", here.appendingPathComponent("Andeville.icns").path, set.path]
try pack.run()
pack.waitUntilExit()
exit(pack.terminationStatus)
