// barhelper — native side of the bar.
//
//   barhelper daemon                              watch layout / wallpaper, fire sketchybar events,
//                                                 show the theme menu on a right click on the bar
//   barhelper shape W H R FILL STROKE SW OUT [...] continuous-corner (squircle) PNGs, 7 args each
//   barhelper icon SIZE BUNDLE OUT [...]          app icon PNGs rendered at exact pixel size
//   barhelper battery PCT STATE COLOR OUT         battery with the level printed inside
//                                                 (STATE: 0 battery, 1 charging, 2 on AC)
//   barhelper measure FAMILY STYLE SIZE TEXT...   text widths in points, one per line
//   barhelper accent                              print wallpaper accent (0xAARRGGBB)
//   barhelper phase [LAT LON]                     dynamic wallpaper: "<frame now> <next switch>" (nothing if static)
//   barhelper layout [next]                       print / switch keyboard layout
//   barhelper geometry                            main screen: "<screen_w> <left_of_notch_w> <right_of_notch_w> <scale>"
//   barhelper screens                             per display: "<NSScreen index, 1-based> <CGDirectDisplayID> <w> <left_of_notch_w|0>"
//                                                 (maps aerospace's monitor-appkit-nsscreen-screens-id to displays)
//   barhelper render JSON                         whole islands as single images, prints JSON meta
//   barhelper cursor                              global cursor x
//   barhelper pick 0xAARRGGBB                     native color panel, live preview, prints result
//   barhelper sleep                               end Sidecar sessions, then sleep the system (F6 in Karabiner;
//                                                 the daemon reconnects the iPad after wake)

import AppKit
import Carbon
import IOKit.pwr_mgt
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

/// scale: pixel density relative to the backing scale; shown at 1/backing the
/// image is a crisp scaled copy (a shorter bar strip on some display).
func render(_ w: CGFloat, _ h: CGFloat, to out: String, scale: CGFloat = 1, _ draw: (CGContext) -> Void) {
  let density = backing * scale
  // an empty/invalid size renders nothing; the caller keeps its previous image
  guard w.isFinite, h.isFinite, w >= 1, h >= 1, density > 0,
        let cs = CGColorSpace(name: CGColorSpace.sRGB),
        let ctx = CGContext(data: nil, width: Int((w * density).rounded()), height: Int((h * density).rounded()),
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
  ctx.scaleBy(x: density, y: density)
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
  guard let content = desktopWallpaperContent(),
        (content["Choices"] as? [[String: Any]])?.first?["Provider"] as? String == "com.apple.wallpaper.choice.aerials"
  else { return nil }
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
  if let dyn = dynamicWallpaper(), let src = CGImageSourceCreateWithURL(dyn.url as CFURL, nil),
     let img = CGImageSourceCreateThumbnailAtIndex(src, dyn.frame(Date()), [
       kCGImageSourceCreateThumbnailFromImageAlways: true,
       kCGImageSourceThumbnailMaxPixelSize: 192,
     ] as CFDictionary) { return img }
  if let img = aerialThumbnail() { return img }
  let screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
  if let url = screen.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }) { return loadThumb(url) }
  return nil
}

// MARK: - Dynamic wallpaper phases
//
// A dynamic wallpaper is a HEIC with several frames and a schedule in its XMP:
// `apple_desktop:solar` (sun altitude/azimuth per frame) or `apple_desktop:h24`
// (time of day per frame). WindowManager shows the frame closest to the sun's
// (or clock's) position, so the next switch is known in advance: the daemon
// re-samples the accent then instead of polling. The sun is placed at
// `sunLocation` (config.lua `location`), else at the time zone's reference city
// (zone.tab) — no location access — which can be off by half an hour; the
// daemon then looks again later (see Daemon.schedulePhase).

/// Latitude/longitude (radians) from the daemon's arguments, nil = unknown.
var sunLocation: (Double, Double)?

func parseLocation(_ a: ArraySlice<String>) -> (Double, Double)? {
  guard a.count >= 2, let lat = Double(a[a.startIndex]), let lon = Double(a[a.startIndex + 1]) else { return nil }
  return (lat * .pi / 180, lon * .pi / 180)
}

