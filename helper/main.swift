// barhelper — native side of the bar.
//
//   barhelper daemon                              watch layout / wallpaper, fire sketchybar events
//   barhelper shape W H R FILL STROKE SW OUT [...] continuous-corner (squircle) PNGs, 7 args each
//   barhelper icon SIZE BUNDLE OUT [...]          app icon PNGs rendered at exact pixel size
//   barhelper battery PCT STATE COLOR OUT         battery with the level printed inside
//                                                 (STATE: 0 battery, 1 charging, 2 on AC)
//   barhelper measure FAMILY STYLE SIZE TEXT...   text widths in points, one per line
//   barhelper accent                              print wallpaper accent (0xAARRGGBB)
//   barhelper layout [next]                       print / switch keyboard layout
//   barhelper geometry                            "<screen_w> <left_of_notch_w> <right_of_notch_w> <scale> <narrowest_screen_w>"
//   barhelper render JSON                         whole islands as single images, prints JSON meta
//   barhelper cursor                              global cursor x
//   barhelper pick 0xAARRGGBB                     native color panel, live preview, prints result

import AppKit
import Carbon
import ScreenCaptureKit
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

// MARK: - Colors

func parseColor(_ s: String) -> CGColor {
  let v = UInt32(s.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0xffffffff
  func c(_ shift: UInt32) -> CGFloat { CGFloat((v >> shift) & 0xff) / 255 }
  return CGColor(srgbRed: c(16), green: c(8), blue: c(0), alpha: c(24))
}

func hex(_ c: NSColor) -> String {
  let s = c.usingColorSpace(.sRGB) ?? c
  func b(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
  return String(format: "0x%02x%02x%02x%02x", b(s.alphaComponent), b(s.redComponent), b(s.greenComponent), b(s.blueComponent))
}

// MARK: - Rendering

let backing: CGFloat = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

func render(_ w: CGFloat, _ h: CGFloat, to out: String, _ draw: (CGContext) -> Void) {
  // an empty/invalid size renders nothing; the caller keeps its previous image
  guard w.isFinite, h.isFinite, w >= 1, h >= 1,
        let cs = CGColorSpace(name: CGColorSpace.sRGB),
        let ctx = CGContext(data: nil, width: Int((w * backing).rounded()), height: Int((h * backing).rounded()),
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
  ctx.scaleBy(x: backing, y: backing)
  ctx.setShouldAntialias(true)
  ctx.interpolationQuality = .high
  draw(ctx)
  guard let image = ctx.makeImage() else { return }
  let rep = NSBitmapImageRep(cgImage: image)
  let tmp = out + ".\(getpid()).tmp"
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: tmp))
  // atomic swap so sketchybar never reads a half-written file
  _ = rename(tmp, out)
}

/// Apple's continuous corner curve, exactly as the system draws it.
func squircle(_ rect: CGRect, _ r: CGFloat) -> CGPath {
  RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect).cgPath
}

func shape(_ a: ArraySlice<String>) {
  let a = Array(a)
  let w = CGFloat(Double(a[0])!), h = CGFloat(Double(a[1])!), r = CGFloat(Double(a[2])!)
  let fill = parseColor(a[3]), stroke = parseColor(a[4])
  let sw = CGFloat(Double(a[5])!)
  render(w, h, to: a[6]) { ctx in
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.addPath(squircle(rect, r)); ctx.setFillColor(fill); ctx.fillPath()
    if sw > 0, stroke.alpha > 0 {
      let inset = rect.insetBy(dx: sw / 2, dy: sw / 2)
      ctx.addPath(squircle(inset, max(0, r - sw / 2)))
      ctx.setStrokeColor(stroke); ctx.setLineWidth(sw); ctx.strokePath()
    }
  }
}

func icon(size: CGFloat, bundle: String, out: String) {
  let ws = NSWorkspace.shared
  let img: NSImage
  if let url = ws.urlForApplication(withBundleIdentifier: bundle) {
    img = ws.icon(forFile: url.path)
  } else {
    img = ws.icon(for: .applicationBundle)
  }
  render(size, size, to: out) { ctx in
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
  }
}

func font(_ family: String, _ style: String, _ size: CGFloat) -> NSFont {
  let d = NSFontDescriptor(fontAttributes: [.family: family, .face: style])
  return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
}

