import AppKit

// Battery glyph: outline, level fill and terminal cap. `level` is 0...1.
func drawBattery(_ ctx: CGContext, in rect: CGRect, level: CGFloat, color: NSColor) {
 let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - 5, height: rect.height)
 ctx.setStrokeColor(NSColor.white.cgColor)
 ctx.setLineWidth(2.5)
 ctx.addPath(CGPath(roundedRect: body, cornerWidth: 6, cornerHeight: 6, transform: nil))
 ctx.strokePath()
 ctx.setFillColor(NSColor.white.cgColor)
 ctx.fill(CGRect(x: body.maxX + 1, y: rect.midY - 4, width: 4, height: 8))
 let clamped = max(0, min(1, level))
 let inner = body.insetBy(dx: 5, dy: 5)
 if clamped > 0 {
  ctx.setFillColor(color.cgColor)
  ctx.addPath(CGPath(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: max(8, inner.width * clamped), height: inner.height),
                     cornerWidth: 3, cornerHeight: 3, transform: nil))
  ctx.fillPath()
 }
}

// Row of flat characters, each with a battery above. Asleep when the bridge is off,
// awake and charged while it is on; the battery level tracks the remaining run time.
final class HeroIllustration: NSView {
 var awake = false { didSet { needsDisplay = true } }
 var level: CGFloat = 0.12 { didSet { needsDisplay = true } }

 override var isFlipped: Bool { false }
 // Drawn in a 178-pt-high design space and scaled to this height.
 private let designHeight: CGFloat = 178
 override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 120) }

 override func draw(_ dirtyRect: NSRect) {
  guard let ctx = NSGraphicsContext.current?.cgContext else { return }
  let people: [(body: NSColor, skin: NSColor, hair: NSColor)] = [
   (Theme.purple, NSColor(srgbRed: 0.55, green: 0.36, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.10, green: 0.07, blue: 0.06, alpha: 1)),
   (Theme.teal, NSColor(srgbRed: 0.98, green: 0.83, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.84, green: 0.60, blue: 0.30, alpha: 1)),
   (Theme.yellow, NSColor(srgbRed: 0.90, green: 0.68, blue: 0.50, alpha: 1), NSColor(srgbRed: 0.45, green: 0.28, blue: 0.20, alpha: 1)),
   (Theme.blue, NSColor(srgbRed: 0.36, green: 0.22, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.08, green: 0.06, blue: 0.05, alpha: 1)),
   (NSColor(srgbRed: 0.95, green: 0.50, blue: 0.62, alpha: 1), NSColor(srgbRed: 0.98, green: 0.83, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.20, green: 0.12, blue: 0.10, alpha: 1))
  ]
  let s = bounds.height / designHeight
  ctx.scaleBy(x: s, y: s)
  let width = bounds.width / s
  // Equal margins left and right: five slots centered in the full width.
  let slot = width / CGFloat(people.count)
  let deskTop: CGFloat = 30
  for (index, person) in people.enumerated() {
   let cx = slot * (CGFloat(index) + 0.5)
   let base = deskTop
   // Body (its lower part is hidden behind the desk)
   ctx.setFillColor(person.body.cgColor)
   ctx.addPath(CGPath(roundedRect: CGRect(x: cx - 36, y: base - 10, width: 72, height: 62), cornerWidth: 26, cornerHeight: 26, transform: nil))
   ctx.fillPath()
   // Head
   let head = CGRect(x: cx - 24, y: base + 38, width: 48, height: 48)
   ctx.setFillColor(person.skin.cgColor)
   ctx.fillEllipse(in: head)
   ctx.setFillColor(person.hair.cgColor)
   ctx.addPath(CGPath(roundedRect: CGRect(x: head.minX - 2, y: head.midY + 10, width: head.width + 4, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil))
   ctx.fillPath()
   // Face: closed eyes when asleep, open eyes and a smile when awake.
   ctx.setStrokeColor(NSColor(white: 0.12, alpha: 1).cgColor)
   ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
   ctx.setLineWidth(2.2)
   ctx.setLineCap(.round)
   for dx in [-9.0, 9.0] {
    if awake {
     ctx.fillEllipse(in: CGRect(x: head.midX + dx - 2.5, y: head.midY + 1, width: 5, height: 5))
    } else {
     ctx.move(to: CGPoint(x: head.midX + dx - 5, y: head.midY + 3))
     ctx.addQuadCurve(to: CGPoint(x: head.midX + dx + 5, y: head.midY + 3), control: CGPoint(x: head.midX + dx, y: head.midY - 2))
     ctx.strokePath()
    }
   }
   ctx.move(to: CGPoint(x: head.midX - 6, y: head.midY - 10))
   ctx.addQuadCurve(to: CGPoint(x: head.midX + 6, y: head.midY - 10), control: CGPoint(x: head.midX, y: head.midY - (awake ? 17 : 5)))
   ctx.strokePath()
   // Battery centered above the head
   let batteryColor: NSColor = awake ? Theme.teal : Theme.red
   let personLevel = awake ? level : 0.14 + 0.05 * CGFloat(index % 3)
   drawBattery(ctx, in: CGRect(x: cx - 28, y: base + 100, width: 56, height: 28), level: personLevel, color: batteryColor)
  }
  // Desk, inset to match the card padding
  ctx.setFillColor(NSColor(srgbRed: 0.29, green: 0.33, blue: 0.41, alpha: 1).cgColor)
  ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: deskTop), cornerWidth: 10, cornerHeight: 10, transform: nil))
  ctx.fillPath()
 }
}

// Standalone battery used for the remaining bridge time.
final class BatteryView: NSView {
 var level: CGFloat = 0 { didSet { needsDisplay = true } }
 var color: NSColor = Theme.teal { didSet { needsDisplay = true } }
 override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 30) }
 override func draw(_ dirtyRect: NSRect) {
  guard let ctx = NSGraphicsContext.current?.cgContext else { return }
  drawBattery(ctx, in: bounds.insetBy(dx: 2, dy: 2), level: level, color: color)
 }
}
