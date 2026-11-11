// Renders Resources/AppIcon.png (1024x1024) from Resources/ClippyIcon.png on
// the macOS icon grid: an 824 pt rounded tile, art cropped to its opaque
// pixels and scaled to fill it. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let src = NSImage(contentsOf: root.appendingPathComponent("Resources/ClippyIcon.png"))!
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!

// Bounding box of pixels with alpha > 8 (top-left origin).
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let rgba = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rgba.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
var (minX, minY, maxX, maxY) = (w, h, 0, 0)
for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let art = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(path); ctx.setFillColor(.white); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
    CGColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1),
    CGColor(red: 0.12, green: 0.33, blue: 0.66, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Art fills ~86% of the tile, centred.
let box = tile.insetBy(dx: 824 * 0.07, dy: 824 * 0.07)
let scale = min(box.width / CGFloat(art.width), box.height / CGFloat(art.height))
let drawn = CGSize(width: CGFloat(art.width) * scale, height: CGFloat(art.height) * scale)
ctx.interpolationQuality = .high
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
ctx.draw(art, in: CGRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
ctx.restoreGState()

let out = root.appendingPathComponent("Resources/AppIcon.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
