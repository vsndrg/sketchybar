// barhelper — native side of the bar.
//
//   barhelper daemon RADIUS    draws the bar (Liquid Glass windows, bar.swift) from the state lua writes,
//                              fires sketchybar events (layout, minute, menu picks), masks the built-in
//                              display's bottom corners (RADIUS, 0 = off), reconnects Sidecar after wake
//   barhelper layout [next]    print / switch keyboard layout
//   barhelper screens          per display: "<NSScreen index, 1-based> <CGDirectDisplayID> <w> <left_of_notch_w|0>
//                              <menu bar height> <kind>" (maps aerospace's monitor-appkit-nsscreen-screens-id)
//   barhelper sleep            end Sidecar sessions, then sleep the system (F6 in Karabiner;
//                              the daemon reconnects the iPad after wake)

import AppKit
import Carbon
import IOKit.pwr_mgt
import SwiftUI

let sketchybar = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/sketchybar")
  ? "/opt/homebrew/bin/sketchybar" : "/usr/local/bin/sketchybar"

/// All events go through one serial queue: sent in parallel, two events fired
/// a few ms apart (hover in/out, EN→RU→EN) could arrive in the wrong order,
/// and since the daemon only re-sends on change, the bar would stay wrong.
let triggerQueue = DispatchQueue(label: "trigger")

func triggerAsync(_ event: String, _ vars: [String: String]) {
  triggerQueue.async { trigger(event, vars) }
}

func trigger(_ event: String, _ vars: [String: String]) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: sketchybar)
  p.arguments = ["--trigger", event] + vars.map { "\($0.key)=\($0.value)" }
  try? p.run()
  p.waitUntilExit()
}

// MARK: - Drawing

/// Apple's continuous corner curve, exactly as the system draws it.
func squircle(_ rect: CGRect, _ r: CGFloat) -> CGPath {
  RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect).cgPath
}

func font(_ family: String, _ style: String, _ size: CGFloat) -> NSFont {
  let d = NSFontDescriptor(fontAttributes: [.family: family, .face: style])
  return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
}


/// Battery, drawn like macOS: a solid squircle body, the charged part opaque,
/// the rest translucent, the level knocked out of the whole body (readable
/// wherever the fill edge falls); optional bolt to the left.
let batteryHeight: CGFloat = 13
func batteryWidth(_ state: Int) -> CGFloat { (state > 0 ? 9 : 0) + 28 + 1 + 2 }

func drawBattery(_ ctx: CGContext, at origin: CGPoint, level: Int, state: Int, color: CGColor,
                 style: String = "Bold", size: CGFloat = 10) {
  let bw: CGFloat = 28, bh = batteryHeight, nub: CGFloat = 2, gap: CGFloat = 1
  let empty: CGFloat = 0.4 // alpha of the uncharged part and the nub
  ctx.saveGState()
  ctx.translateBy(x: origin.x, y: origin.y)
  ctx.beginTransparencyLayer(auxiliaryInfo: nil) // keeps the digit knock-out local
  if state > 0 {
    let b = CGMutablePath(), cy = bh / 2, cx: CGFloat = 3.5
    b.move(to: CGPoint(x: cx + 1.2, y: cy + 5.6))
    b.addLine(to: CGPoint(x: cx - 3.2, y: cy - 0.8))
    b.addLine(to: CGPoint(x: cx - 0.2, y: cy - 0.8))
    b.addLine(to: CGPoint(x: cx - 1.2, y: cy - 5.6))
    b.addLine(to: CGPoint(x: cx + 3.2, y: cy + 0.8))
    b.addLine(to: CGPoint(x: cx + 0.2, y: cy + 0.8))
    b.closeSubpath()
    ctx.setAlpha(state == 1 ? 1 : 0.45)
    ctx.addPath(b); ctx.setFillColor(color); ctx.fillPath()
    ctx.setAlpha(1)
    ctx.translateBy(x: 9, y: 0)
  }
  let body = CGRect(x: 0, y: 0, width: bw, height: bh)
  ctx.setFillColor(color)
  ctx.setAlpha(empty)
  ctx.addPath(squircle(body, 4)); ctx.fillPath()
  ctx.addPath(squircle(CGRect(x: bw + gap, y: bh / 2 - 2.25, width: nub, height: 4.5), 1)); ctx.fillPath()
  ctx.setAlpha(1)
  ctx.saveGState()
  ctx.clip(to: CGRect(x: 0, y: 0, width: bw * CGFloat(max(0, min(100, level))) / 100, height: bh))
  ctx.addPath(squircle(body, 4)); ctx.fillPath() // over the translucent body: no seam at the edge
  ctx.restoreGState()

  let f = font("SF Pro Text", style, size)
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(level)", attributes: [
    .font: f, .foregroundColor: NSColor(cgColor: color)!, .kern: -0.2,
  ]))
  let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  let pos = CGPoint(x: (bw - tw) / 2, y: (bh - f.capHeight) / 2)
  ctx.setBlendMode(.destinationOut)
  ctx.textPosition = pos; CTLineDraw(line, ctx)
  ctx.endTransparencyLayer()
  ctx.restoreGState()
}

