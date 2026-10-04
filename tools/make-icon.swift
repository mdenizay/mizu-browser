// Draws the app icon — a water drop on a plate of deep water ("mizu" is water
// in Japanese) — and writes the PNG sizes iconutil needs.
// Usage: swift tools/make-icon.swift <output.iconset>
import AppKit

let space = CGColorSpaceCreateDeviceRGB()

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.30, blue: 0.75, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let water = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.33, green: 0.80, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.10, green: 0.47, blue: 0.95, alpha: 1),
        CGColor(srgbRed: 0.07, green: 0.22, blue: 0.62, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(water, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A soft highlight along the top edge, like light on glass.
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 990), startRadius: 0, endCenter: CGPoint(x: 512, y: 990), endRadius: 560, options: [])
    // Two ripples spreading under the drop.
    for (radius, alpha) in [(250.0, 0.20), (370.0, 0.11)] {
        ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
        ctx.setLineWidth(14)
        ctx.strokeEllipse(in: CGRect(x: 512 - radius, y: 250 - radius * 0.26, width: radius * 2, height: radius * 0.52))
    }
    ctx.restoreGState()

    // The drop: a circle drawn up to a point.
    let drop = CGMutablePath()
    let centre = CGPoint(x: 512, y: 440), radius: CGFloat = 170, tip = CGPoint(x: 512, y: 790)
    drop.move(to: tip)
    drop.addCurve(to: CGPoint(x: centre.x + radius, y: centre.y), control1: CGPoint(x: 560, y: 690), control2: CGPoint(x: centre.x + radius, y: 560))
    drop.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi, clockwise: true)
    drop.addCurve(to: tip, control1: CGPoint(x: centre.x - radius, y: 560), control2: CGPoint(x: 464, y: 690))
    drop.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(srgbRed: 0, green: 0.12, blue: 0.40, alpha: 0.40))
    ctx.addPath(drop)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(drop)
    ctx.clip()
    let body = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(srgbRed: 0.80, green: 0.92, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: 512, y: 790), end: CGPoint(x: 512, y: 270), options: [])
    // The curve of light inside the drop.
    ctx.setStrokeColor(CGColor(srgbRed: 0.20, green: 0.60, blue: 0.98, alpha: 0.55))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.addArc(center: centre, radius: 104, startAngle: .pi * 1.08, endAngle: .pi * 1.45, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(size: size).write(to: out.appendingPathComponent("icon_\(name).png"))
}