func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f]))
  return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// Battery: squircle body with the level printed inside (knocked out of the
/// fill, solid over the empty part), optional bolt to the left.
let batteryHeight: CGFloat = 13
func batteryWidth(_ state: Int) -> CGFloat { (state > 0 ? 9 : 0) + 28 + 1 + 2 }

func drawBattery(_ ctx: CGContext, at origin: CGPoint, level: Int, state: Int, color: CGColor) {
  let bw: CGFloat = 28, bh = batteryHeight, nub: CGFloat = 2, gap: CGFloat = 1
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
  let body = CGRect(x: 0.5, y: 0.5, width: bw - 1, height: bh - 1)
  ctx.setAlpha(0.4)
  ctx.addPath(squircle(body, 4)); ctx.setStrokeColor(color); ctx.setLineWidth(1); ctx.strokePath()
  ctx.addPath(squircle(CGRect(x: bw + gap, y: bh / 2 - 2.25, width: nub, height: 4.5), 1))
  ctx.setFillColor(color); ctx.fillPath()
  ctx.setAlpha(1)

  let inner = body.insetBy(dx: 1.5, dy: 1.5)
  let fillRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(max(0, min(100, level))) / 100, height: inner.height)
  ctx.saveGState()
  ctx.clip(to: fillRect)
  ctx.addPath(squircle(inner, 2.5)); ctx.setFillColor(color); ctx.fillPath()
  ctx.restoreGState()

  let f = font("SF Pro Text", "Bold", 9)
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(level)", attributes: [
    .font: f, .foregroundColor: NSColor(cgColor: color)!, .kern: -0.2,
  ]))
  let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  let pos = CGPoint(x: (bw - tw) / 2, y: (bh - f.capHeight) / 2)
  ctx.saveGState()
  ctx.clip(to: CGRect(x: fillRect.maxX, y: 0, width: bw, height: bh))
  ctx.textPosition = pos; CTLineDraw(line, ctx)
  ctx.restoreGState()
  ctx.saveGState()
  ctx.clip(to: CGRect(x: 0, y: 0, width: fillRect.maxX, height: bh))
  ctx.setBlendMode(.destinationOut)
  ctx.textPosition = pos; CTLineDraw(line, ctx)
  ctx.restoreGState()
  ctx.endTransparencyLayer()
  ctx.restoreGState()
}

func battery(_ a: [String]) {
  let level = Int(a[0]) ?? 100, state = Int(a[1]) ?? 0
  render(batteryWidth(state), batteryHeight, to: a[3]) { ctx in
    drawBattery(ctx, at: .zero, level: level, state: state, color: parseColor(a[2]))
  }
}

// MARK: - Wallpaper accent

/// The live wallpaper layer (works for aerials / dynamic wallpapers), no windows on top.
func captureWallpaper() -> CGImage? {
  guard CGPreflightScreenCaptureAccess() else { return nil }
  let sem = DispatchSemaphore(value: 0)
  var result: CGImage?
  Task.detached {
    defer { sem.signal() }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? content.displays.first
    else { return }
    let wallpapers = content.windows.filter {
      $0.title == "Wallpaper" && $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager"
        && $0.frame.intersects(display.frame)
    }
    guard !wallpapers.isEmpty else { return }
    let cfg = SCStreamConfiguration()
    cfg.width = 192
    cfg.height = Int(192 * display.frame.height / max(1, display.frame.width))
    cfg.showsCursor = false
    let filter = SCContentFilter(display: display, including: wallpapers)
    result = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
  }
  _ = sem.wait(timeout: .now() + 3)
  return result
}