/// Desktop wallpaper settings (all spaces and displays) from the wallpaper store.
func desktopWallpaperContent() -> [String: Any]? {
  let path = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
  guard let data = FileManager.default.contents(atPath: path),
        let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let desk = (root["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"] as? [String: Any]
  else { return nil }
  return desk["Content"] as? [String: Any]
}

func plist(_ data: Any?) -> [String: Any]? {
  (data as? Data).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
}

/// The desktop wallpaper's HEIC and the frame it shows at a given date, if it
/// is dynamic (and set to follow the time of day, not light/dark/appearance).
func dynamicWallpaper() -> (url: URL, frame: (Date) -> Int)? {
  guard let content = desktopWallpaperContent(),
        let choice = (content["Choices"] as? [[String: Any]])?.first else { return nil }
  let style = (((plist(content["EncodedOptionValues"])?["values"] as? [String: Any])?["style"]
    as? [String: Any])?["picker"] as? [String: Any]).flatMap { ($0["_0"] as? [String: Any])?["id"] as? String }
  if let style, style != "dynamic" { return nil }
  // system pictures: a .madesktop plist naming a downloaded asset; own files: the .heic itself
  let urls = [((plist(choice["Configuration"])?["url"] as? [String: Any])?["relative"] as? String)]
    + ((choice["Files"] as? [[String: Any]]) ?? []).map { ($0["relative"] as? String) }
  guard var url = urls.compactMap({ $0.flatMap(URL.init(string:)) }).first else { return nil }
  if url.pathExtension == "madesktop" {
    guard let d = FileManager.default.contents(atPath: url.path),
          let m = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
          m["isDynamic"] as? Bool == true, let id = m["mobileAssetID"] as? String else { return nil }
    url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.apple.mobileAssetDesktop/\(id).heic")
  }
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return nil }
  func tag(_ name: String) -> [String: Any]? {
    (CGImageMetadataCopyStringValueWithPath(meta, nil, name as CFString) as String?)
      .flatMap { Data(base64Encoded: $0) }
      .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
  }
  if let solar = tag("apple_desktop:solar")?["si"] as? [[String: Any]] {
    let frames = solar.compactMap { f -> (alt: Double, az: Double, i: Int)? in
      guard let a = (f["a"] as? NSNumber)?.doubleValue, let z = (f["z"] as? NSNumber)?.doubleValue,
            let i = (f["i"] as? NSNumber)?.intValue else { return nil }
      return (a * .pi / 180, z * .pi / 180, i)
    }
    guard !frames.isEmpty else { return nil }
    let (lat, lon) = sunLocation ?? timeZoneLocation()
    return (url, { date in
      let sun = sunPosition(date, lat: lat, lon: lon)
      // nearest frame on the sky (great-circle distance)
      return frames.max { f, g in
        func closeness(_ f: (alt: Double, az: Double, i: Int)) -> Double {
          sin(f.alt) * sin(sun.alt) + cos(f.alt) * cos(sun.alt) * cos(f.az - sun.az)
        }
        return closeness(f) < closeness(g)
      }!.i
    })
  }
  if let h24 = tag("apple_desktop:h24")?["ti"] as? [[String: Any]] {
    let frames = h24.compactMap { f -> (t: Double, i: Int)? in
      guard let t = (f["t"] as? NSNumber)?.doubleValue, let i = (f["i"] as? NSNumber)?.intValue else { return nil }
      return (t, i)
    }.sorted { $0.t < $1.t }
    guard let last = frames.last else { return nil }
    return (url, { date in
      let c = Calendar.current.dateComponents([.hour, .minute], from: date)
      let t = (Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60) / 24
      return (frames.last { $0.t <= t } ?? last).i
    })
  }
  return nil
}

/// When the dynamic wallpaper switches to another frame next (minute precision).
func nextWallpaperPhase(after start: Date = Date()) -> Date? {
  guard let frame = dynamicWallpaper()?.frame else { return nil }
  let now = frame(start)
  for m in 1...(26 * 60) {
    let t = start.addingTimeInterval(Double(m) * 60)
    if frame(t) != now { return t }
  }
  return nil
}

/// Latitude/longitude (radians) of the current time zone's reference city.
func timeZoneLocation() -> (Double, Double) {
  let tz = TimeZone.current
  let fallback = (45 * Double.pi / 180, Double(tz.secondsFromGMT()) / 240 * .pi / 180)
  guard let tab = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8),
        let line = tab.split(separator: "\n").first(where: { $0.split(separator: "\t").dropFirst(2).first == Substring(tz.identifier) })
  else { return fallback }
  // ±DDMM[SS]±DDDMM[SS]
  let coord = String(line.split(separator: "\t")[1])
  guard let split = coord.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return fallback }
  func angle(_ s: Substring, degDigits: Int) -> Double {
    let sign: Double = s.first == "-" ? -1 : 1
    let d = Array(s.dropFirst()).map { Double(String($0)) ?? 0 }
    func num(_ r: Range<Int>) -> Double { r.upperBound <= d.count ? r.reduce(0) { $0 * 10 + d[$1] } : 0 }
    let deg = num(0..<degDigits), min = num(degDigits..<degDigits + 2), sec = num(degDigits + 2..<degDigits + 4)
    return sign * (deg + min / 60 + sec / 3600) * .pi / 180
  }
  return (angle(coord[..<split], degDigits: 2), angle(coord[split...], degDigits: 3))
}