var iconCache: [String: NSImage] = [:]
func appIcon(_ bundle: String) -> NSImage {
  if let i = iconCache[bundle] { return i }
  let ws = NSWorkspace.shared
  let img = ws.urlForApplication(withBundleIdentifier: bundle).map { ws.icon(forFile: $0.path) }
    ?? ws.icon(for: .applicationBundle)
  iconCache[bundle] = img
  return img
}

// MARK: - Displays

func displayID(_ s: NSScreen) -> CGDirectDisplayID {
  (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

/// What kind of device a display is: builtin, ipad (Sidecar reports vendor
/// 'aapl' and model 'iPad' as FourCCs) or display. Names are localized, so
/// they aren't used.
func displayKind(_ id: CGDirectDisplayID) -> String {
  if CGDisplayIsBuiltin(id) != 0 { return "builtin" }
  if CGDisplayVendorNumber(id) == 0x6161_706C && CGDisplayModelNumber(id) == 0x6950_6164 { return "ipad" }
  return "display"
}

/// Menu bar height of each display (0 = unknown). WindowServer keeps one
/// menu bar window per display, listed even while the menu bar is
/// auto-hidden (then just moved above the screen). Matched by owner and
/// level: window names of other apps need Screen Recording.
func menuBarHeights() -> [CGDirectDisplayID: Int] {
  var out: [CGDirectDisplayID: Int] = [:]
  let level = Int(CGWindowLevelForKey(.mainMenuWindow))
  let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
  let bars = list.compactMap { w -> CGRect? in
    guard w[kCGWindowOwnerName as String] as? String == "Window Server",
          w[kCGWindowLayer as String] as? Int == level,
          let d = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: d)
  }
  for s in NSScreen.screens {
    let id = displayID(s), b = CGDisplayBounds(id)
    if let r = bars.first(where: { abs($0.minX - b.minX) < 1 && abs($0.width - b.width) < 1 }) {
      out[id] = Int(r.height)
    }
  }
  return out
}

// MARK: - Keyboard layout

func layoutCode() -> String {
  let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
  if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
    let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String] ?? []
    if let l = langs.first { return String(l.prefix(2)).uppercased() }
  }
  return "??"
}

func sourceID(_ s: TISInputSource) -> String {
  guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
  return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func nextLayout() {
  let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
  guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
        !list.isEmpty else { return }
  let cur = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
  let i = list.firstIndex { sourceID($0) == cur } ?? -1
  TISSelectInputSource(list[(i + 1) % list.count])
}

// MARK: - Screen corners

/// The built-in panel's top corners are physically rounded, the bottom ones
/// are not: mask the bottom corners with black so all four match. Only the
/// built-in display (CGDisplayIsBuiltin); rebuilt when screens change.
// Private (SkyLight via CoreGraphics): the Spaces of every display, as the
// Mission Control / AeroSpace see them.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

/// Whether the display currently shows a native fullscreen app's Space.
func showsFullscreenSpace(_ id: CGDirectDisplayID) -> Bool {
  guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
        let str = CFUUIDCreateString(nil, uuid) as String?,
        let list = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return false }
  let entry = list.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(str) == .orderedSame }
    // with "Displays have separate Spaces" off there is one entry for all displays
    ?? (list.count == 1 ? list.first : nil)
  let current = entry?["Current Space"] as? [String: Any]
  return (current?["type"] as? Int) == 4
}

