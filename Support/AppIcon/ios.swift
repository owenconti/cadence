#!/usr/bin/env swift
// Run from the repo root: swift Support/AppIcon/ios.swift Support/AppIcon/Cadence-1024.png iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// iPhone icons must be opaque squares; iOS rounds the corners itself.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
// Crops the Mac icon to its 824-pt tile and lays it on opaque dark, for iOS.
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(colorSpace: space, components: [0x13/255, 0x13/255, 0x19/255, 1])!)
ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
let scale = 1024.0 / 824.0
ctx.draw(image, in: CGRect(x: -100 * scale, y: -100 * scale, width: 1024 * scale, height: 1024 * scale))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