/// Sun altitude and azimuth (radians, azimuth clockwise from north), low-precision
/// ephemeris (≈0.01° — far below what matters for picking a frame).
func sunPosition(_ date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double) {
  let rad = Double.pi / 180
  let d = date.timeIntervalSince1970 / 86400 - 10957.5 // days since J2000.0
  let g = (357.529 + 0.98560028 * d) * rad
  let q = 280.459 + 0.98564736 * d
  let l = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
  let e = (23.439 - 0.00000036 * d) * rad
  let ra = atan2(cos(e) * sin(l), cos(l)), dec = asin(sin(e) * sin(l))
  let gmst = (280.46061837 + 360.98564736629 * d) * rad
  let ha = gmst + lon - ra
  let alt = asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha))
  let az = atan2(-sin(ha), tan(dec) * cos(lat) - sin(lat) * cos(ha))
  return (alt, az < 0 ? az + 2 * .pi : az)
}

/// The hue that covers most of the wallpaper right under the bar (its top
/// eighth; the whole wallpaper if that strip is gray). Area-weighted, not the
/// most saturated one: a sunset glow at the horizon would win that, and a dark
/// orange island is just brown — the sky it hangs on is what the bar goes with.
func accent() -> String {
  let neutral = "0xffc9ced6"
  guard let img = wallpaperImage() else { return neutral }

  let w = img.width, h = img.height
  var px = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

  /// Dominant hue of pixel rows 0..<rows (row 0 = top), nil if they're gray.
  func dominantHue(rows: Int) -> Double? {
    let buckets = 36
    var weight = [Double](repeating: 0, count: buckets)
    var hx = weight, hy = weight
    for i in stride(from: 0, to: rows * w * 4, by: 4) {
      let (L, C, hue) = toOklch(Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
      guard L > 0.08, C > 0.02 else { continue }
      let k = Int((hue < 0 ? hue + 2 * .pi : hue) / (2 * .pi) * Double(buckets)) % buckets
      weight[k] += C; hx[k] += cos(hue) * C; hy[k] += sin(hue) * C
    }
    let score = (0..<buckets).map { weight[($0 + buckets - 1) % buckets] * 0.5 + weight[$0] + weight[($0 + 1) % buckets] * 0.5 }
    // colored pixels must cover a meaningful part of the area (C ≈ 0.05 on 5% of it)
    guard let best = score.indices.max(by: { score[$0] < score[$1] }),
          score[best] > Double(rows * w) * 0.0025 else { return nil }
    let near = [best + buckets - 1, best, best + 1].map { $0 % buckets }
    return atan2(near.reduce(0) { $0 + hy[$1] }, near.reduce(0) { $0 + hx[$1] })
  }
  guard let hue = dominantHue(rows: max(1, h / 8)) ?? dominantHue(rows: h) else { return neutral }
  return normalizeAccent(hue: hue)
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

var symbolCache: [String: NSImage] = [:]
/// An SF Symbol `width` pt wide, tinted `color`.
func symbolImage(_ name: String, _ width: CGFloat, _ color: CGColor) -> NSImage? {
  let key = "\(name)|\(width)|\(color)"
  if let i = symbolCache[key] { return i }
  // point size ≈ 3/4 of the width: device symbols are wider than tall
  guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: width * 0.75, weight: .semibold)),
    let tint = NSColor(cgColor: color) else { return nil }
  let img = NSImage(size: sym.size, flipped: false) { r in
    sym.draw(in: r)
    tint.set()
    r.fill(using: .sourceAtop)
    return true
  }
  symbolCache[key] = img
  return img
}

