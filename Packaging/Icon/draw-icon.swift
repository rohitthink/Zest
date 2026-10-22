import AppKit
import CoreGraphics

// Zest app icon: a cream macOS-style squircle with a juicy orange slice.
// Usage: swift draw-icon.swift <out.png> [size]

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon-1024.png"
let size = args.count > 2 ? Int(args[2])! : 1024
let S = CGFloat(size) / 1024   // design units are on a 1024 canvas

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: S, y: S)
// Design coordinates: origin bottom-left, y up (CoreGraphics default).

/// Apple-style continuous-corner tile: a superellipse (n = 5) in the 824pt icon grid box.
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0) } as CFArray, locations: stops.map(\.1))!
}

// MARK: Tile

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = squircle(in: tileRect)

// Ground shadow under the tile (the macOS icon grid leaves room for it).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.30))
ctx.addPath(tile); ctx.setFillColor(rgb(0xFFE9D2)); ctx.fillPath()
ctx.restoreGState()

// Warm cream, lighter at the top.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(gradient([(0xFFF6EA, 0), (0xFFE9D2, 0.55), (0xFFD7AE, 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A soft top sheen.
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: 400, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 400, y: 860), endRadius: 520, options: [])
ctx.restoreGState()

// MARK: Orange slice

let center = CGPoint(x: 498, y: 494)
let rPeel: CGFloat = 318, rRind: CGFloat = 286, rSegOut: CGFloat = 270, rSegIn: CGFloat = 70, rHub: CGFloat = 60
let segments = 9
let gapDeg: CGFloat = 4.2
let rotation: CGFloat = -14 * .pi / 180

func disc(_ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

// Shadow of the slice on the tile.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.setShadow(offset: CGSize(width: 10, height: -22), blur: 36, color: rgb(0x8F3F00, 0.32))
ctx.addPath(disc(rPeel)); ctx.setFillColor(rgb(0xFF8A1F)); ctx.fillPath()
ctx.restoreGState()

// Peel: deep orange with a lit top-left.
ctx.saveGState()
ctx.addPath(disc(rPeel)); ctx.clip()
ctx.drawLinearGradient(gradient([(0xFFA640, 0), (0xFF8A1F, 0.45), (0xE8650C, 1)]),
                       start: CGPoint(x: center.x - 220, y: center.y + 240), end: CGPoint(x: center.x + 220, y: center.y - 240), options: [])
ctx.restoreGState()

// Rind (pith ring) and the pith between segments.
ctx.addPath(disc(rRind)); ctx.setFillColor(rgb(0xFFF4E6)); ctx.fillPath()

// Segments: juicy, brighter toward the middle.
let segGradient = gradient([(0xFFD08A, 0), (0xFFB257, 0.55), (0xFF9330, 1)])
for i in 0..<segments {
    let span = 2 * CGFloat.pi / CGFloat(segments)
    let mid = rotation + CGFloat(i) * span
    let half = span / 2 - (gapDeg * .pi / 180) / 2
    let path = CGMutablePath()
    path.addArc(center: center, radius: rSegOut, startAngle: mid - half, endAngle: mid + half, clockwise: false)
    path.addArc(center: center, radius: rSegIn, startAngle: mid + half, endAngle: mid - half, clockwise: true)
    path.closeSubpath()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawRadialGradient(segGradient, startCenter: center, startRadius: rSegIn,
                           endCenter: center, endRadius: rSegOut, options: [.drawsAfterEndLocation])
    // Juice cells: a few soft light streaks along the segment.
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22)); ctx.setLineWidth(5); ctx.setLineCap(.round)
    for k in [-0.45, 0.0, 0.45] as [CGFloat] {
        let a = mid + k * half * 0.75
        ctx.move(to: CGPoint(x: center.x + (rSegIn + 40) * cos(a), y: center.y + (rSegIn + 40) * sin(a)))
        ctx.addLine(to: CGPoint(x: center.x + (rSegOut - 46) * cos(a), y: center.y + (rSegOut - 46) * sin(a)))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

// Hub.
ctx.addPath(disc(rHub)); ctx.setFillColor(rgb(0xFFF4E6)); ctx.fillPath()

// Gloss: a soft highlight across the upper-left of the fruit.
ctx.saveGState()
ctx.addPath(disc(rRind)); ctx.clip()
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: center.x - 120, y: center.y + 150), startRadius: 0,
                       endCenter: CGPoint(x: center.x - 120, y: center.y + 150), endRadius: 260, options: [])
ctx.restoreGState()

// Peel highlight arc.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.45)); ctx.setLineWidth(9); ctx.setLineCap(.round)
ctx.addArc(center: center, radius: rPeel - 14, startAngle: 2.05, endAngle: 2.75, clockwise: false)
ctx.strokePath()

// MARK: Juice drops (the "squeeze")

func drop(at tip: CGPoint, length: CGFloat, angle: CGFloat) {
    // A teardrop pointing along `angle`, tip first.
    let r = length * 0.36
    let bodyCenter = CGPoint(x: tip.x - (length - r) * cos(angle), y: tip.y - (length - r) * sin(angle))
    let path = CGMutablePath()
    let side = CGFloat.pi / 2
    path.move(to: tip)
    path.addQuadCurve(to: CGPoint(x: bodyCenter.x + r * cos(angle + side), y: bodyCenter.y + r * sin(angle + side)),
                      control: CGPoint(x: bodyCenter.x + r * 1.1 * cos(angle + 0.55), y: bodyCenter.y + r * 1.1 * sin(angle + 0.55)))
    path.addArc(center: bodyCenter, radius: r, startAngle: angle + side, endAngle: angle - side, clockwise: false)
    path.addQuadCurve(to: tip,
                      control: CGPoint(x: bodyCenter.x + r * 1.1 * cos(angle - 0.55), y: bodyCenter.y + r * 1.1 * sin(angle - 0.55)))
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 3, height: -6), blur: 10, color: rgb(0x8F3F00, 0.25))
    ctx.addPath(path); ctx.setFillColor(rgb(0xFF8A1F)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFB45C, 0), (0xF2700F, 1)]),
                           start: CGPoint(x: bodyCenter.x - r, y: bodyCenter.y + r), end: CGPoint(x: bodyCenter.x + r, y: bodyCenter.y - r), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(ellipseIn: CGRect(x: bodyCenter.x - r * 0.45, y: bodyCenter.y + r * 0.05, width: r * 0.42, height: r * 0.42), transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.65)); ctx.fillPath()
}
// Drops flung off the top-right of the peel; a flying drop trails its point toward where it came from.
drop(at: CGPoint(x: 773.9, y: 783.7), length: 100, angle: -2.3318)   // tail points back at the slice
drop(at: CGPoint(x: 849.3, y: 714.2), length: 64, angle: -2.5816)   // tail points back at the slice

// MARK: Write

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)px)")
