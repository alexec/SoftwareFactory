#!/usr/bin/env swift
// make-icon.swift: draws the Software Factory icon with Core Graphics. Nothing here is
// a recording or a download; every pixel is computed.
//
//   swift Tools/make-icon.swift
//
// Writes the full macOS icon set (16 to 512 at 1x and 2x, squircle drawn in, since
// macOS does not mask) into App/Resources/Assets.xcassets/AppIcon.appiconset, and one
// 1024 full-bleed square (iOS masks its own) into Phone/Resources/.../AppIcon.appiconset.
//
// The picture: a factory roofline, three sawtooth teeth and a chimney, cut in warm white
// out of a night-blue ground, with one lit window in the amber the app uses for
// "needs you". The roof reads at 16 px; the window is the detail that rewards 512.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent().deletingLastPathComponent()
let macSet = root.appending(path: "App/Resources/Assets.xcassets/AppIcon.appiconset")
let phoneSet = root.appending(path: "Phone/Resources/Assets.xcassets/AppIcon.appiconset")

func draw(size: Int, squircle: Bool) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Ground. macOS icons draw their own squircle; iOS masks a full square.
    let ground: CGPath
    if squircle {
        ground = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: s * 0.2237, cornerHeight: s * 0.2237, transform: nil)
    } else {
        ground = CGPath(rect: CGRect(x: 0, y: 0, width: s, height: s), transform: nil)
    }
    ctx.addPath(ground)
    ctx.clip()
    let night = [CGColor(red: 0.13, green: 0.17, blue: 0.27, alpha: 1), CGColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: night as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s * 0.3, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The building. Coordinates are fractions of the side; y goes up.
    let left = s * 0.16, right = s * 0.84, floor = s * 0.24, wall = s * 0.50
    let teeth = 3
    let toothWidth = (right - left) / CGFloat(teeth)
    let toothRise = s * 0.16
    let building = CGMutablePath()
    building.move(to: CGPoint(x: left, y: floor))
    building.addLine(to: CGPoint(x: left, y: wall))
    for t in 0..<teeth {
        let x0 = left + toothWidth * CGFloat(t)
        // Each tooth: a steep rise on the left, a long slope back down to the right.
        building.addLine(to: CGPoint(x: x0 + toothWidth * 0.18, y: wall + toothRise))
        building.addLine(to: CGPoint(x: x0 + toothWidth, y: wall))
    }
    building.addLine(to: CGPoint(x: right, y: floor))
    building.closeSubpath()

    // The chimney, standing on the first tooth.
    let chimney = CGRect(x: left + toothWidth * 0.30, y: wall + toothRise * 0.4, width: toothWidth * 0.22, height: s * 0.30)

    let warm = CGColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1)
    ctx.setFillColor(warm)
    ctx.addPath(building)
    ctx.fillPath()
    ctx.fill(chimney)

    // One lit window, amber, on the middle bay. Small enough to vanish at 16 px.
    if size >= 32 {
        let amber = CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        let w = CGRect(x: left + toothWidth * 1.36, y: floor + s * 0.08, width: toothWidth * 0.28, height: s * 0.11)
        ctx.setFillColor(amber)
        ctx.fill(w)
    }

    // A faint glow from the chimney at the large sizes, nothing at the small ones.
    if size >= 128 {
        let glow = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 0.35), CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        let top = CGPoint(x: chimney.midX, y: chimney.maxY + s * 0.02)
        ctx.drawRadialGradient(glow, startCenter: top, startRadius: 0, endCenter: top, endRadius: s * 0.16, options: [])
    }

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// macOS: every size the catalog wants, squircle drawn in.
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = "icon_\(points)x\(points)@\(scale)x.png"
    write(draw(size: px, squircle: true), to: macSet.appending(path: name))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
}
let macContents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: macContents, options: [.prettyPrinted, .sortedKeys]).write(to: macSet.appending(path: "Contents.json"))

// iOS: one full-bleed 1024.
write(draw(size: 1024, squircle: false), to: phoneSet.appending(path: "icon-1024.png"))
let phoneContents: [String: Any] = [
    "images": [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"]],
    "info": ["author": "xcode", "version": 1],
]
try! JSONSerialization.data(withJSONObject: phoneContents, options: [.prettyPrinted, .sortedKeys]).write(to: phoneSet.appending(path: "Contents.json"))

// A preview to look at on the Mac.
write(draw(size: 512, squircle: true), to: root.appending(path: "build/icon-preview.png"))
print("wrote \(images.count) mac sizes, one iOS 1024, and build/icon-preview.png")