/// NSImage.draw sets its own opacity (ignores the context alpha): pass it here.
func drawIcon(_ ctx: CGContext, _ img: NSImage, _ rect: CGRect, alpha: CGFloat = 1) {
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  NSGraphicsContext.current?.imageInterpolation = .high
  img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
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

  let deviceW = num(j, "device_w"), deviceSlot = num(j, "device_slot")

  // focused: the workspace shown on this display (pill; "pill_idle" when the
  // display isn't the focused one). device: it lives on another display —
  // that display's glyph (SF Symbol) sits between the digit and the icons.
  // ring: the focused workspace, seen from another display — a dashed
  // outline in the accent.
  struct WS { let n: Int; let focused: Bool; let idle: Bool; let device: NSImage?; let ring: Bool; let hovered: Bool; let label: CTLine; let labelW: CGFloat; let apps: [String]; let overflow: Int; let w: CGFloat }
  var items: [WS] = []
  for ws in wss {
    let n = Int(num(ws, "n")), focused = (ws["focused"] as? Bool) ?? false
    let idle = focused && ((ws["idle"] as? Bool) ?? false)
    let device = focused ? nil : (ws["device"] as? String).flatMap { symbolImage($0, deviceW, col(j, "dim")) }
    let ring = !focused && ((ws["ring"] as? Bool) ?? false)
    let hovered = !focused && ((ws["hovered"] as? Bool) ?? false)
    let all = ws["apps"] as? [String] ?? []
    let shown = all.count > maxSlots ? Array(all.prefix(maxSlots - 1)) : all
    let overflow = all.count > maxSlots ? all.count - shown.count : 0
    let label = textLine("\(n)", f, col(j, focused ? "fg" : (hovered ? "hover_fg" : "dim")))
    let lw = ceil(lineWidth(label))
    let slots = CGFloat(shown.count + (overflow > 0 ? 1 : 0))
    // an empty workspace ends with the glyph itself: pad after it, like after a digit
    let w = slots > 0 ? pad + lw + numGap + (device == nil ? 0 : deviceSlot) + slots * slot + tail
                      : pad + lw + (device == nil ? 0 : numGap + deviceW) + pad
    items.append(WS(n: n, focused: focused, idle: idle, device: device, ring: ring, hovered: hovered, label: label, labelW: lw, apps: shown, overflow: overflow, w: w))
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
        ctx.addPath(squircle(pill, pillR))
        ctx.setFillColor(col(j, ws.focused ? (ws.idle ? "pill_idle" : "pill") : "hover")); ctx.fillPath()
      }
      if ws.ring {
        let lw = num(j, "ring_w", 1.25)
        let pill = CGRect(x: x, y: (h - pillH) / 2, width: ws.w, height: pillH).insetBy(dx: lw / 2, dy: lw / 2)
        ctx.saveGState()
        ctx.addPath(squircle(pill, max(0, pillR - lw / 2)))
        ctx.setStrokeColor(col(j, "ring")); ctx.setLineWidth(lw)
        ctx.setLineDash(phase: 0, lengths: [3, 2.5])
        ctx.strokePath()
        ctx.restoreGState()
      }
      drawLine(ctx, ws.label, x: x + pad, mid: mid, f)
      var ix = x + pad + ws.labelW + numGap
      if let g = ws.device {
        let gh = deviceW * g.size.height / g.size.width
        drawIcon(ctx, g, CGRect(x: ix, y: mid - gh / 2, width: deviceW, height: gh))
        ix += deviceSlot
      }
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
      let c = col(p, "color"), style = str(p, "style", "Bold"), size = num(p, "size", 10)
      laid.append(Part(w: batteryWidth(state)) { ctx, x in
        drawBattery(ctx, at: CGPoint(x: x, y: (h - batteryHeight) / 2), level: level, state: state, color: c,
                    style: style, size: size)
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

/// The theme menu: Lua lays it out (entries with rects in pt from the top-left),
/// this only draws it. Entries: "text" (centered) or "swatch" (a color dot);
/// a selected text entry sits on a pill, a selected swatch gets a white dot.
/// It floats over windows, so it casts a shadow like a system menu (a tight
/// contact one and a soft wide one) into a margin of `m` around it; a
/// non-key window's own shadow is too faint to separate it from them.
func layoutMenu(_ j: [String: Any]) -> Laid {
  let w = num(j, "w"), h = num(j, "h"), m = num(j, "m")
  let entries = j["entries"] as? [[String: Any]] ?? []
  return Laid(w: w + 2 * m, draw: { ctx in
    ctx.translateBy(x: m, y: m)
    let body = squircle(CGRect(x: 0, y: 0, width: w, height: h), num(j, "r"))
    for (blur, dy, alpha) in [(CGFloat(22), CGFloat(-8), CGFloat(0.6)), (3, -1, 0.6)] {
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: CGColor(gray: 0, alpha: alpha))
      ctx.addPath(body); ctx.setFillColor(col(j, "fill")); ctx.fillPath()
      ctx.restoreGState()
    }
    islandBackground(ctx, j, w: w, h: h)
    for e in entries {
      let r = CGRect(x: num(e, "x"), y: h - num(e, "y") - num(e, "h"), width: num(e, "w"), height: num(e, "h"))
      let selected = (e["selected"] as? Bool) ?? false
      if str(e, "type") == "swatch" {
        let d = num(e, "d")
        let dot = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        ctx.addEllipse(in: dot); ctx.setFillColor(col(e, "color")); ctx.fillPath()
        ctx.addEllipse(in: dot.insetBy(dx: 0.5, dy: 0.5))
        ctx.setStrokeColor(col(e, "ring")); ctx.setLineWidth(1); ctx.strokePath()
        if selected {
          let m = num(e, "mark")
          ctx.addEllipse(in: CGRect(x: r.midX - m / 2, y: r.midY - m / 2, width: m, height: m))
          ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        }
        continue
      }
      if selected {
        ctx.addPath(squircle(r, num(j, "pill_r"))); ctx.setFillColor(col(j, "pill")); ctx.fillPath()
      }
      let f = font(str(e, "font"), str(e, "style"), num(e, "size"))
      let l = textLine(str(e, "text"), f, col(e, "color"))
      drawLine(ctx, l, x: r.midX - lineWidth(l) / 2, mid: r.midY, f)
    }
  })
}

func layoutJob(_ j: [String: Any]) -> Laid {
  switch str(j, "kind") {
  case "spaces": return layoutSpaces(j)
  case "menu": return layoutMenu(j)
  default: return layoutIsland(j)
  }
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
  render(canvas, h, to: str(j, "out"), scale: j["scale"] == nil ? 1 : num(j, "scale")) { ctx in
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

/// Keep only the wallpaper's hue (OKLCH, radians); give it a fixed, vivid tone
/// so it reads as an accent against both the wallpaper and the dark islands.
func normalizeAccent(hue h: Double) -> String {
  var chroma = 0.15
  while chroma > 0.02 {
    if let (r, g, b) = fromOklch(0.78, chroma, h) {
      return hex(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }
    chroma -= 0.005
  }
  return "0xffc9ced6"
}

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

/// The bar is drawn on every display, so positions are relative to the screen
/// under the cursor: returns (x from that screen's left edge, its width).
func cursorOnScreen() -> (x: CGFloat, width: CGFloat, display: CGDirectDisplayID) {
  let p = NSEvent.mouseLocation
  guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main
  else { return (p.x, 0, 0) }
  return (p.x - screen.frame.minX, screen.frame.width, displayID(screen))
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

// MARK: - Tooltips

/// Bar tooltips (the battery's) as the daemon's own window, shown on the
/// display under the cursor — a sketchybar popup only appears on the display
/// with the focused window. Lua renders the images and lists them in
/// ~/.local/state/sketchybar/tooltips: "<region> <display> <right> <top> <png>"
/// (the image's right edge / top edge in pt from the screen's right / top edge).
/// Showing one on hover spawns nothing, so it appears with the hover itself.
final class Tooltips {
  let path = NSHomeDirectory() + "/.local/state/sketchybar/tooltips"
  var entries: [String: (right: CGFloat, top: CGFloat, png: String)] = [:] // "<region> <display>"
  var stamp: Date?
  var window: NSWindow?
  var shown = "" // key of the tooltip on screen

  func load() -> Bool {
    let st = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard st != stamp else { return false }
    stamp = st
    entries = [:]
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") {
      let f = line.split(separator: " ", maxSplits: 4)
      guard f.count == 5, let r = Double(f[2]), let t = Double(f[3]) else { continue }
      entries["\(f[0]) \(f[1])"] = (CGFloat(r), CGFloat(t), String(f[4]))
    }
    return true
  }

  /// Show the tooltip of `region` on `display` (CGDirectDisplayID), or hide.
  func update(region: String, display: String) {
    if region.isEmpty && shown.isEmpty { return } // the common case: every mouse move off the bar
    let changed = load()
    let key = "\(region) \(display)"
    guard key != shown || changed else { return }
    guard !region.isEmpty, let e = entries[key],
          let screen = NSScreen.screens.first(where: { String(displayID($0)) == display }),
          let img = NSImage(contentsOfFile: e.png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      window?.orderOut(nil)
      shown = ""
      return
    }
    // rendered at the backing scale (times the strip's scale), shown 1:1
    let size = NSSize(width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing)
    let f = screen.frame
    let frame = NSRect(x: f.maxX - e.right - size.width, y: f.maxY - e.top - size.height,
                       width: size.width, height: size.height)
    let w = window ?? makeWindow()
    w.setFrame(frame, display: false)
    w.contentView?.layer?.contents = img
    w.contentView?.layer?.contentsScale = backing
    w.orderFrontRegardless()
    window = w
    shown = key
  }

  func makeWindow() -> NSWindow {
    let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = .popUpMenu
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    let view = NSView()
    view.wantsLayer = true
    view.layerContentsRedrawPolicy = .never
    w.contentView = view
    return w
  }
}

// MARK: - Menu

/// The theme menu, opened by a right click anywhere on the bar, as the daemon's
/// own window on the display that was clicked (a sketchybar popup only appears
/// on the display with the focused window). Lua renders it per display and
/// lists it in ~/.local/state/sketchybar/menu:
///   "menu <display> <right> <top> <hover_r> <hover_color> <png>"
///       image's right / top edge in pt from the screen's; the hover highlight
///   "hit <display> <id> <x0> <y0> <x1> <y1>"  clickable entries, pt from the image's top-left
/// The entry under the cursor gets a highlight layer over the image (no
/// re-render). A click on an entry fires `menu_select ID=<id>` and leaves the
/// menu open (the new state re-renders it in place); a click anywhere else closes it.
final class Menu {
  let path = NSHomeDirectory() + "/.local/state/sketchybar/menu"
  var menus: [String: (right: CGFloat, top: CGFloat, hoverR: CGFloat, hover: CGColor, png: String)] = [:] // display
  var hits: [String: [(id: String, rect: CGRect)]] = [:]
  var stamp: Date?
  var panel: NSPanel?
  var shown = "" // display the menu is open on
  var clicked = Date.distantPast // last click on an entry
  let image = CALayer() // the menu's image, placed in the window (which is clipped to the screen)
  let highlight = CALayer() // in the image's coordinates
  var hovered = "" // entry id under the cursor
  var watcher: DispatchSourceFileSystemObject?

  var isOpen: Bool { !shown.isEmpty }

  func load() -> Bool {
    let st = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard st != stamp else { return false }
    stamp = st
    menus = [:]
    hits = [:]
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") {
      let f = line.split(separator: " ", maxSplits: 6)
      if f.count == 7, f[0] == "menu", let r = Double(f[2]), let t = Double(f[3]), let hr = Double(f[4]) {
        menus[String(f[1])] = (CGFloat(r), CGFloat(t), CGFloat(hr), parseColor(String(f[5])), String(f[6]))
      } else if f.count == 7, f[0] == "hit", let x0 = Double(f[3]), let y0 = Double(f[4]),
                let x1 = Double(f[5]), let y1 = Double(f[6]) {
        hits[String(f[1]), default: []].append((String(f[2]), CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)))
      }
    }
    return true
  }

  func toggle(on display: String) {
    if shown == display { hide() } else { show(display) }
  }

  func show(_ display: String) {
    _ = load()
    guard let e = menus[display],
          let screen = NSScreen.screens.first(where: { String(displayID($0)) == display }),
          let img = NSImage(contentsOfFile: e.png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      hide()
      return
    }
    // rendered at the backing scale (times the strip's scale), shown 1:1
    let size = NSSize(width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing)
    let f = screen.frame
    let rect = NSRect(x: f.maxX - e.right - size.width, y: f.maxY - e.top - size.height,
                      width: size.width, height: size.height)
    // the shadow margin may reach past the screen's edge, onto a neighbor display
    let frame = rect.intersection(f)
    guard !frame.isEmpty else { hide(); return }
    let p = panel ?? makePanel()
    p.setFrame(frame, display: false)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    image.frame = CGRect(x: rect.minX - frame.minX, y: rect.minY - frame.minY, width: size.width, height: size.height)
    image.contents = img
    image.contentsScale = backing
    CATransaction.commit()
    highlight.cornerRadius = e.hoverR
    highlight.backgroundColor = e.hover
    p.orderFrontRegardless()
    panel = p
    shown = display
    hovered = ""
    hover(p.mouseLocationOutsideOfEventStream)
    watch()
  }

  func hide() {
    panel?.orderOut(nil)
    shown = ""
    hover(nil)
  }

  /// A point in the view (origin bottom-left) in the image's coordinates (origin top-left).
  func imagePoint(_ point: NSPoint) -> CGPoint {
    CGPoint(x: point.x - image.frame.minX, y: image.frame.maxY - point.y)
  }

  /// Highlights the entry under `point` (view coordinates; nil = none).
  func hover(_ point: NSPoint?) {
    var hit: (id: String, rect: CGRect)?
    if let point, let v = panel?.contentView, v.bounds.contains(point) {
      let p = imagePoint(point)
      hit = hits[shown]?.first { $0.rect.contains(p) }
    }
    guard (hit?.id ?? "") != hovered else { return }
    hovered = hit?.id ?? ""
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let hit {
      highlight.frame = CGRect(x: hit.rect.minX, y: image.bounds.height - hit.rect.maxY,
                               width: hit.rect.width, height: hit.rect.height)
      highlight.isHidden = false
    } else {
      highlight.isHidden = true
    }
    CATransaction.commit()
  }

  /// A click inside the menu, in the view's coordinates.
  func click(_ point: NSPoint) {
    let p = imagePoint(point)
    guard let hit = hits[shown]?.first(where: { $0.rect.contains(p) }) else {
      // the image's margin holds the shadow: a click there is a click outside
      let body = (hits[shown] ?? []).reduce(CGRect.null) { $0.union($1.rect) }.insetBy(dx: -6, dy: -6)
      if !body.contains(p) { hide() }
      return
    }
    clicked = Date()
    if hit.id == "custom" { hide() } // the color panel takes over
    triggerAsync("menu_select", ["ID": hit.id])
  }

  /// Picks up a new image (a selection re-renders the menu) while it is open.
  func watch() {
    guard watcher == nil else { return }
    let fd = open((path as NSString).deletingLastPathComponent, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
    src.setEventHandler {
      if self.isOpen, self.load() { self.show(self.shown) }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    watcher = src
  }

  func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false // drawn into the image (see layoutMenu)
    p.hidesOnDeactivate = false
    p.acceptsMouseMovedEvents = true // else only entering the window updates the hover
    p.becomesKeyOnlyIfNeeded = true
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    let view = MenuView()
    view.onClick = { [weak self] in self?.click($0) }
    view.onHover = { [weak self] in self?.hover($0) }
    view.wantsLayer = true
    view.layerContentsRedrawPolicy = .never
    p.contentView = view
    highlight.cornerCurve = .continuous
    highlight.isHidden = true
    image.addSublayer(highlight)
    view.layer?.addSublayer(image)
    return p
  }
}

final class MenuView: NSView {
  var onClick: ((NSPoint) -> Void)?
  var onHover: ((NSPoint?) -> Void)?
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    // activeAlways: the daemon's app is never active
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }
  override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
  override func mouseEntered(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
  override func mouseExited(with event: NSEvent) { onHover?(nil) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if bounds.contains(p) { onClick?(p) }
  }
}

/// CGDirectDisplayID of the display whose bar is under the click, or nil: the
/// window the click went to must be sketchybar's (not a window, not the
/// auto-hidden menu bar sliding in over the bar).
func barDisplay(_ e: NSEvent) -> String? {
  let p = NSEvent.mouseLocation
  guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
        let wid = e.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),
        wid > 0,
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(wid)) as? [[String: Any]],
        info.first?[kCGWindowOwnerName as String] as? String == "sketchybar" else { return nil }
  return String(displayID(screen))
}

// MARK: - Daemon

final class Daemon {
  var lastAccent = ""
  var pending: DispatchWorkItem?
  var watcher: DispatchSourceFileSystemObject?
  var prefsWatcher: DispatchSourceFileSystemObject?
  var iconTheme = Daemon.iconTheme()
  let work = DispatchQueue(label: "accent")
  let corners: Corners
  let tooltips = Tooltips()
  let menu = Menu()
  let sidecar = SidecarReconnect()

  /// cornerRadius: bottom corners of the built-in display (0 = off), see Corners
  init(cornerRadius: CGFloat) { corners = Corners(radius: cornerRadius) }

  // Hover regions of the bar, written by lua: "strip <height>" then
  // "<name> <left|right> <d0> <d1> [display]" — [d0, d1) measured from that
  // edge of the screen under the cursor; only on that CGDirectDisplayID when
  // given, else on every display.
  // Fixed-size items can't tell which island the cursor is over, so the daemon
  // does, and fires `bar_hover REGION=<name>` only when the region changes.
  let regionsPath = NSHomeDirectory() + "/.local/state/sketchybar/regions"
  var regions: [(name: String, fromRight: Bool, d0: CGFloat, d1: CGFloat, display: String?)] = []
  var strip: CGFloat = 32
  var regionsStamp: Date?
  var hovered = ""
  var hoveredDisplay = ""

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
        regions.append((String(f[0]), f[1] == "right", CGFloat(a), CGFloat(b), f.count >= 5 ? String(f[4]) : nil))
      }
    }
  }

  func checkHover() {
    let p = NSEvent.mouseLocation
    var name = "", display = ""
    if let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
       screen.frame.maxY - p.y <= strip {
      display = String(displayID(screen))
      loadRegions()
      let fromLeft = p.x - screen.frame.minX, fromRight = screen.frame.maxX - p.x
      name = regions.first {
        let d = $0.fromRight ? fromRight : fromLeft
        return ($0.display == nil || $0.display == display) && d >= $0.d0 && d < $0.d1
      }?.name ?? ""
    }
    if name == "" { display = "" }
    tooltips.update(region: name, display: display)
    guard name != hovered || display != hoveredDisplay else { return }
    hovered = name
    hoveredDisplay = display
    // DISPLAY: CGDirectDisplayID of the screen under the cursor ("" = none)
    triggerAsync("bar_hover", ["REGION": name, "DISPLAY": display])
  }

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
    ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
      self.scheduleAccent()
      self.corners.refresh()
    }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
      self.scheduleAccent(delay: 2)
      self.schedulePhase()
      self.scheduleMinute()
      triggerAsync("minute_change", [:])
    }
    NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
      self.scheduleMinute()
      self.schedulePhase()
      triggerAsync("minute_change", [:])
    }
    ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in self.scheduleAccent(delay: 2) }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
      self.scheduleAccent()
      self.corners.update()
      self.menu.hide()
    }
    corners.update()
    sidecar.watch()
    watchWallpaperStore()
    watchIconTheme()
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in self.checkHover() }
    // clicks in the menu go to its own window; a global one is always elsewhere
    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in
      if e.type == .rightMouseDown, let d = barDisplay(e) { self.menu.toggle(on: d) } else { self.menu.hide() }
    }
    // another app coming forward (cmd-N) closes the menu — except right after a
    // click in it: on another display aerospace focuses that display on click
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
      if Date().timeIntervalSince(self.menu.clicked) > 1 { self.menu.hide() }
    }
    // light/dark wallpaper variants follow the appearance
    dnc.addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
      self.scheduleAccent(delay: 2)
    }
    NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
      self.schedulePhase()
    }
    schedulePhase()
    emitLayout()
    scheduleMinute()
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
    src.setEventHandler {
      self.scheduleAccent(delay: 2, force: true)
      self.schedulePhase()
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    watcher = src
  }

  var phaseTimer: Timer?

  /// The accent is sampled on events only (wallpaper / space / display change,
  /// wake); a dynamic wallpaper also switches frames by itself, at times known
  /// from its schedule: re-sample a minute after the next switch. Without a
  /// configured location the sun is placed at the time zone's reference city and
  /// the real switch can come half an hour later: look again 45 minutes later
  /// too (only a visible change is emitted).
  func schedulePhase() {
    work.async {
      let next = nextWallpaperPhase()
      DispatchQueue.main.async {
        self.phaseTimer?.invalidate()
        self.phaseTimer = nil
        guard let next else { return }
        let t = Timer(fire: next.addingTimeInterval(60), interval: 0, repeats: false) { _ in
          self.scheduleAccent(delay: 0)
          if sunLocation == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 45 * 60) { self.scheduleAccent(delay: 0) }
          }
          self.schedulePhase()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        self.phaseTimer = t
      }
    }
  }

  /// System Settings → Appearance → Icons (default / dark / clear / tinted) only
  /// changes global preferences; AppKit's own notification doesn't reach other
  /// processes. The bar's app icons are baked into cached images, so tell lua.
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
      triggerAsync("icon_theme_change", ["THEME": t])
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    prefsWatcher = src
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
  // daemon <corner radius> [LAT LON]
  sunLocation = parseLocation(args.dropFirst(2))
  Daemon(cornerRadius: CGFloat(args.count > 1 ? Double(args[1]) ?? 0 : 0)).run()
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
case "phase":
  sunLocation = parseLocation(args.dropFirst())
  if let frame = dynamicWallpaper()?.frame {
    print(frame(Date()), nextWallpaperPhase().map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime]) } ?? "-")
  }