/// Aerials have no image file; fall back to the thumbnail of the chosen variant.
func aerialThumbnail() -> CGImage? {
  let base = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper"
  guard let data = FileManager.default.contents(atPath: base + "/Store/Index.plist"),
        let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let desk = (root["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"] as? [String: Any],
        let content = desk["Content"] as? [String: Any] else { return nil }
  var ids: [String] = []
  if let opts = content["EncodedOptionValues"] as? Data,
     let o = try? PropertyListSerialization.propertyList(from: opts, format: nil) as? [String: Any],
     let v = (((o["values"] as? [String: Any])?["aerialVariant"] as? [String: Any])?["picker"] as? [String: Any])?["_0"] as? [String: Any],
     let id = v["id"] as? String { ids.append(id) }
  if let choice = (content["Choices"] as? [[String: Any]])?.first, let cfg = choice["Configuration"] as? Data,
     let c = try? PropertyListSerialization.propertyList(from: cfg, format: nil) as? [String: Any],
     let id = c["assetID"] as? String { ids.append(id) }
  for id in ids {
    let url = URL(fileURLWithPath: base + "/aerials/thumbnails/\(id).png")
    if let img = loadThumb(url) { return img }
  }
  return nil
}

func loadThumb(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateThumbnailAtIndex(src, 0, [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: 192,
  ] as CFDictionary)
}

func wallpaperImage() -> CGImage? {
  if let img = captureWallpaper() { return img }
  if let img = aerialThumbnail() { return img }
  let screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
  if let url = screen.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }) { return loadThumb(url) }
  return nil
}

/// Most prominent hue of the wallpaper, lifted to read well on a dark bar.
/// Dark wallpapers count too: hue is weighted by saturation, brightness only gates noise.
func accent() -> String {
  let neutral = "0xffc9ced6"
  guard let img = wallpaperImage() else { return neutral }

  let w = img.width, h = img.height
  var px = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

  let buckets = 36
  var weight = [Double](repeating: 0, count: buckets)
  var hx = weight, hy = weight, sat = weight
  var total = 0.0
  for i in stride(from: 0, to: px.count, by: 4) {
    let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
    var H: CGFloat = 0, S: CGFloat = 0, B: CGFloat = 0
    c.getHue(&H, saturation: &S, brightness: &B, alpha: nil)
    total += 1
    guard B > 0.08, S > 0.12 else { continue }
    let k = min(buckets - 1, Int(H * CGFloat(buckets)))
    // chroma-weighted: vivid pixels dominate, brightness matters only a little
    let wgt = Double(S * S) * Double(0.35 + 0.65 * B)
    weight[k] += wgt
    hx[k] += cos(Double(H) * 2 * .pi) * wgt; hy[k] += sin(Double(H) * 2 * .pi) * wgt
    sat[k] += Double(S) * wgt
  }
  let score = (0..<buckets).map { weight[($0 + buckets - 1) % buckets] * 0.5 + weight[$0] + weight[($0 + 1) % buckets] * 0.5 }
  guard let best = score.indices.max(by: { score[$0] < score[$1] }),
        score[best] > total * 0.002 else { return neutral }

  // average hue over the winning neighbourhood
  var x = 0.0, y = 0.0, s = 0.0, ww = 0.0
  for k in [best + buckets - 1, best, best + 1].map({ $0 % buckets }) {
    x += hx[k]; y += hy[k]; s += sat[k]; ww += weight[k]
  }
  var hue = atan2(y, x) / (2 * .pi); if hue < 0 { hue += 1 }
  return normalizeAccent(NSColor(hue: hue, saturation: max(0.35, s / ww), brightness: 0.9, alpha: 1))
}

func colorDistance(_ a: String, _ b: String) -> Int {
  guard let x = UInt32(a.dropFirst(2), radix: 16), let y = UInt32(b.dropFirst(2), radix: 16) else { return 999 }
  return [16, 8, 0].reduce(0) { $0 + abs(Int((x >> UInt32($1)) & 0xff) - Int((y >> UInt32($1)) & 0xff)) }
}


// MARK: - Whole-island rendering
//
// On macOS 26+ sketchybar can't batch window updates, so an island made of
// several items can tear for a frame. Each island is therefore drawn here as
// ONE image shown by ONE item: every state change is a single atomic update.

func textLine(_ s: String, _ f: NSFont, _ c: CGColor) -> CTLine {
  CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
    .font: f, .foregroundColor: NSColor(cgColor: c) ?? .white,
  ]))
}