final class Corners {
  let radius: CGFloat
  var windows: [NSWindow] = []
  var display: CGDirectDisplayID = 0

  /// radius of Apple's continuous corner (the curve reaches ~1.53 r along each edge)
  init(radius: CGFloat) { self.radius = radius }

  /// Black outside the continuous corner, rendered once: the window shows it as
  /// static layer contents (no draw() calls, nothing to redraw).
  func mask(_ s: CGFloat, scale: CGFloat, right: Bool) -> CGImage? {
    let px = Int((s * scale).rounded())
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    // a big rect whose bottom-left / bottom-right corner sits in this window
    ctx.setBlendMode(.clear)
    ctx.addPath(squircle(CGRect(x: right ? s - 4 * s : 0, y: 0, width: 4 * s, height: 4 * s), radius))
    ctx.fillPath()
    return ctx.makeImage()
  }

  func update() {
    windows.forEach { $0.orderOut(nil) }
    windows = []
    display = 0
    guard radius > 0,
          let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin(displayID($0)) != 0 }) else { return }
    display = displayID(screen)
    let s = ceil(radius * 1.53) + 1
    for right in [false, true] {
      let f = screen.frame
      let frame = NSRect(x: right ? f.maxX - s : f.minX, y: f.minY, width: s, height: s)
      let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = false
      w.ignoresMouseEvents = true
      w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
      // like the physical top corners, keep them out of screenshots
      w.sharingType = .none
      let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
      view.wantsLayer = true
      view.layerContentsRedrawPolicy = .never
      view.layer?.contents = mask(s, scale: screen.backingScaleFactor, right: right)
      view.layer?.contentsScale = screen.backingScaleFactor
      w.contentView = view
      windows.append(w)
    }
    refresh()
  }

  /// Hidden while the built-in display shows a fullscreen app (the corners
  /// would sit on top of its content, and cost the fullscreen fast path).
  func refresh() {
    let hide = display != 0 && showsFullscreenSpace(display)
    for w in windows {
      if hide { w.orderOut(nil) } else { w.orderFrontRegardless() }
    }
  }
}

// MARK: - Daemon

final class Daemon {
  var prefsWatcher: DispatchSourceFileSystemObject?
  var iconTheme = Daemon.iconTheme()
  let corners: Corners
  let bar = GlassBar()
  let sidecar = SidecarReconnect()

  /// cornerRadius: bottom corners of the built-in display (0 = off), see Corners
  init(cornerRadius: CGFloat) { corners = Corners(radius: cornerRadius) }

  var parentWatch: DispatchSourceProcess?
  var minuteTimer: Timer?

  /// Fires `minute_change` right on every minute boundary (the clock), one
  /// wakeup a minute. Timers don't follow the wall clock across sleep or a
  /// clock change, so those re-align it.
  func scheduleMinute() {
    minuteTimer?.invalidate()
    let now = Date().timeIntervalSince1970
    let next = (floor(now / 60) + 1) * 60
    // a hair past the boundary, so the new minute is what the bar reads
    let t = Timer(fire: Date(timeIntervalSince1970: next + 0.005), interval: 0, repeats: false) { _ in
      triggerAsync("minute_change", [:])
      self.scheduleMinute()
    }
    t.tolerance = 0.005
    RunLoop.main.add(t, forMode: .common)
    minuteTimer = t
  }

