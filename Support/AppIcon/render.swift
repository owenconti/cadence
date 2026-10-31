#!/usr/bin/env swift
// Run from any directory: swift Support/AppIcon/render.swift
// Draws the master, all ten iconset PNGs, and Cadence.icns using macOS frameworks.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255, alpha
    ])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

// Two cubic segments per corner ease the straight sides into a continuous curve.
// The opaque body occupies 824 × 824 points, with a 100-point margin on each side.
func tilePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let corner: CGFloat = 230
    let x = rect.minX, y = rect.minY, r = rect.maxX, t = rect.maxY
    let c = corner * rect.width / 824
    path.move(to: CGPoint(x: x + c, y: t))
    path.addLine(to: CGPoint(x: r - c, y: t))
    path.addCurve(to: CGPoint(x: r - c * 0.178, y: t - c * 0.178),
                  control1: CGPoint(x: r - c * 0.565, y: t),
                  control2: CGPoint(x: r - c * 0.356, y: t))
    path.addCurve(to: CGPoint(x: r, y: t - c),
                  control1: CGPoint(x: r, y: t - c * 0.356),
                  control2: CGPoint(x: r, y: t - c * 0.565))
    path.addLine(to: CGPoint(x: r, y: y + c))
    path.addCurve(to: CGPoint(x: r - c * 0.178, y: y + c * 0.178),
                  control1: CGPoint(x: r, y: y + c * 0.565),
                  control2: CGPoint(x: r, y: y + c * 0.356))
    path.addCurve(to: CGPoint(x: r - c, y: y),
                  control1: CGPoint(x: r - c * 0.356, y: y),
                  control2: CGPoint(x: r - c * 0.565, y: y))
    path.addLine(to: CGPoint(x: x + c, y: y))
    path.addCurve(to: CGPoint(x: x + c * 0.178, y: y + c * 0.178),
                  control1: CGPoint(x: x + c * 0.565, y: y),
                  control2: CGPoint(x: x + c * 0.356, y: y))
    path.addCurve(to: CGPoint(x: x, y: y + c),
                  control1: CGPoint(x: x, y: y + c * 0.356),
                  control2: CGPoint(x: x, y: y + c * 0.565))
    path.addLine(to: CGPoint(x: x, y: t - c))
    path.addCurve(to: CGPoint(x: x + c * 0.178, y: t - c * 0.178),
                  control1: CGPoint(x: x, y: t - c * 0.565),
                  control2: CGPoint(x: x, y: t - c * 0.356))
    path.addCurve(to: CGPoint(x: x + c, y: t),
                  control1: CGPoint(x: x + c * 0.356, y: t),
                  control2: CGPoint(x: x + c * 0.565, y: t))
    path.closeSubpath()
    return path
}

func context(size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawIcon(_ ctx: CGContext) {
    let body = tilePath(in: CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 20,
                  color: color(0x000000, alpha: 0.38))
    ctx.addPath(body)
    ctx.setFillColor(color(0x111116))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x25242D), color(0x15151C), color(0x0C0C10)],
                                    [0, 0.55, 1]),
                           start: CGPoint(x: 300, y: 924), end: CGPoint(x: 690, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A faint warm reflection connects the dark material to the coral mark.
    ctx.drawRadialGradient(gradient([color(0xFF6A55, alpha: 0.055), color(0xFF6A55, alpha: 0)], [0, 1]),
                           startCenter: CGPoint(x: 380, y: 630), startRadius: 0,
                           endCenter: CGPoint(x: 380, y: 630), endRadius: 470, options: [])
    ctx.addPath(body)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, alpha: 0.25), color(0xFFFFFF, alpha: 0.035),
                                     color(0x000000, alpha: 0.5)], [0, 0.5, 1]),
                           start: CGPoint(x: 330, y: 924), end: CGPoint(x: 650, y: 100), options: [])
    ctx.restoreGState()

    // The shared baseline and unequal heights read as an audio meter at 16 px.
    let bars = CGMutablePath()
    for (x, height): (CGFloat, CGFloat) in [(288, 264), (452, 440), (616, 336)] {
        bars.addRoundedRect(in: CGRect(x: x, y: 304, width: 112, height: height),
                            cornerWidth: 56, cornerHeight: 56)
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 9,
                  color: color(0x000000, alpha: 0.3))
    ctx.addPath(bars)
    ctx.setFillColor(color(0xC0397A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bars)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFF8C70), color(0xFF6A55), color(0xC0397A)],
                                    [0, 0.3, 1]),
                           start: CGPoint(x: 300, y: 740), end: CGPoint(x: 750, y: 270),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Restrained edge lighting rather than a glossy bevel.
    ctx.addPath(bars)
    ctx.setLineWidth(2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFE3CC, alpha: 0.5), color(0xFFFFFF, alpha: 0)], [0, 1]),
                           start: CGPoint(x: 300, y: 750), end: CGPoint(x: 600, y: 350), options: [])
    ctx.restoreGState()
}

// Supersampling gives tiny sizes clean, consistent capsule edges.
let source = context(size: 2048)
source.scaleBy(x: 2, y: 2)
drawIcon(source)
let artwork = source.makeImage()!

func writePNG(size: Int, to url: URL) throws {
    let target = context(size: size)
    target.interpolationQuality = .high
    target.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, target.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "CadenceIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
    }
}

try writePNG(size: 1024, to: output.appendingPathComponent("Cadence-1024.png"))
for size in [16, 32, 128, 256, 512] {
    try writePNG(size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("Cadence.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "CadenceIcon", code: Int(iconutil.terminationStatus),
                  userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
print("Rendered master, AppIcon.iconset, and Cadence.icns in \(output.path)")