func lineWidth(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

/// Draw with the cap height centered on `mid` (optical centering, like the menu bar).
func drawLine(_ ctx: CGContext, _ l: CTLine, x: CGFloat, mid: CGFloat, _ f: NSFont) {
  ctx.textPosition = CGPoint(x: x, y: mid - f.capHeight / 2)
  CTLineDraw(l, ctx)
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

func drawIcon(_ ctx: CGContext, _ img: NSImage, _ rect: CGRect) {
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  NSGraphicsContext.current?.imageInterpolation = .high
  img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
}

func num(_ d: [String: Any], _ k: String, _ def: CGFloat = 0) -> CGFloat {
  (d[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? def
}
func str(_ d: [String: Any], _ k: String, _ def: String = "") -> String { d[k] as? String ?? def }
func col(_ d: [String: Any], _ k: String) -> CGColor { parseColor(str(d, k, "0x00000000")) }

func islandBackground(_ ctx: CGContext, _ j: [String: Any], w: CGFloat, h: CGFloat) {
  let rect = CGRect(x: 0, y: 0, width: w, height: h)
  let r = num(j, "r")
  ctx.addPath(squircle(rect, r)); ctx.setFillColor(col(j, "fill")); ctx.fillPath()
  let sw = num(j, "sw")
  if sw > 0 {
    ctx.addPath(squircle(rect.insetBy(dx: sw / 2, dy: sw / 2), max(0, r - sw / 2)))
    ctx.setStrokeColor(col(j, "stroke")); ctx.setLineWidth(sw); ctx.strokePath()
  }
}

struct Laid {
  let w: CGFloat
  let draw: (CGContext) -> Void
  var ranges: [[CGFloat]] = []
}

/// Workspaces island. Hit ranges (relative to the island) map clicks back.
func layoutSpaces(_ j: [String: Any]) -> Laid {
  let h = num(j, "h"), inset = num(j, "inset"), pad = num(j, "pad"), numGap = num(j, "num_gap")
  let iconSize = num(j, "icon"), slot = num(j, "slot"), tail = num(j, "tail")
  let pillH = num(j, "pill_h"), pillR = num(j, "pill_r")
  let f = font(str(j, "font"), str(j, "style"), num(j, "size"))
  let small = font(str(j, "font"), str(j, "style"), num(j, "size") - 1.5)
  let maxSlots = Int(num(j, "max_slots", 8))
  let wss = j["workspaces"] as? [[String: Any]] ?? []

  struct WS { let n: Int; let focused: Bool; let hovered: Bool; let label: CTLine; let labelW: CGFloat; let apps: [String]; let overflow: Int; let w: CGFloat }
  var items: [WS] = []
  for ws in wss {
    let n = Int(num(ws, "n")), focused = (ws["focused"] as? Bool) ?? false
    let hovered = !focused && ((ws["hovered"] as? Bool) ?? false)
    let all = ws["apps"] as? [String] ?? []
    let shown = all.count > maxSlots ? Array(all.prefix(maxSlots - 1)) : all
    let overflow = all.count > maxSlots ? all.count - shown.count : 0
    let label = textLine("\(n)", f, col(j, focused ? "fg" : (hovered ? "hover_fg" : "dim")))
    let lw = ceil(lineWidth(label))
    let slots = CGFloat(shown.count + (overflow > 0 ? 1 : 0))
    let w = slots > 0 ? pad + lw + numGap + slots * slot + tail : pad + lw + pad
    items.append(WS(n: n, focused: focused, hovered: hovered, label: label, labelW: lw, apps: shown, overflow: overflow, w: w))
  }
  let width = items.reduce(inset) { $0 + $1.w + inset }
  var ranges: [[CGFloat]] = []
  var x = inset
  for ws in items {
    ranges.append([CGFloat(ws.n), x - inset / 2, x + ws.w + inset / 2])
    x += ws.w + inset
  }
  return Laid(w: width, draw: { ctx in
    islandBackground(ctx, j, w: width, h: h)
    let mid = h / 2
    var x = inset
    for ws in items {
      if ws.focused || ws.hovered {
        let pill = CGRect(x: x, y: (h - pillH) / 2, width: ws.w, height: pillH)
        ctx.addPath(squircle(pill, pillR)); ctx.setFillColor(col(j, ws.focused ? "pill" : "hover")); ctx.fillPath()
      }
      drawLine(ctx, ws.label, x: x + pad, mid: mid, f)
      var ix = x + pad + ws.labelW + numGap
      for app in ws.apps {
        drawIcon(ctx, appIcon(app), CGRect(x: ix + (slot - iconSize) / 2, y: (h - iconSize) / 2, width: iconSize, height: iconSize))
        ix += slot
      }
      if ws.overflow > 0 {
        let l = textLine("+\(ws.overflow)", small, col(j, "dim"))
        drawLine(ctx, l, x: ix + (slot - lineWidth(l)) / 2, mid: mid, small)
      }
      x += ws.w + inset
    }
  }, ranges: ranges)
}

/// Generic island: a row of parts (text / battery / gap) between two paddings.
func layoutIsland(_ j: [String: Any]) -> Laid {
  let h = num(j, "h")
  let parts = j["parts"] as? [[String: Any]] ?? []
  struct Part { let w: CGFloat; let draw: (CGContext, CGFloat) -> Void }
  var laid: [Part] = []
  for p in parts {
    switch str(p, "type") {
    case "text":
      let f = font(str(p, "font", "SF Pro Text"), str(p, "style", "Medium"), num(p, "size", 12.5))
      let l = textLine(str(p, "text"), f, col(p, "color"))
      let tw = lineWidth(l)
      var minW = num(p, "min_w")
      if let t = p["min_text"] as? String { minW = max(minW, lineWidth(textLine(t, f, col(p, "color")))) }
      let w = ceil(max(tw, minW))
      let align = str(p, "align", "left")
      laid.append(Part(w: w) { ctx, x in
        let dx = align == "right" ? w - tw : (align == "center" ? (w - tw) / 2 : 0)
        drawLine(ctx, l, x: x + dx, mid: h / 2, f)
      })
    case "battery":
      let state = Int(num(p, "state")), level = Int(num(p, "level"))
      let c = col(p, "color")
      laid.append(Part(w: batteryWidth(state)) { ctx, x in
        drawBattery(ctx, at: CGPoint(x: x, y: (h - batteryHeight) / 2), level: level, state: state, color: c)
      })
    default:
      laid.append(Part(w: num(p, "w")) { _, _ in })
    }
  }
  let pl = num(j, "pad_l"), pr = num(j, "pad_r")
  let width = pl + laid.reduce(0) { $0 + $1.w } + pr
  return Laid(w: width, draw: { ctx in
    islandBackground(ctx, j, w: width, h: h)
    var x = pl
    for p in laid { p.draw(ctx, x); x += p.w }
  })
}

func layoutJob(_ j: [String: Any]) -> Laid {
  str(j, "kind") == "spaces" ? layoutSpaces(j) : layoutIsland(j)
}

/// A fixed-size canvas holding one or more islands. The item showing it never
/// changes size, so sketchybar never resizes its window: every update is a
/// pure content swap, i.e. exactly one frame.
///   canvas_w   fixed width (or center_from_right: canvas grows to center the
///              content at that distance from the right edge — for tooltips)
///   align      "left" | "right"
///   gap        space between islands
func renderRow(_ j: [String: Any]) -> [String: Any] {
  let h = num(j, "h")
  let gap = num(j, "gap")
  let laid = (j["islands"] as? [[String: Any]] ?? []).map(layoutJob)
  let total = laid.reduce(0) { $0 + $1.w } + gap * CGFloat(max(0, laid.count - 1))
  var canvas = num(j, "canvas_w")
  if let c = j["center_from_right"] as? NSNumber { canvas = CGFloat(c.doubleValue) + total / 2 }
  canvas = max(canvas, total)
  let start = str(j, "align") == "right" ? canvas - total : 0
  var meta: [[String: Any]] = []
  var x = start
  for l in laid {
    meta.append(["x0": x, "x1": x + l.w, "ranges": l.ranges])
    x += l.w + gap
  }
  render(canvas, h, to: str(j, "out")) { ctx in
    var x = start
    for l in laid {
      ctx.saveGState(); ctx.translateBy(x: x, y: 0); l.draw(ctx); ctx.restoreGState()
      x += l.w + gap
    }
  }
  return ["width": canvas, "islands": meta]
}

/// `barhelper render '<json array of row jobs>'` → JSON array of metadata.
func renderJobs(_ json: String) {
  guard let data = json.data(using: .utf8),
        let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    print("[]"); return
  }
  var out: [[String: Any]] = []
  for j in jobs {
    var meta = renderRow(j)
    let path = str(j, "out")
    guard FileManager.default.fileExists(atPath: path) else { continue } // nothing rendered
    meta["out"] = path
    out.append(meta)
  }
  guard let d = try? JSONSerialization.data(withJSONObject: out), let text = String(data: d, encoding: .utf8) else {
    print("[]"); return
  }
  print(text)
}

// MARK: - OKLCH (perceptual accent normalization)

func srgbToLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func linearToSrgb(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

func toOklch(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, C: Double, h: Double) {
  let (lr, lg, lb) = (srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
  let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
  let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
  let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
  let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
  let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
  let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  return (L, sqrt(A * A + B * B), atan2(B, A))
}

func fromOklch(_ L: Double, _ C: Double, _ h: Double) -> (Double, Double, Double)? {
  let A = C * cos(h), B = C * sin(h)
  let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
  let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
  let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
  let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  guard [r, g, b].allSatisfy({ $0 >= -0.0005 && $0 <= 1.0005 }) else { return nil }
  return (linearToSrgb(max(0, r)), linearToSrgb(max(0, g)), linearToSrgb(max(0, b)))
}

/// Keep only the wallpaper's hue; give it a fixed, vivid tone so it reads as
/// an accent against both the wallpaper and the dark islands.
func normalizeAccent(_ c: NSColor) -> String {
  let s = c.usingColorSpace(.sRGB)!
  let (_, C, h) = toOklch(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
  if C < 0.02 { return "0xffc9ced6" } // no real hue: neutral
  var chroma = 0.15
  while chroma > 0.02 {
    if let (r, g, b) = fromOklch(0.78, chroma, h) {
      return hex(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }
    chroma -= 0.005
  }
  return "0xffc9ced6"
}

/// The bar is drawn on every display, so positions are relative to the screen
/// under the cursor: returns (x from that screen's left edge, its width).
func cursorOnScreen() -> (x: CGFloat, width: CGFloat) {
  let p = NSEvent.mouseLocation
  let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
  guard let f = screen?.frame else { return (p.x, 0) }
  return (p.x - f.minX, f.width)
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

// MARK: - Daemon

final class Daemon {
  var lastAccent = ""
  var pending: DispatchWorkItem?
  var watcher: DispatchSourceFileSystemObject?
  let work = DispatchQueue(label: "accent")

  // Hover regions of the bar, written by lua: "strip <height>" then
  // "<name> <left|right> <d0> <d1>" — [d0, d1) measured from that edge of the
  // screen under the cursor, so the same regions apply on every display.
  // Fixed-size items can't tell which island the cursor is over, so the daemon
  // does, and fires `bar_hover REGION=<name>` only when the region changes.
  let regionsPath = NSHomeDirectory() + "/.local/state/sketchybar/regions"
  var regions: [(name: String, fromRight: Bool, d0: CGFloat, d1: CGFloat)] = []
  var strip: CGFloat = 32
  var regionsStamp: Date?
  var hovered = ""

  func loadRegions() {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: regionsPath))?[.modificationDate] as? Date
    guard stamp != regionsStamp else { return }
    regionsStamp = stamp
    regions = []
    let text = (try? String(contentsOfFile: regionsPath, encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") {
      let f = line.split(separator: " ")
      guard f.count >= 2 else { continue }
      if f[0] == "strip", let h = Double(f[1]) { strip = CGFloat(h); continue }
      if f.count >= 4, f[1] == "left" || f[1] == "right", let a = Double(f[2]), let b = Double(f[3]) {
        regions.append((String(f[0]), f[1] == "right", CGFloat(a), CGFloat(b)))
      }
    }
  }

  func checkHover() {
    let p = NSEvent.mouseLocation
    var name = ""
    if let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
       screen.frame.maxY - p.y <= strip {
      loadRegions()
      let fromLeft = p.x - screen.frame.minX, fromRight = screen.frame.maxX - p.x
      name = regions.first {
        let d = $0.fromRight ? fromRight : fromLeft
        return d >= $0.d0 && d < $0.d1
      }?.name ?? ""
    }
    guard name != hovered else { return }
    hovered = name
    triggerAsync("bar_hover", ["REGION": name])
  }

  var parentWatch: DispatchSourceProcess?

  /// Exit together with sketchybar (the daemon is detached via nohup, so it
  /// would otherwise keep capturing the wallpaper and spawning failing
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
    ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in self.scheduleAccent() }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in self.scheduleAccent(delay: 2) }
    ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in self.scheduleAccent(delay: 2) }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in self.scheduleAccent() }
    watchWallpaperStore()
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in self.checkHover() }
    // aerials drift slowly; re-sample now and then, only large changes are emitted
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in self.scheduleAccent() }
    emitLayout()
    scheduleAccent(delay: 0.3, force: true)
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
  }

  func emitLayout() {
    let l = layoutCode()
    triggerAsync("layout_change", ["LAYOUT": l])
  }

  var pendingForce = false

  func scheduleAccent(delay: Double = 1.0, force: Bool = false) {
    pending?.cancel()
    // a forced update (new wallpaper) survives being rescheduled by a
    // non-forced one (e.g. a space change right after)
    pendingForce = pendingForce || force
    let item = DispatchWorkItem {
      let force = self.pendingForce
      self.pendingForce = false
      self.work.async {
        let a = accent()
        DispatchQueue.main.async {
          if force || self.lastAccent.isEmpty || colorDistance(a, self.lastAccent) > 36 {
            self.lastAccent = a
            triggerAsync("wallpaper_change", ["ACCENT": a])
          }
        }
      }
    }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  // The wallpaper store plist is replaced atomically, so watch its directory.
  func watchWallpaperStore() {
    let dir = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store"
    let fd = open(dir, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
    src.setEventHandler { self.scheduleAccent(delay: 2, force: true) }
    src.setCancelHandler { close(fd) }
    src.resume()
    watcher = src
  }
}

// MARK: - Color picker

final class Picker: NSObject {
  var last = ""
  var changed = false
  var pending: DispatchWorkItem?

  func run(_ initial: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.isContinuous = true
    panel.color = NSColor(cgColor: parseColor(initial)) ?? .systemBlue
    last = hex(panel.color.withAlphaComponent(1))
    panel.setTarget(self)
    panel.setAction(#selector(colorChanged(_:)))
    panel.title = "Bar accent"
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
      // closing without touching the color is a cancel (keeps Auto mode)
      print(self.changed ? self.last : "cancel"); fflush(stdout); exit(0)
    }
    app.activate(ignoringOtherApps: true)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    app.run()
  }

  @objc func colorChanged(_ sender: NSColorPanel) {
    changed = true
    last = hex(sender.color.withAlphaComponent(1))
    pending?.cancel()
    let c = last
    let work = DispatchWorkItem { triggerAsync("accent_preview", ["ACCENT": c]) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
  }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "daemon": Daemon().run()
case "shape":
  var rest = args.dropFirst()
  while rest.count >= 7 { shape(rest.prefix(7)); rest = rest.dropFirst(7) }
case "icon":
  let size = CGFloat(Double(args[1]) ?? 18)
  var rest = args.dropFirst(2)
  while rest.count >= 2 { icon(size: size, bundle: rest.first!, out: rest.dropFirst().first!); rest = rest.dropFirst(2) }
case "battery": battery(Array(args.dropFirst()))
case "measure":
  let f = font(args[1], args[2], CGFloat(Double(args[3]) ?? 12))
  for s in args.dropFirst(4) { print(String(format: "%.2f", textWidth(s, f))) }
case "accent": print(accent())
case "render": renderJobs(args.count > 1 ? args[1] : "[]")
case "cursor":
  let c = cursorOnScreen()
  print(Int(c.x), Int(c.width))
case "layout": if args.count > 1, args[1] == "next" { nextLayout() } else { print(layoutCode()) }
case "geometry":
  let s = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main!
  let w = s.frame.width
  let l = s.auxiliaryTopLeftArea?.width ?? w / 2
  let r = s.auxiliaryTopRightArea?.width ?? w / 2
  let narrowest = NSScreen.screens.map(\.frame.width).min() ?? w
  print(Int(w), Int(l), Int(r), backing, Int(narrowest))
case "pick": Picker().run(args.count > 1 ? args[1] : "0xff8ec8ff")
default:
  FileHandle.standardError.write("usage: barhelper daemon|shape|icon|battery|measure|accent|layout|geometry|pick\n".data(using: .utf8)!)
  exit(1)
}
