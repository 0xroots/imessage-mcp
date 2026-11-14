import AppKit
import Foundation
import Darwin

// iMessage MCP: keeps your Messages on this Mac and lets you lend them to a local
// MCP client for a short, limited, owner-approved run. No network access is requested.

guard let pw = getpwuid(getuid()), let userHome = pw.pointee.pw_dir else { exit(1) }
let messagesFolder = URL(fileURLWithPath: String(cString: userHome))
 .appendingPathComponent("Library/Messages", isDirectory: true).standardizedFileURL
let bookmarkKey = "messageslocal.folder-bookmark.v1"

final class AppDelegate: NSObject, NSApplicationDelegate, NSOpenSavePanelDelegate {
 var window: NSWindow!
 var hero: HeroIllustration!
 var headline: NSTextField!
 var subline: NSTextField!
 var battery: BatteryView!
 var batteryText: NSTextField!
 var folderChip: NSTextField!
 var folderButton: PillButton!
 var bridgeButton: PillButton!
 var bridgeNote: NSTextField!
 var browserButton: PillButton!
 var advancedBox: NSStackView!
 var advancedToggle: PillButton!
 var browser: LocalBrowserWindow?
 var ipcServer: LocalIPCServer?
 var ipcFolder: URL?
 var ipcLimits: SessionAuthority.Limits?
 var bridgeStarted: Date?
 var ticker: Timer?
 var bookmarkStatus = "not_checked"
 var folderReady = false
 var clientName: String?
 var clientRow: NSTextField!
 var statusBox: NSStackView!
 var statusItem: NSStatusItem?
 var coach: NSPanel?
 var previewOn = false   // design snapshots only (MSGLOCAL_SNAPSHOT)

 // MARK: Layout

 func applicationDidFinishLaunching(_ notification: Notification) {
  NSApp.appearance = NSAppearance(named: .darkAqua)
  NSApp.applicationIconImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage

  window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered, defer: false)
  window.title = "iMessage MCP"
  window.titlebarAppearsTransparent = true
  window.titleVisibility = .hidden
  window.isMovableByWindowBackground = true
  window.isReleasedWhenClosed = false
  window.minSize = NSSize(width: 560, height: 420)

  let backdrop = BackdropView(frame: window.contentView!.bounds)
  backdrop.autoresizingMask = [.width, .height]
  window.contentView = backdrop

  // Content scrolls when the screen is short, so nothing is ever cut off.
  let scroll = NSScrollView(frame: backdrop.bounds)
  scroll.autoresizingMask = [.width, .height]
  scroll.drawsBackground = false
  scroll.hasVerticalScroller = true
  scroll.autohidesScrollers = true
  scroll.scrollerStyle = .overlay
  let doc = FlippedView()
  doc.translatesAutoresizingMaskIntoConstraints = false
  scroll.documentView = doc
  backdrop.addSubview(scroll)
  doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

  // 8-pt grid: 24 outer margin, 20 card padding, 16 between cards, 8 inside text groups.
  let title = label("iMessage MCP", size: 26, weight: .bold, lines: 1)
  let tagline = label("Your messages stay on this Mac. Share them with AI only when you choose.",
                      size: 14, color: Theme.textDim)
  let header = NSStackView(views: [title, tagline])
  header.orientation = .vertical
  header.alignment = .leading
  header.spacing = 4

  hero = HeroIllustration()
  hero.translatesAutoresizingMaskIntoConstraints = false
  headline = label("Local only", size: 22, weight: .bold, lines: 1)
  subline = label("", size: 14, color: Theme.textDim, lines: 2)
  battery = BatteryView()
  battery.translatesAutoresizingMaskIntoConstraints = false
  batteryText = label("", size: 14, weight: .semibold, color: Theme.text, lines: 1)
  batteryText.setAccessibilityLabel("Bridge time remaining")
  clientRow = label("", size: 14, weight: .semibold, color: Theme.teal, lines: 1)

