import AppKit
import Foundation

// Numeric quotas are chosen locally every time the owner starts the bridge.
// Limits are never persisted and cancel leaves the bridge stopped.
// A field that selects its whole value when it gets focus, so typing replaces
// the number instead of being inserted into it.
final class SelectAllField: NSTextField {
 override func becomeFirstResponder() -> Bool {
  let accepted = super.becomeFirstResponder()
  if accepted { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
  return accepted
 }
}

enum BridgeLimitsChooser {
 static func prompt() -> SessionAuthority.Limits? {
  let alert = NSAlert()
  alert.messageText = "Configure AI bridge limits"
  alert.informativeText = "Starting the bridge does not grant client access; each connection still needs your approval. After approval, retrieved message content may be sent to cloud-hosted AI. Limits apply across every connection until you stop the bridge. Reconnecting does not reset them.\n\nEach message query reserves its maximum result slots, even when fewer or no rows match. Attachment metadata reserves one slot. This caps returned message volume; SQLite may inspect additional rows internally while searching. Response size is measured on the backend's JSON before the adapter wraps it in MCP.\n\n\"Start without limits\" lifts the quotas (100 results per call and a 120 KiB reply stay as technical ceilings). Every connection still needs your approval."
  alert.addButton(withTitle: "Start with these limits")
  alert.addButton(withTitle: "Cancel")
  alert.addButton(withTitle: "Start without limits")

  let defaults = SessionAuthority.Limits.defaults
  let rows: [(String, String)] = [
   ("Messages per request (1–100)", String(defaults.maxMessagesPerRequest)),
   ("Message slots per bridge run (1–500)", String(defaults.maxMessagesPerSession)),
   ("Requests per minute (1–60)", String(defaults.requestsPerMinute)),
   ("Duration in minutes (1–60)", String(defaults.durationSeconds / 60)),
   ("Backend JSON response limit in KiB (1–120)", String(defaults.maxResponseBytes / 1_024))
  ]
  let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 212))
  var fields: [NSTextField] = []
  for (index, row) in rows.enumerated() {
   let y = 180 - index * 32
   let label = NSTextField(labelWithString: row.0)
   label.frame = NSRect(x: 0, y: y, width: 348, height: 24)
   accessory.addSubview(label)
   let field = SelectAllField(string: row.1)
   field.alignment = .right
   field.frame = NSRect(x: 354, y: y, width: 96, height: 24)
   accessory.addSubview(field)
   fields.append(field)
  }
  // Attachments are a separate, explicit choice: they can contain far more than text.
  let attachmentsBox = NSButton(checkboxWithTitle: "Allow reading photos and PDFs from allowed chats (up to 40 MB per run)", target: nil, action: nil)
  attachmentsBox.frame = NSRect(x: 0, y: 6, width: 460, height: 24)
  attachmentsBox.state = .on  // on by default; the owner can switch it off here or later in the main window
  accessory.addSubview(attachmentsBox)
  alert.accessoryView = accessory
  let attachmentBytes = 40 * 1_024 * 1_024

  switch alert.runModal() {
  case .alertFirstButtonReturn: break
  case .alertThirdButtonReturn:
   var unlimited = SessionAuthority.Limits.unlimited
   if attachmentsBox.state == .on { unlimited.attachmentBytes = 4 * attachmentBytes }
   return unlimited
  default: return nil
  }
  let values = fields.compactMap { Int($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
  guard values.count == 5 else {
   showInvalidLimits()
   return nil
  }
  // Out-of-range numbers are brought to the nearest allowed value instead of being refused.
  func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
  guard var limits = SessionAuthority.Limits(maxMessagesPerRequest: clamp(values[0], 1...SessionAuthority.Limits.hardMaxMessagesPerRequest),
                                             maxMessagesPerSession: clamp(values[1], 1...SessionAuthority.Limits.hardMaxMessagesPerSession),
                                             requestsPerMinute: clamp(values[2], 1...SessionAuthority.Limits.hardMaxRequestsPerMinute),
                                             durationSeconds: clamp(values[3], 1...60) * 60,
                                             maxResponseBytes: clamp(values[4], 1...120) * 1_024) else {
   showInvalidLimits()
   return nil
  }
  if attachmentsBox.state == .on { limits.attachmentBytes = attachmentBytes }
  return limits
 }

 private static func showInvalidLimits() {
  let alert = NSAlert()
  alert.messageText = "Limits are outside the allowed range"
  alert.informativeText = "The bridge remains stopped. Enter whole numbers and try again."
  alert.addButton(withTitle: "OK")
  alert.runModal()
 }
}
