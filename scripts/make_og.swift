import AppKit

// Renders the 1200x630 social preview image. Usage: swift scripts/make_og.swift <icon.png> <out.png>
let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOfFile: args[1]) else { print("usage: make_og <icon.png> <out.png>"); exit(2) }
let w = 1200, h = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bg = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1), CGColor(srgbRed: 0.10, green: 0.07, blue: 0.23, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])
let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.36, green: 0.20, blue: 0.14, alpha: 0.6), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 140, y: 560), startRadius: 0, endCenter: CGPoint(x: 140, y: 560), endRadius: 520, options: [])
icon.draw(in: NSRect(x: 70, y: 150, width: 330, height: 330))
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint, width: CGFloat, height: CGFloat) {
 let style = NSMutableParagraphStyle(); style.lineSpacing = 4
 NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
  .draw(in: NSRect(x: p.x, y: p.y, width: width, height: height))
}
text("iMessage MCP", size: 40, weight: .semibold, color: NSColor(srgbRed: 0.12, green: 0.85, blue: 0.75, alpha: 1), at: NSPoint(x: 430, y: 470), width: 700, height: 50)
text("iMessage for AI tools,\nwithout Full Disk Access", size: 54, weight: .bold, color: .white, at: NSPoint(x: 430, y: 270), width: 740, height: 190)
text("Sandboxed · No network · You approve everything", size: 28, weight: .regular, color: NSColor(white: 1, alpha: 0.72), at: NSPoint(x: 430, y: 200), width: 740, height: 50)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