  let batteryRow = NSStackView(views: [battery, batteryText])
  batteryRow.orientation = .horizontal
  batteryRow.spacing = 8
  batteryRow.alignment = .centerY
  let statusLeft = NSStackView(views: [headline, subline])
  statusLeft.orientation = .vertical
  statusLeft.alignment = .leading
  statusLeft.spacing = 4
  let statusRight = NSStackView(views: [batteryRow, clientRow])
  statusRight.orientation = .vertical
  statusRight.alignment = .trailing
  statusRight.spacing = 4
  statusRight.setContentHuggingPriority(.required, for: .horizontal)
  statusRight.setContentCompressionResistancePriority(.required, for: .horizontal)
  statusBox = statusRight
  let statusRow = NSStackView(views: [statusLeft, statusRight])
  statusRow.orientation = .horizontal
  statusRow.alignment = .centerY
  statusRow.spacing = 16

  let heroCard = CardView()
  let heroStack = NSStackView(views: [hero, statusRow])
  heroStack.orientation = .vertical
  heroStack.alignment = .leading
  heroStack.spacing = 12
  heroStack.translatesAutoresizingMaskIntoConstraints = false
  heroCard.addSubview(heroStack)
  NSLayoutConstraint.activate([
   heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 20),
   heroStack.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -20),
   heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 16),
   heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -16),
   hero.widthAnchor.constraint(equalTo: heroStack.widthAnchor),
   statusRow.widthAnchor.constraint(equalTo: heroStack.widthAnchor)
  ])

  // Step 1: folder access
  folderChip = label("", size: 13, weight: .semibold, color: Theme.yellow, lines: 1)
  folderButton = PillButton(title: "Allow Messages folder", symbol: "folder.badge.plus", style: .primary(Theme.yellow), target: self, action: #selector(selectFolder))
  let step1 = stepCard(accent: Theme.yellow, number: "1", title: "Give read-only access to Messages",
                       body: "Pick your Messages folder once. The app can only read it, never change it.",
                       extra: nil, trailing: folderChip, button: folderButton)

  // Step 2: bridge
  bridgeNote = label("", size: 13, color: Theme.textDim, lines: 1)
  bridgeButton = PillButton(title: "Start AI bridge", symbol: "bolt.fill", style: .primary(Theme.teal), target: self, action: #selector(toggleBridge))
  let step2 = stepCard(accent: Theme.teal, number: "2", title: "Start the AI bridge when you need it",
                       body: "You set the limits and approve every connection. Close this window and the bridge keeps running in the menu bar.",
                       extra: bridgeNote, trailing: nil, button: bridgeButton)

  // Step 3: local browsing (compact: text left, button right)
  browserButton = PillButton(title: "Browse", symbol: "text.bubble", style: .secondary, target: self, action: #selector(openLocalBrowser))
  let step3 = stepRow(accent: Theme.purple, number: "3", title: "Or just read them yourself",
                      body: "Search and read them here. No AI.", button: browserButton)

  // Advanced
  advancedToggle = PillButton(title: "Advanced", symbol: "chevron.down", style: .quiet, target: self, action: #selector(toggleAdvanced))
  let removeButton = PillButton(title: "Remove folder access", symbol: "trash", style: .secondary, target: self, action: #selector(removeBookmark))
  let aboutButton = PillButton(title: "Privacy and security", symbol: "lock.shield", style: .secondary, target: self, action: #selector(showPrivacy))
  advancedBox = NSStackView(views: [removeButton, aboutButton])
  advancedBox.orientation = .horizontal
  advancedBox.spacing = 12
  advancedBox.isHidden = true
  let footer = NSStackView(views: [advancedToggle, advancedBox])
  footer.orientation = .vertical
  footer.alignment = .leading
  footer.spacing = 8

  let root = NSStackView(views: [header, heroCard, step1, step2, step3, footer])
  root.orientation = .vertical
  root.alignment = .leading
  root.spacing = 16
  root.setCustomSpacing(16, after: header)
  root.translatesAutoresizingMaskIntoConstraints = false
  doc.addSubview(root)
  NSLayoutConstraint.activate([
   root.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
   root.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
   root.topAnchor.constraint(equalTo: doc.topAnchor, constant: 36),
   root.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
   header.widthAnchor.constraint(equalTo: root.widthAnchor),
   heroCard.widthAnchor.constraint(equalTo: root.widthAnchor),
   step1.widthAnchor.constraint(equalTo: root.widthAnchor),
   step2.widthAnchor.constraint(equalTo: root.widthAnchor),
   step3.widthAnchor.constraint(equalTo: root.widthAnchor),
   tagline.widthAnchor.constraint(equalTo: header.widthAnchor)
  ])

  // Fit the window to the content, but never taller than the screen in use.
  doc.layoutSubtreeIfNeeded()
  let launchScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
  if let frame = launchScreen?.visibleFrame {
   let height = min(doc.fittingSize.height, frame.height - 20)
   window.setContentSize(NSSize(width: 600, height: height))
   window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
  }
  setupStatusItem()

  refreshFolderState()
  render()
  if let path = ProcessInfo.processInfo.environment["MSGLOCAL_SNAPSHOT"] { snapshot(doc: doc, to: path); exit(0) }
  window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps: true)
 }

 // Numbered badge in the step color; the number is text, so color is never the only cue.
 func badge(_ number: String, _ color: NSColor) -> NSView {
  let v = NSView()
  v.wantsLayer = true
  v.layer?.backgroundColor = color.cgColor
  v.layer?.cornerRadius = 14
  v.translatesAutoresizingMaskIntoConstraints = false
  let t = label(number, size: 15, weight: .bold, color: Theme.ink, lines: 1)
  t.alignment = .center
  v.addSubview(t)
  NSLayoutConstraint.activate([
   v.widthAnchor.constraint(equalToConstant: 28), v.heightAnchor.constraint(equalToConstant: 28),
   t.centerXAnchor.constraint(equalTo: v.centerXAnchor), t.centerYAnchor.constraint(equalTo: v.centerYAnchor)
  ])
  return v
 }

 // Badge + title on one line, then body, extra and button aligned to the title.
 func stepCard(accent: NSColor, number: String, title: String, body: String, extra: NSTextField?, trailing: NSTextField? = nil, button: PillButton) -> CardView {
  let card = CardView()
  let heading = label(title, size: 17, weight: .semibold, lines: 1)
  var headViews: [NSView] = [badge(number, accent), heading]
  if let trailing {
   let spacer = NSView()
   spacer.setContentHuggingPriority(.init(1), for: .horizontal)
   headViews += [spacer, trailing]
  }
  let head = NSStackView(views: headViews)
  head.orientation = .horizontal
  head.alignment = .centerY
  head.spacing = 12
  let text = label(body, size: 14, color: Theme.textDim)
  var views: [NSView] = [head, text]
  if let extra { views.append(extra) }
  views.append(button)
  let stack = NSStackView(views: views)
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 8
  stack.setCustomSpacing(16, after: views[views.count - 2])
  stack.translatesAutoresizingMaskIntoConstraints = false
  card.addSubview(stack)
  NSLayoutConstraint.activate([
   stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
   stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
   stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
   stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
   text.widthAnchor.constraint(equalTo: stack.widthAnchor),
   head.widthAnchor.constraint(equalTo: stack.widthAnchor)
  ])
  return card
 }

 func stepRow(accent: NSColor, number: String, title: String, body: String, button: PillButton) -> CardView {
  let card = CardView()
  let heading = label(title, size: 17, weight: .semibold, lines: 1)
  let text = label(body, size: 14, color: Theme.textDim, lines: 2)
  let col = NSStackView(views: [heading, text])
  col.orientation = .vertical
  col.alignment = .leading
  col.spacing = 4
  let spacer = NSView()
  spacer.setContentHuggingPriority(.init(1), for: .horizontal)
  let row = NSStackView(views: [badge(number, accent), col, spacer, button])
  row.orientation = .horizontal
  row.alignment = .centerY
  row.spacing = 12
  row.translatesAutoresizingMaskIntoConstraints = false
  col.setContentHuggingPriority(.defaultLow, for: .horizontal)
  button.setContentHuggingPriority(.required, for: .horizontal)
  card.addSubview(row)
  NSLayoutConstraint.activate([
   row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
   row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
   row.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
   row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20)
  ])
  return card
 }

 // Developer aid: renders the window content to PNG files (off and on states).
 func snapshot(doc: NSView, to path: String) {
  func write(_ name: String) {
   window.contentView?.layoutSubtreeIfNeeded()
   guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
   view.cacheDisplay(in: view.bounds, to: rep)
   try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
  }
  write(path)
  previewOn = true; clientName = "claude"; render()
  write(path.replacingOccurrences(of: ".png", with: "-on.png"))
 }

 // MARK: Menu bar (the bridge keeps running while the window is closed)

 static func friendly(_ raw: String) -> String {
  let lower = raw.lowercased()
  if lower.contains("claude") { return "Claude" }
  if lower.contains("codex") { return "Codex" }
  if lower == "node" { return "AI tool (node)" }
  return raw
 }

 func setupStatusItem() {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  statusItem = item
  updateStatusItem()
 }

 func updateStatusItem() {
  guard let item = statusItem else { return }
  let on = ipcServer != nil
  item.button?.image = NSImage(systemSymbolName: on ? "bolt.circle.fill" : "message.circle", accessibilityDescription: "iMessage MCP")
  item.button?.toolTip = on ? "iMessage MCP: AI bridge is on" : "iMessage MCP: local only"
  let menu = NSMenu()
  menu.addItem(withTitle: on ? "AI bridge is on" : "Local only", action: nil, keyEquivalent: "").isEnabled = false
  if on { menu.addItem(withTitle: clientName.map { "Connected: \(Self.friendly($0))" } ?? "Waiting for Claude or Codex", action: nil, keyEquivalent: "").isEnabled = false }
  menu.addItem(.separator())
  menu.addItem(withTitle: "Show window", action: #selector(showWindow), keyEquivalent: "").target = self
  if on { menu.addItem(withTitle: "Stop AI bridge", action: #selector(toggleBridge), keyEquivalent: "").target = self }
  menu.addItem(.separator())
  menu.addItem(withTitle: "Quit iMessage MCP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  item.menu = menu
 }

 @objc func showWindow() {
  window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps: true)
 }

 func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
  if !flag { showWindow() }
  return true
 }

 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  guard ipcServer != nil else { return .terminateNow }
  let alert = NSAlert()
  alert.messageText = "Quit and stop the AI bridge?"
  alert.informativeText = "Connected AI tools will lose access. Closing the window instead keeps the bridge running."
  alert.addButton(withTitle: "Keep running")
  alert.addButton(withTitle: "Quit")
  return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
 }

 // MARK: State

 func render() {
  let on = ipcServer != nil || previewOn
  hero.awake = on
  headline.stringValue = on ? "AI bridge is on" : "Local only"
  subline.stringValue = on
   ? "Nothing is shared until you approve each connection."
   : "Nothing leaves your Mac. The AI bridge is off."
  bridgeButton.attributedTitle = NSAttributedString(string: on ? "  Stop AI bridge" : "  Start AI bridge",
   attributes: [.font: Theme.font(15, .semibold), .foregroundColor: Theme.ink])
  bridgeButton.image = NSImage(systemSymbolName: on ? "stop.fill" : "bolt.fill", accessibilityDescription: nil)?
   .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
  bridgeButton.isEnabled = folderReady || on
  browserButton.isEnabled = folderReady
  bridgeNote.stringValue = folderReady ? "" : "Step 1 first: allow the Messages folder."
  bridgeNote.isHidden = folderReady
  statusBox.isHidden = !on
  clientRow.stringValue = clientName.map { "Connected: \(Self.friendly($0))" } ?? "Waiting for Claude or Codex"
  clientRow.textColor = clientName == nil ? Theme.textDim : Theme.teal
  tick()
  updateStatusItem()
 }

 func tick() {
  if previewOn { battery.level = 0.62; hero.level = 0.62; batteryText.stringValue = "9:18 left"; return }
  guard let limits = ipcLimits, let started = bridgeStarted, ipcServer != nil else {
   hero.level = 0.12
   return
  }
  let total = Double(limits.durationSeconds)
  let remaining = max(0, total - Date().timeIntervalSince(started))
  let fraction = CGFloat(remaining / total)
  battery.level = fraction
  battery.color = fraction > 0.25 ? Theme.teal : Theme.red
  hero.level = fraction
  let minutes = Int(remaining / 60), seconds = Int(remaining) % 60
  batteryText.stringValue = String(format: "%d:%02d left", minutes, seconds)
 }

 func refreshFolderState() {
  if let (url, active) = resolve(), active {
   url.stopAccessingSecurityScopedResource()
   folderReady = true
   folderChip.stringValue = "Allowed"
   folderChip.textColor = Theme.teal
   folderButton.attributedTitle = NSAttributedString(string: "  Choose the folder again", attributes: [.font: Theme.font(15, .semibold), .foregroundColor: Theme.text])
  } else {
   folderReady = false
   folderChip.stringValue = "Not allowed yet"
   folderChip.textColor = Theme.yellow
  }
 }

 func message(_ title: String, _ detail: String) {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = detail
  alert.addButton(withTitle: "OK")
  alert.runModal()
 }

 // MARK: Folder access (read-only, app-scoped bookmark)

 func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
  let path = url.standardizedFileURL.path, target = messagesFolder.path
  return path == target || target.hasPrefix(path == "/" ? "/" : path + "/")
 }
 func panel(_ sender: Any, validate url: URL) throws {
  guard url.standardizedFileURL.path == messagesFolder.path else { throw NSError(domain: "MessagesFolderOnly", code: 1) }
 }

 @objc func selectFolder() {
  let panel = NSOpenPanel()
  panel.delegate = self
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.canCreateDirectories = false
  panel.showsHiddenFiles = true
  panel.directoryURL = messagesFolder.deletingLastPathComponent()
  panel.prompt = "Allow"
  panel.message = "Select your Messages folder. iMessage MCP gets read-only access."
  showCoach(over: panel)
  defer { coach?.orderOut(nil); coach = nil }
  guard panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL.path == messagesFolder.path else { return }
  let active = url.startAccessingSecurityScopedResource()
  defer { if active { url.stopAccessingSecurityScopedResource() } }
  do {
   let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
   UserDefaults.standard.set(data, forKey: bookmarkKey)
  } catch {
   message("Could not save access", "macOS refused to create the folder bookmark. Try again.")
  }
  refreshFolderState()
  render()
 }


 // Banner floating above the folder picker, so the right folder is obvious.
 func showCoach(over panel: NSOpenPanel) {
  let text = label("Click “Messages”, then press Allow", size: 17, weight: .bold, color: Theme.ink, lines: 1)
  text.translatesAutoresizingMaskIntoConstraints = false
  let pill = NSView()
  pill.wantsLayer = true
  pill.layer?.backgroundColor = Theme.yellow.cgColor
  pill.layer?.cornerRadius = 16
  pill.addSubview(text)
  NSLayoutConstraint.activate([
   text.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
   text.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 18),
   text.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -18)
  ])
  let banner = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  banner.isOpaque = false
  banner.backgroundColor = .clear
  banner.hasShadow = true
  banner.level = .modalPanel
  banner.ignoresMouseEvents = true
  pill.frame = NSRect(origin: .zero, size: banner.frame.size)
  pill.autoresizingMask = [.width, .height]
  banner.contentView = pill
  coach = banner
  // The picker is shown modally; position the banner once its frame exists.
  let timer = Timer(timeInterval: 0.1, repeats: true) { [weak banner, weak panel] t in
   guard let banner, let panel, panel.isVisible else { return }
   let f = panel.frame
   banner.setFrameOrigin(NSPoint(x: f.midX - banner.frame.width / 2, y: f.maxY + 10))
   banner.orderFront(nil)
   t.invalidate()
  }
  RunLoop.main.add(timer, forMode: .common)
 }

 func resolve() -> (URL, Bool)? {
  guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { bookmarkStatus = "bookmark_missing"; return nil }
  do {
   var stale = false
   let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
   guard url.standardizedFileURL.path == messagesFolder.path else { bookmarkStatus = "folder_mismatch"; return nil }
   guard url.startAccessingSecurityScopedResource() else { bookmarkStatus = stale ? "stale_scope_denied" : "scope_denied"; return nil }
   if stale {
    do {
     let refreshed = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
     UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
    } catch {
     url.stopAccessingSecurityScopedResource()
     bookmarkStatus = "refresh_failed"
     return nil
    }
   }
   bookmarkStatus = stale ? "refreshed" : "restored"
   return (url, true)
  } catch {
   bookmarkStatus = "resolve_failed"
   return nil
  }
 }

 @objc func removeBookmark() {
  stopBridge()
  browser?.window?.close(); browser = nil
  UserDefaults.standard.removeObject(forKey: bookmarkKey)
  refreshFolderState()
  render()
 }

 @objc func toggleAdvanced() {
  advancedBox.isHidden.toggle()
  advancedToggle.image = NSImage(systemSymbolName: advancedBox.isHidden ? "chevron.down" : "chevron.up", accessibilityDescription: nil)?
   .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
 }

 @objc func showPrivacy() {
  message("Privacy and security",
   "The app runs in the macOS sandbox with read-only access to the Messages folder you pick and no network access.\n\nThe AI bridge is a local socket. Every connection needs your approval, usage is capped by the limits you set, and it stops when time runs out or you press Stop.\n\nSending a message always shows the exact recipient and text and waits for your click. A sent message cannot be recalled.")
 }

 @objc func openLocalBrowser() {
  if let existing = browser?.window, existing.isVisible { existing.makeKeyAndOrderFront(nil); return }
  guard let (url, active) = resolve(), active else { refreshFolderState(); render(); return }
  let controller = LocalBrowserWindow(folder: url)
  browser = controller
  controller.show()
 }

 // MARK: AI bridge

 @objc func toggleBridge() {
  if ipcServer != nil { stopBridge(); return }
  guard let (url, active) = resolve(), active else { refreshFolderState(); render(); return }
  guard let limits = BridgeLimitsChooser.prompt() else { url.stopAccessingSecurityScopedResource(); return }
  let server = LocalIPCServer(folder: url, filename: "chat.db", limits: limits,
   onRunExpired: { [weak self] in self?.bridgeExpired() },
   onClient: { [weak self] name in self?.clientName = name; self?.render() },
   confirmSend: { [weak self] recipient, text, alive in self?.confirmOneMessage(recipient: recipient, text: text, stillConnected: alive) ?? false },
   sendText: { recipient, text, canDispatch in
    let result = MessagesAppleEventSender().send(phoneE164: recipient, text: text, canDispatch: canDispatch)
    // Reason is an enum name only; it never contains the recipient or the text.
    let why = result.reason.map { ":\($0.rawValue)" } ?? ""
    switch result.outcome {
    case .notAttempted: return "not_attempted" + why
    case .acceptedByMessages: return "submitted"
    case .indeterminate: return "unknown" + why
    }
   }) { [weak self] alive in self?.approveBridgeConnection(stillConnected: alive) }
  guard server.start() else {
   url.stopAccessingSecurityScopedResource()
   message("The bridge did not start", "A previous connection may still be closing. Wait a moment and try again.")
   return
  }
  ipcFolder = url; ipcLimits = limits; ipcServer = server; bridgeStarted = Date()
  ticker?.invalidate()
  ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
  render()
 }

 func stopBridge() {
  ipcServer?.stop(); ipcServer = nil
  ipcFolder?.stopAccessingSecurityScopedResource(); ipcFolder = nil
  ipcLimits = nil; bridgeStarted = nil; clientName = nil
  ticker?.invalidate(); ticker = nil
  if window != nil { render() }
 }

 func bridgeExpired() {
  guard ipcServer != nil else { return }
  ipcServer = nil
  ipcFolder?.stopAccessingSecurityScopedResource(); ipcFolder = nil
  ipcLimits = nil; bridgeStarted = nil; clientName = nil
  ticker?.invalidate(); ticker = nil
  render()
 }

 func bridgeLimitsDescription() -> String {
  guard let limits = ipcLimits else { return "Shared bridge quotas apply." }
  return "Run caps: \(limits.maxMessagesPerRequest) message slots per request, \(limits.maxMessagesPerSession) per run, \(limits.requestsPerMinute) requests/minute, \(limits.durationSeconds / 60) minutes, and \(limits.maxResponseBytes / 1_024) KiB backend JSON."
 }

 // The timer runs in modal mode too: a dialog closes by itself if its connection ends,
 // so a stale click can never grant access or send a message.
 func runConnectionAlert(_ alert: NSAlert, stillConnected: @escaping () -> Bool) -> NSApplication.ModalResponse {
  guard stillConnected() else { return .abort }
  alert.icon = NSApp.applicationIconImage
  // Place the dialog on the screen the owner is using (where the pointer is),
  // never on another monitor.
  let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
  if let frame = screen?.visibleFrame {
   let size = alert.window.frame.size
   alert.window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
  }
  let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
   if !stillConnected(), NSApp.modalWindow === alert.window { NSApp.stopModal(withCode: .abort) }
  }
  RunLoop.main.add(timer, forMode: .common)
  defer { timer.invalidate() }
  NSApp.activate(ignoringOtherApps: true)
  alert.window.level = .floating
  alert.window.collectionBehavior.insert(.canJoinAllSpaces)
  alert.window.collectionBehavior.insert(.fullScreenAuxiliary)
  alert.window.orderFrontRegardless()
  return alert.runModal()
 }

 // Every outbound message needs its own confirmation with the full text visible.
 func confirmOneMessage(recipient: String, text: String, stillConnected: @escaping () -> Bool) -> Bool {
  guard stillConnected() else { return false }
  let alert = NSAlert()
  alert.window.title = "Confirm Message"
  alert.messageText = "Confirm Message"
  alert.informativeText = "Recipient: \(recipient)\nSending application: iMessage MCP via Apple Messages\n\nReview the complete message below. Sending cannot be undone. A successful request does not guarantee delivery."
  let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
  scroll.hasVerticalScroller = true
  let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 445, height: 190))
  view.isEditable = false; view.isSelectable = true; view.string = text; view.font = NSFont.systemFont(ofSize: 15)
  scroll.documentView = view
  alert.accessoryView = scroll
  alert.addButton(withTitle: "Cancel")
  alert.addButton(withTitle: "Send this message")
  return runConnectionAlert(alert, stillConnected: stillConnected) == .alertSecondButtonReturn && stillConnected()
 }

 func approveBridgeConnection(stillConnected: @escaping () -> Bool) -> SessionAuthority.Mode? {
  let alert = NSAlert()
  alert.messageText = "Allow AI access for this connection?"
  alert.informativeText = "The adapter can be launched by other local processes. Approve only if you initiated this request. Retrieved message content may be sent to cloud-hosted AI. This connection shares the bridge's run-wide quotas and expiry.\n\n\(bridgeLimitsDescription())"
  alert.addButton(withTitle: "Deny")
  alert.addButton(withTitle: "Selected chat")
  alert.addButton(withTitle: "All chats")
  let answer = runConnectionAlert(alert, stillConnected: stillConnected)
  if answer == .alertSecondButtonReturn {
   guard let folder = ipcFolder, let chats = try? LocalMessageReader.conversations(folder: folder, filename: "chat.db"), !chats.isEmpty else { return nil }
   let chooser = AllowlistChooser(chats: chats)
   let entry = NSAlert()
   entry.messageText = "Select allowed conversations"
   entry.informativeText = "Only selected conversations can be accessed. Hold Command to select more than one. Retrieved message content may be sent to cloud-hosted AI."
   entry.accessoryView = chooser.view
   entry.addButton(withTitle: "Allow for this bridge run")
   entry.addButton(withTitle: "Cancel")
   guard runConnectionAlert(entry, stillConnected: stillConnected) == .alertFirstButtonReturn, stillConnected() else { return nil }
   let selected = chooser.selected()
   guard !selected.isEmpty, selected.count <= 100 else { return nil }
   return .assisted(selected)
  }
  if answer == .alertThirdButtonReturn {
   let warning = NSAlert()
   warning.messageText = "Allow all conversations?"
   warning.informativeText = "AI clients may send retrieved messages to cloud-hosted models. Any conversation can be accessed until this bridge run expires or you stop the bridge.\n\n\(bridgeLimitsDescription())"
   warning.addButton(withTitle: "Cancel")
   warning.addButton(withTitle: "Allow all for this bridge run")
   return runConnectionAlert(warning, stillConnected: stillConnected) == .alertSecondButtonReturn && stillConnected() ? .full : nil
  }
  return nil
 }

 func applicationWillTerminate(_ notification: Notification) { stopBridge() }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class FlippedView: NSView { override var isFlipped: Bool { true } }