  /// Exit together with sketchybar (the daemon is detached via nohup, so it
  /// would otherwise keep showing a bar nobody updates and spawning failing
  /// triggers after the bar is stopped).
  func exitWithSketchybar() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "sketchybar"]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let pid = text.split(separator: "\n").compactMap({ pid_t($0) }).first else { exit(0) }
    let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    src.setEventHandler { exit(0) }
    src.resume()
    parentWatch = src
  }

  func run() {
    exitWithSketchybar()
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                    object: nil, queue: .main) { _ in self.emitLayout() }
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
      self.corners.refresh()
    }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
      self.scheduleMinute()
      triggerAsync("minute_change", [:])
    }
    NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
      self.scheduleMinute()
      triggerAsync("minute_change", [:])
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
      self.corners.update()
      self.bar.screensChanged()
    }
    corners.update()
    sidecar.watch()
    watchIconTheme()
    // the bar's own windows get their clicks; a global one is always elsewhere
    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
      self.bar.menu.hide()
    }
    // another app coming forward (cmd-N) closes the menu — except right after a
    // click in it: on another display aerospace focuses that display on click
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
      if Date().timeIntervalSince(self.bar.menu.clicked) > 1 { self.bar.menu.hide() }
    }
    emitLayout()
    scheduleMinute()
    NSApplication.shared.setActivationPolicy(.prohibited)
    bar.start()
    NSApplication.shared.run()
  }

  func emitLayout() {
    let l = layoutCode()
    triggerAsync("layout_change", ["LAYOUT": l])
  }

  /// System Settings → Appearance → Icons (default / dark / clear / tinted) only
  /// changes global preferences; AppKit's own notification doesn't reach other
  /// processes. The bar's app icons are cached: re-read them.
  static func iconTheme() -> String {
    let keys = ["AppleIconAppearanceTheme", "AppleIconAppearanceTintColor"]
    return keys.map { k in
      CFPreferencesCopyAppValue(k as CFString, kCFPreferencesAnyApplication).map { "\($0)" } ?? "-"
    }.joined(separator: "|").filter { $0.isLetter || $0.isNumber || $0 == "|" || $0 == "." || $0 == "-" }
  }

  // cfprefsd replaces .GlobalPreferences.plist (a directory write) within a
  // second or two of the change.
  func watchIconTheme() {
    let fd = open(NSHomeDirectory() + "/Library/Preferences", O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
    src.setEventHandler {
      let t = Daemon.iconTheme()
      guard t != self.iconTheme else { return }
      self.iconTheme = t
      self.bar.iconsChanged()
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    prefsWatcher = src
  }
}

// MARK: - Sleep

let sleepLog = NSHomeDirectory() + "/.local/state/sketchybar/sleep.log"

/// Appends (the daemon and F6 both write here); past 256 KB keeps the newest half.
func sleepLogLine(_ s: String) {
  let fm = FileManager.default
  if !fm.fileExists(atPath: sleepLog) { fm.createFile(atPath: sleepLog, contents: nil) }
  guard let h = FileHandle(forUpdatingAtPath: sleepLog) else { return }
  defer { h.closeFile() }
  let size = h.seekToEndOfFile()
  if size > 256 << 10 {
    h.seek(toFileOffset: size / 2)
    var tail = h.readDataToEndOfFile()
    if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: nl)) }
    h.truncateFile(atOffset: 0)
    h.write(tail)
  }
  h.write("\(Date()) \(s)\n".data(using: .utf8)!)
}

/// SidecarCore's display manager (private; what the Control Center display menu uses).
final class Sidecar {
  typealias Completion = @convention(block) (NSError?) -> Void
  typealias Call = @convention(c) (NSObject, Selector, NSObject, @escaping Completion) -> Void

  let manager: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil,
          let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { return nil }
    return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
  }()

  func devices(_ key: String) -> [NSObject] { manager?.value(forKey: key) as? [NSObject] ?? [] }
  func id(_ d: NSObject) -> String { (d.value(forKey: "identifier") as? UUID)?.uuidString ?? "" }
  var connected: [NSObject] { devices("connectedDevices") }

  func call(_ name: String, _ device: NSObject, _ done: @escaping (NSError?) -> Void) {
    guard let m = manager else { return }
    let sel = NSSelectorFromString(name)
    let f = unsafeBitCast(m.method(for: sel), to: Call.self)
    f(m, sel, device) { e in DispatchQueue.main.async { done(e) } }
  }
}

