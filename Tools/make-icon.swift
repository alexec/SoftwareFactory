#!/usr/bin/env swift
// make-icon.swift: draws the Taktu icon with Core Graphics. Nothing here is a recording
// or a download; every pixel is computed.
//
//   swift Tools/make-icon.swift
//
// Writes the full macOS icon set (16 to 512 at 1x and 2x, squircle drawn in, since
// macOS does not mask) into App/Resources/Assets.xcassets/AppIcon.appiconset, and one
// 1024 full-bleed square (iOS masks its own) into Phone/Resources/.../AppIcon.appiconset.
//
// The mark is four evenly spaced vertical strokes. The taller amber third stroke makes
// the icon recognisable at small sizes; the other three are warm white on a near-black
// tile. The concept also includes light and tinted examples, but app-icon catalogs use
// the dark tile consistently across the required raster sizes.

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
    ctx.setFillColor(CGColor(red: 0.11, green: 0.105, blue: 0.098, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    let warm = CGColor(red: 0.945, green: 0.937, blue: 0.91, alpha: 1)
    let amber = CGColor(red: 0.937, green: 0.624, blue: 0.153, alpha: 1)
    let width = s * 0.08
    let shortHeight = s * 0.38
    let tallHeight = s * 0.58
    let centers = [0.215, 0.405, 0.595, 0.785].map { s * $0 }

    for (index, center) in centers.enumerated() {
        let height = index == 2 ? tallHeight : shortHeight
        let rect = CGRect(x: center - width / 2, y: (s - height) / 2, width: width, height: height)
        ctx.setFillColor(index == 2 ? amber : warm)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
        ctx.fillPath()
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