case "render": renderJobs(args.count > 1 ? args[1] : "[]")
case "cursor":
  // x on the screen under the cursor, that screen's width and CGDirectDisplayID
  let c = cursorOnScreen()
  print(Int(c.x), Int(c.width), c.display)
case "layout": if args.count > 1, args[1] == "next" { nextLayout() } else { print(layoutCode()) }
case "geometry":
  // the main screen (menu bar) — other displays don't affect the geometry
  let s = NSScreen.screens.first!
  let w = s.frame.width
  let l = s.auxiliaryTopLeftArea?.width ?? w / 2
  let r = s.auxiliaryTopRightArea?.width ?? w / 2
  print(Int(w), Int(l), Int(r), backing)
case "screens":
  // NSScreen index, CGDirectDisplayID, width, width left of the notch (0 = none), menu bar height, kind
  let menuBars = menuBarHeights()
  for (i, s) in NSScreen.screens.enumerated() {
    print(i + 1, displayID(s), Int(s.frame.width), Int(s.auxiliaryTopLeftArea?.width ?? 0), menuBars[displayID(s)] ?? 0,
          displayKind(displayID(s)))
  }
case "pick": Picker().run(args.count > 1 ? args[1] : "0xff8ec8ff")
case "sleep": SidecarSleep().run()
default:
  FileHandle.standardError.write("usage: barhelper daemon|shape|icon|battery|measure|accent|phase|layout|geometry|screens|render|cursor|pick|sleep\n".data(using: .utf8)!)
  exit(1)
}