/// Sidecar sessions end when the Mac sleeps (lid closed, idle, F6) and macOS
/// doesn't bring them back. Runs in the daemon: remembers the iPads connected
/// going to sleep and connects them again after wake, once the screen is
/// unlocked (the lock screen isn't worth mirroring). Closing the lid may drop
/// the iPad just before the sleep notification, so ones lost moments earlier
/// count too. Opening the lid changes the main screen, so sketchybarrc restarts
/// the daemon right after wake: the list is kept in a file and a fresh daemon
/// picks it up. The bar may also restart the daemon between the iPad dropping
/// and the sleep (lid closed on the charger: the iPad goes first), so recent
/// losses are kept in a file too. Log: ~/.local/state/sketchybar/sleep.log.
final class SidecarReconnect {
  static let wantPath = NSHomeDirectory() + "/.local/state/sketchybar/sidecar-reconnect"
  static let lostPath = NSHomeDirectory() + "/.local/state/sketchybar/sidecar-lost"
  let sidecar = Sidecar()
  let started = DispatchTime.now()  // uptime: stands still while asleep
  var sawSleep = false
  var connected = Set<String>()
  var lost: [String: Date] = [:] {  // disconnected iPads → when
    didSet {
      guard lost != oldValue else { return }
      if lost.isEmpty { try? FileManager.default.removeItem(atPath: Self.lostPath) }
      else {
        let text = lost.map { "\($0.key) \($0.value.timeIntervalSince1970)" }.sorted().joined(separator: "\n")
        try? text.write(toFile: Self.lostPath, atomically: true, encoding: .utf8)
      }
    }
  }
  var want = Set<String>() {  // to connect after wake
    didSet {
      if want.isEmpty { try? FileManager.default.removeItem(atPath: Self.wantPath) }
      else { try? want.sorted().joined(separator: "\n").write(toFile: Self.wantPath, atomically: true, encoding: .utf8) }
    }
  }
  var running = false, attempts = 0
  var loop = 0  // a retry scheduled by an earlier loop stops when this changes
  var done: () -> Void = {}

  func track() {
    let now = Set(sidecar.connected.map(sidecar.id))
    for i in connected.subtracting(now) { lost[i] = Date() }
    for i in now { lost[i] = nil }
    connected = now
  }

  func watch() {
    // left by the daemon this one replaced
    let text = (try? String(contentsOfFile: Self.lostPath, encoding: .utf8)) ?? ""
    for l in text.split(separator: "\n") {
      let f = l.split(separator: " ")
      guard f.count == 2, let t = Double(f[1]) else { continue }
      let date = Date(timeIntervalSince1970: t)
      if Date().timeIntervalSince(date) < 30 { lost[String(f[0])] = date }
    }
    if lost.isEmpty { try? FileManager.default.removeItem(atPath: Self.lostPath) }  // stale
    track()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
      self.track()
      // SidecarCore may catch up with the display change a moment later
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.track() }
    }
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in self.willSleep() }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in self.woke() }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { _ in if !self.want.isEmpty && !self.running { sleepLogLine("unlocked"); self.start() } }
    // left by a daemon that went to sleep (a day old = something went wrong, drop it)
    let attrs = try? FileManager.default.attributesOfItem(atPath: Self.wantPath)
    if let date = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(date) < 86400,
       let text = try? String(contentsOfFile: Self.wantPath, encoding: .utf8) {
      want = Set(text.split(separator: "\n").map(String.init))
      sleepLogLine("daemon started, pending reconnect: \(want.sorted())")
      didWake()
    } else {
      want = []
    }
  }

  func willSleep() {
    sawSleep = true
    track()
    let recent = lost.filter { Date().timeIntervalSince($0.value) < 30 }.keys
    lost = [:]
    // never shrinks: a dark wake can sleep again with the iPad already gone
    want.formUnion(connected.union(recent))
    running = false  // a retry loop from the last wake stops
    if !want.isEmpty { sleepLogLine("will sleep, reconnect after wake: \(want.sorted())") }
  }

  /// Woken without a willSleep: this daemon started while the Mac was already
  /// going to sleep (the bar restarted it), so what it saw lost counts.
  func woke() {
    let awake = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
    if !sawSleep && awake < 30 {
      track()
      if !lost.isEmpty { sleepLogLine("started while going to sleep, reconnect: \(lost.keys.sorted())") }
      want.formUnion(lost.keys)
      lost = [:]
    }
    sawSleep = true
    didWake()
  }

  func didWake() {
    guard !want.isEmpty else { return }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    if session?["CGSSessionScreenIsLocked"] as? Bool == true { sleepLogLine("did wake, waiting for unlock"); return }
    sleepLogLine("did wake")
    start()
  }

  /// Once: unlock right after wake and didWake both get here.
  func start() {
    guard !running else { return }
    running = true
    attempts = 0
    loop += 1
    reconnect(loop)
  }

  func finish(_ s: String) {
    sleepLogLine(s)
    want = []
    running = false
    done()
  }

  /// The iPad may need a few seconds after wake to show up; retry for about a minute.
  func reconnect(_ loop: Int) {
    guard running, loop == self.loop else { return }
    let have = Set(sidecar.connected.map(sidecar.id))
    let missing = want.subtracting(have)
    if missing.isEmpty { return finish("all connected") }
    attempts += 1
    if attempts > 20 { return finish("giving up on \(missing.sorted())") }
    let available = sidecar.devices("devices")
    var left = missing.count
    for i in missing {
      let next = {
        left -= 1
        if left == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.reconnect(loop) } }
      }
      guard let d = available.first(where: { self.sidecar.id($0) == i }) else { sleepLogLine("\(i) not available yet"); next(); continue }
      sidecar.call("connectToDevice:completion:", d) { e in
        sleepLogLine("connect \(i) \(e?.localizedDescription ?? "ok")")
        next()
      }
    }
  }
}

