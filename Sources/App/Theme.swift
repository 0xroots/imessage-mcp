import AppKit

// Visual language: deep navy background, flat saturated accents, rounded shapes.
enum Theme {
 static let bgTop = NSColor(srgbRed: 0.027, green: 0.027, blue: 0.063, alpha: 1)
 static let bgBottom = NSColor(srgbRed: 0.090, green: 0.063, blue: 0.200, alpha: 1)
 static let warmGlow = NSColor(srgbRed: 0.36, green: 0.20, blue: 0.14, alpha: 0.55)
 static let card = NSColor(white: 1, alpha: 0.07)
 static let cardBorder = NSColor(white: 1, alpha: 0.10)
 static let text = NSColor(white: 1, alpha: 0.96)
 static let textDim = NSColor(white: 1, alpha: 0.68)
 static let purple = NSColor(srgbRed: 0.545, green: 0.486, blue: 0.965, alpha: 1)
 static let teal = NSColor(srgbRed: 0.122, green: 0.851, blue: 0.753, alpha: 1)
 static let yellow = NSColor(srgbRed: 1.000, green: 0.824, blue: 0.247, alpha: 1)
 static let blue = NSColor(srgbRed: 0.341, green: 0.690, blue: 1.000, alpha: 1)
 static let red = NSColor(srgbRed: 1.000, green: 0.373, blue: 0.396, alpha: 1)
 static let ink = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1)

 // Generous sizes: readable from 14 to 65+ without zooming.
 static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
  NSFont.systemFont(ofSize: size, weight: weight)
 }
}

// Full-window gradient with a warm glow and a faint grid, as in the reference.
final class BackdropView: NSView {
 override var isFlipped: Bool { true }
 override func draw(_ dirtyRect: NSRect) {
  guard let ctx = NSGraphicsContext.current?.cgContext else { return }
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let gradient = CGGradient(colorsSpace: space, colors: [Theme.bgTop.cgColor, Theme.bgBottom.cgColor] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
  let glow = CGGradient(colorsSpace: space, colors: [Theme.warmGlow.cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
  ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 120, y: 40), startRadius: 0, endCenter: CGPoint(x: 120, y: 40), endRadius: 360, options: [])
  ctx.setStrokeColor(NSColor(white: 1, alpha: 0.035).cgColor)
  ctx.setLineWidth(1)
  var x: CGFloat = 0
  while x < bounds.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height)); x += 44 }
  var y: CGFloat = 0
  while y < bounds.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y)); y += 44 }
  ctx.strokePath()
 }
}

final class CardView: NSView {
 init() {
  super.init(frame: .zero)
  wantsLayer = true
  layer?.cornerRadius = 16
  layer?.backgroundColor = Theme.card.cgColor
  layer?.borderColor = Theme.cardBorder.cgColor
  layer?.borderWidth = 1
  translatesAutoresizingMaskIntoConstraints = false
 }
 required init?(coder: NSCoder) { fatalError() }
}

// Large, high-contrast pill button. Never relies on color alone: it always has a label.
final class PillButton: NSButton {
 enum Style { case primary(NSColor), secondary, quiet }
 private let style: Style
 private var hovering = false

 init(title: String, symbol: String? = nil, style: Style, target: AnyObject?, action: Selector?) {
  self.style = style
  super.init(frame: .zero)
  self.target = target
  self.action = action
  isBordered = false
  wantsLayer = true
  layer?.cornerRadius = 12
  translatesAutoresizingMaskIntoConstraints = false
  setAccessibilityLabel(title)
  let color: NSColor
  switch style {
  case .primary: color = Theme.ink
  case .secondary, .quiet: color = Theme.text
  }
  attributedTitle = NSAttributedString(string: (symbol == nil ? "" : "  ") + title, attributes: [.font: Theme.font(15, .semibold), .foregroundColor: color])
  if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
   self.image = image.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
   imagePosition = .imageLeading
   contentTintColor = color
  }
  alignment = .center
  imageHugsTitle = true
  heightAnchor.constraint(equalToConstant: 44).isActive = true
  if case .quiet = style { alignment = .left } else { widthAnchor.constraint(greaterThanOrEqualToConstant: 168).isActive = true }
  addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  refresh()
 }
 required init?(coder: NSCoder) { fatalError() }
 override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
 override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
 override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
 override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + { if case .quiet = style { return 8 } else { return 40 } }(), height: 44) }
 private func refresh() {
  switch style {
  case .primary(let color):
   layer?.backgroundColor = (hovering ? color.blended(withFraction: 0.18, of: .white) ?? color : color).cgColor
   layer?.borderWidth = 0
  case .secondary:
   layer?.backgroundColor = NSColor(white: 1, alpha: hovering ? 0.16 : 0.09).cgColor
   layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
   layer?.borderWidth = 1
  case .quiet:
   layer?.backgroundColor = NSColor(white: 1, alpha: hovering ? 0.10 : 0).cgColor
   layer?.borderWidth = 0
  }
 }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.text, lines: Int = 0) -> NSTextField {
 let field = NSTextField(wrappingLabelWithString: text)
 field.font = Theme.font(size, weight)
 field.textColor = color
 field.maximumNumberOfLines = lines
 field.isSelectable = false
 field.translatesAutoresizingMaskIntoConstraints = false
 field.setContentHuggingPriority(.defaultLow, for: .horizontal)
 return field
}
