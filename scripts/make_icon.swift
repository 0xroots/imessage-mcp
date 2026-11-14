import AppKit

// Draws the app icon: dark rounded square, teal speech bubble, purple/yellow dots, battery.
// Usage: swift scripts/make_icon.swift <output.iconset>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
 let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
 let ctx = NSGraphicsContext.current!.cgContext
 let s = CGFloat(px) / 1024
 ctx.scaleBy(x: s, y: s)
 let space = CGColorSpace(name: CGColorSpace.sRGB)!
 // Squircle background (macOS icon grid: 824 px inside 1024).
 let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
 ctx.saveGState()
 ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
 ctx.clip()
 let bg = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.09, green: 0.06, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.03, green: 0.03, blue: 0.07, alpha: 1)] as CFArray, locations: [0, 1])!
 ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
 let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.36, green: 0.20, blue: 0.14, alpha: 0.6), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)] as CFArray, locations: [0, 1])!
 ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 250, y: 820), startRadius: 0, endCenter: CGPoint(x: 250, y: 820), endRadius: 520, options: [])
 ctx.restoreGState()
 // Speech bubble
 let bubble = CGRect(x: 232, y: 330, width: 560, height: 400)
 ctx.setFillColor(CGColor(srgbRed: 0.122, green: 0.851, blue: 0.753, alpha: 1))
 ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 130, cornerHeight: 130, transform: nil))
 ctx.fillPath()
 ctx.move(to: CGPoint(x: 330, y: 345)); ctx.addLine(to: CGPoint(x: 290, y: 235)); ctx.addLine(to: CGPoint(x: 450, y: 335)); ctx.closePath(); ctx.fillPath()
 // Three dots in the bubble
 let dotColors = [CGColor(srgbRed: 0.545, green: 0.486, blue: 0.965, alpha: 1), CGColor(srgbRed: 1, green: 0.824, blue: 0.247, alpha: 1), CGColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1)]
 for (i, c) in dotColors.enumerated() {
  ctx.setFillColor(c)
  ctx.fillEllipse(in: CGRect(x: 360 + CGFloat(i) * 120, y: 490, width: 72, height: 72))
 }
 // Small battery badge (bottom right)
 let badge = CGRect(x: 600, y: 190, width: 200, height: 100)
 ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1))
 ctx.addPath(CGPath(roundedRect: badge.insetBy(dx: -26, dy: -22), cornerWidth: 44, cornerHeight: 44, transform: nil)); ctx.fillPath()
 ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(12)
 ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.strokePath()
 ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: badge.maxX + 6, y: badge.midY - 20, width: 14, height: 40))
 ctx.setFillColor(CGColor(srgbRed: 1, green: 0.824, blue: 0.247, alpha: 1))
 ctx.addPath(CGPath(roundedRect: badge.insetBy(dx: 20, dy: 20).applying(CGAffineTransform(scaleX: 1, y: 1)), cornerWidth: 10, cornerHeight: 10, transform: nil))
 ctx.fillPath()
 NSGraphicsContext.restoreGraphicsState()
 return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png")) }
print("wrote \(out)")