/// F6: a Sidecar session keeps the iPad lit while the Mac sleeps, so end it
/// first, then sleep. The daemon's SidecarReconnect brings the iPad back after
/// wake; this process only does that itself if the sleep doesn't happen.
/// It stays alive through the sleep and exits after wake: exiting inside the
/// willSleep handler leaves the sleep unacknowledged, and the kernel then
/// waits its full 30 s timeout with the screen off (the iPad gone for good by then).
final class SidecarSleep {
  let sidecar = Sidecar()
  var requested = false, asleep = false

  func run() {
    signal(SIGHUP, SIG_IGN)
    setsid()  // outlive the shell Karabiner runs us from
    let connected = sidecar.connected
    sleepLogLine("sidecar connected: \(connected.map(sidecar.id))")
    if connected.isEmpty { sleepNow(); exit(0) }

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { _ in self.asleep = true }  // returning acknowledges the sleep
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in if self.asleep { exit(0) } }

    var left = connected.count
    for d in connected {
      sidecar.call("disconnectFromDevice:completion:", d) { e in
        sleepLogLine("disconnected \(self.sidecar.id(d)) \(e?.localizedDescription ?? "ok")")
        left -= 1
        if left == 0 { self.sleepNow() }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.sleepNow() }  // Sidecar didn't answer
    // sleep refused (no willSleep) → give the iPad back right away
    // (uptime: after a sleep this fires 18 s into the wake)
    DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
      if self.asleep { exit(0) }
      sleepLogLine("sleep didn't happen")
      let r = SidecarReconnect()
      r.want = Set(connected.map(self.sidecar.id))
      r.done = { exit(0) }
      r.start()
    }
    RunLoop.main.run()
  }

  func sleepNow() {
    guard !requested else { return }
    requested = true
    sleepLogLine("sleep")
    let pm = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    IOPMSleepSystem(pm)
    IOServiceClose(pm)
  }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "daemon":
  Daemon(cornerRadius: CGFloat(args.count > 1 ? Double(args[1]) ?? 0 : 0)).run()
case "layout": if args.count > 1, args[1] == "next" { nextLayout() } else { print(layoutCode()) }
case "screens":
  // NSScreen index, CGDirectDisplayID, width, width left of the notch (0 = none), menu bar height, kind
  let menuBars = menuBarHeights()
  for (i, s) in NSScreen.screens.enumerated() {
    print(i + 1, displayID(s), Int(s.frame.width), Int(s.auxiliaryTopLeftArea?.width ?? 0), menuBars[displayID(s)] ?? 0,
          displayKind(displayID(s)))
  }
case "sleep": SidecarSleep().run()
default:
  FileHandle.standardError.write("usage: barhelper daemon|layout|screens|sleep\n".data(using: .utf8)!)
  exit(1)
}
