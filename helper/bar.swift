// The bar itself: the daemon's own windows, one per display, drawn with
// SwiftUI's Liquid Glass (real NSGlassEffectView underneath — it refracts
// what is behind the window, so it can't be baked into an image).
//
// Lua keeps the logic and writes the whole state to
// ~/.local/state/sketchybar/bar.json (atomically); the daemon watches the
// directory (kqueue, no process per update) and redraws. A state change lands
// in one SwiftUI transaction per window: islands, lens and text move together.
// Clicks, hover, the theme menu and the battery tooltip are handled here.

import AppKit
import SwiftUI

let barStatePath = NSHomeDirectory() + "/.local/state/sketchybar/bar.json"
let aerospaceBin = "/opt/homebrew/bin/aerospace"

// MARK: - State (bar.json)

/// Geometry and type, in the bar's units (config.lua); scaled per display.
struct BarStyle: Equatable {
  var gap: CGFloat = 6, bar: CGFloat = 32
  var pillH: CGFloat = 20, inset: CGFloat = 3
  /// Corner radius of the islands and the tooltip (the menu slider, 0...cornerMax); each
  /// shape takes min(corner, its height / 2), inner pills concentric
  var corner: CGFloat = 8.5, cornerMax: CGFloat = 21
  var family = "SF Pro Text", size: CGFloat = 12.5, battery: CGFloat = 10
  var primary = "Regular", secondary = "Light"
  var popupH: CGFloat = 34, popupR: CGFloat = 12, popupOffset: CGFloat = 7 // popupR: the menu's (system)
  var weights = ["Regular", "Medium", "Semibold"]

  var island: CGFloat { bar - gap }
  var radius: CGFloat { min(corner, island / 2) }
  var pillR: CGFloat { max(0, radius - inset) }
}

struct SpaceItem: Equatable, Identifiable {
  let n: Int
  let apps: [String]
  let shown: Bool      // this display shows it: the lens
  let device: String?  // lives on another display: that display's SF Symbol
  var id: Int { n }
}

struct DisplayState: Equatable {
  let did: CGDirectDisplayID
  let strip: CGFloat   // min(bar, the display's menu bar height)
  let focused: Bool    // the focused display: a clear lens, else a subdued one
  let spaces: [SpaceItem]
}

struct BatteryState: Equatable {
  let level: Int, charge: Int, low: Bool
  let status: String
}

struct StatusState: Equatable {
  var input = "EN", date = "", time = ""
  var battery: BatteryState?
}

struct BarState: Equatable {
  var hidden = false // cmd-shift-b
  var style = BarStyle()
  var displays: [DisplayState] = []
  var status = StatusState()
}

private func cg(_ d: [String: Any], _ k: String, _ def: CGFloat) -> CGFloat {
  (d[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? def
}

func parseBarState(_ data: Data) -> BarState? {
  guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
  var s = BarState()
  s.hidden = j["hidden"] as? Bool ?? false
  if let st = j["style"] as? [String: Any] {
    var y = BarStyle()
    y.gap = cg(st, "gap", y.gap); y.bar = cg(st, "bar", y.bar)
    y.pillH = cg(st, "pill_h", y.pillH); y.inset = cg(st, "inset", y.inset)
    y.corner = cg(st, "corner", y.corner); y.cornerMax = cg(st, "corner_max", y.cornerMax)
    y.family = st["family"] as? String ?? y.family
    y.size = cg(st, "size", y.size); y.battery = cg(st, "battery", y.battery)
    y.primary = st["primary"] as? String ?? y.primary
    y.secondary = st["secondary"] as? String ?? y.secondary
    y.popupH = cg(st, "popup_h", y.popupH); y.popupR = cg(st, "popup_r", y.popupR)
    y.popupOffset = cg(st, "popup_offset", y.popupOffset)
    y.weights = st["weights"] as? [String] ?? y.weights
    s.style = y
  }
  for d in j["displays"] as? [[String: Any]] ?? [] {
    guard let did = (d["did"] as? NSNumber)?.uint32Value else { continue }
    let spaces = (d["spaces"] as? [[String: Any]] ?? []).compactMap { w -> SpaceItem? in
      guard let n = (w["n"] as? NSNumber)?.intValue else { return nil }
      return SpaceItem(n: n, apps: w["apps"] as? [String] ?? [], shown: w["shown"] as? Bool ?? false,
                       device: w["device"] as? String)
    }
    s.displays.append(DisplayState(did: did, strip: cg(d, "strip", 32), focused: d["focused"] as? Bool ?? false,
                                   spaces: spaces))
  }
  if let st = j["status"] as? [String: Any] {
    s.status.input = st["input"] as? String ?? "EN"
    s.status.date = st["date"] as? String ?? ""
    s.status.time = st["time"] as? String ?? ""
    if let b = st["battery"] as? [String: Any] {
      s.status.battery = BatteryState(level: (b["level"] as? NSNumber)?.intValue ?? 100,
                                      charge: (b["charge"] as? NSNumber)?.intValue ?? 0,
                                      low: b["low"] as? Bool ?? false, status: b["status"] as? String ?? "")
    }
  }
  return s
}

// MARK: - Model

/// One display's bar. Hit rects are kept out of @Published: they are reported
/// by the layout itself, and republishing them would re-render in a loop.
final class BarModel: ObservableObject {
  let did: CGDirectDisplayID
  @Published var style = BarStyle()
  @Published var display: DisplayState
  @Published var status = StatusState()
  @Published var hover: Int?
  /// bumped when app icons change (system icon theme)
  @Published var iconEpoch = 0
  var hits: [String: CGRect] = [:] // "ws.N" | "input" | "battery" | "clock", view points from the top-left

  init(_ d: DisplayState) {
    did = d.did
    display = d
  }

  /// The strip is the same islands scaled as a whole; gaps between islands stay `gap`.
  var scale: CGFloat { max(0.5, (display.strip - style.gap) / style.island) }

  func font(_ primary: Bool, _ size: CGFloat? = nil) -> Font {
    Font(helper_font(style.family, primary ? style.primary : style.secondary, (size ?? style.size) * scale) as CTFont)
  }
}

// main.swift's font(): named apart so the SwiftUI `font` modifier isn't shadowed
func helper_font(_ family: String, _ style: String, _ size: CGFloat) -> NSFont { font(family, style, size) }

struct HitKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  /// Reports this view's frame in the bar's coordinates under `key`.
  func hit(_ key: String) -> some View {
    background(GeometryReader { g in Color.clear.preference(key: HitKey.self, value: [key: g.frame(in: .named("bar"))]) })
  }
}

// MARK: - Views

struct SpaceCell: View {
  let w: SpaceItem
  @ObservedObject var m: BarModel

  var body: some View {
    let s = m.scale
    let icon: CGFloat = (m.style.island - 8) * s, slot = icon + 2 * s
    let shown = Array(w.apps.prefix(w.apps.count > 8 ? 7 : 8))
    let overflow = w.apps.count - shown.count
    HStack(spacing: 0) {
      Text("\(w.n)").font(m.font(true))
        .foregroundStyle(w.shown ? .primary : .secondary)
      if let d = w.device {
        Image(systemName: d).font(.system(size: 12 * s, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 16 * s)
          .padding(.leading, 3 * s)
          .padding(.trailing, (w.apps.isEmpty ? 0 : 2) * s)
      }
      if !w.apps.isEmpty { Spacer().frame(width: 3 * s) }
      ForEach(shown, id: \.self) { a in
        Image(nsImage: appIcon(a)).resizable().interpolation(.high)
          .frame(width: icon, height: icon).frame(width: slot)
      }
      if overflow > 0 {
        Text("+\(overflow)").font(m.font(false, m.style.size - 1.5)).foregroundStyle(.secondary).frame(width: slot)
      }
    }
    .padding(.leading, 7 * s)
    // icons carry ~1.5pt of built-in margin, so 5 reads as 7
    .padding(.trailing, (w.apps.isEmpty ? 7 : 5) * s)
    .frame(height: m.style.pillH * s)
    .id("\(w.n).\(m.iconEpoch)")
  }
}

/// The lens: its edges animate on the default .bouncy spring, clamped to the
/// island so an overshoot squashes it against the edge instead of leaving it.
struct LensFrame: ViewModifier, Animatable {
  var lo: CGFloat, hi: CGFloat
  let maxX: CGFloat, height: CGFloat
  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { .init(lo, hi) }
    set { lo = newValue.first; hi = newValue.second }
  }
  func body(content: Content) -> some View {
    let l = max(0, min(lo, maxX)), r = max(l, min(hi, maxX))
    return content.frame(width: r - l, height: height).offset(x: l)
  }
}

struct CellKey: PreferenceKey {
  static var defaultValue: [Int: CGRect] = [:]
  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}
struct WidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The selection: light glass, like the selected tab's platter in iOS 26.
let lensGlass = Glass.regular.tint(.white.opacity(0.3)).interactive()

struct SpacesIsland: View {
  @ObservedObject var m: BarModel
  @Namespace var ns
  @State var lo: CGFloat = 0
  @State var hi: CGFloat = 0
  @State var rowW: CGFloat = 0
  @State var cells: [Int: CGRect] = [:]

  var lensTarget: Int? { m.display.spaces.first { $0.shown }?.n }

  func moveLens(animated: Bool) {
    guard let n = lensTarget, let r = cells[n] else { return }
    if !animated || (lo == 0 && hi == 0) { lo = r.minX; hi = r.maxX; return }
    if r.minX != lo || r.maxX != hi { withAnimation(.bouncy) { lo = r.minX; hi = r.maxX } }
  }

  var body: some View {
    let s = m.scale, st = m.style
    let pill = RoundedRectangle(cornerRadius: st.pillR * s, style: .continuous)
    HStack(spacing: st.inset * s) {
      ForEach(m.display.spaces) { w in
        SpaceCell(w: w, m: m)
          .background {
            if w.n == m.hover && !w.shown {
              pill.fill(.primary.opacity(0.5)).matchedGeometryEffect(id: "hover", in: ns)
            }
          }
          .background(GeometryReader { g in
            Color.clear.preference(key: CellKey.self, value: [w.n: g.frame(in: .named("row"))])
          })
          .hit("ws.\(w.n)")
          .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }
    }
    .coordinateSpace(name: "row")
    .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
    .onPreferenceChange(WidthKey.self) { rowW = $0 }
    .onPreferenceChange(CellKey.self) { c in
      cells = c
      moveLens(animated: true)
    }
    .onChange(of: lensTarget) { moveLens(animated: true) }
    .background(alignment: .leading) {
      if lensTarget != nil {
        // light glass on the focused display, plain on the others. Interactive:
        // a plain glass effect re-animates from its old place once the frame
        // animation ends (the lens snapped back and ran again)
        Color.clear
          .glassEffect(m.display.focused ? lensGlass : .regular.interactive(), in: pill)
          .modifier(LensFrame(lo: lo, hi: hi, maxX: rowW, height: st.pillH * s))
      }
    }
    .padding(st.inset * s)
    .frame(height: st.island * s)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: st.radius * s, style: .continuous))
  }
}

var batteryCache: [String: NSImage] = [:]
/// The battery glyph (main.swift drawBattery) as an image; a template (tinted
/// like the text) unless low (red).
func batteryImage(_ b: BatteryState, style: String, size: CGFloat, scale s: CGFloat) -> NSImage {
  let key = "\(b.level)|\(b.charge)|\(b.low)|\(style)|\(size)|\(s)"
  if let i = batteryCache[key] { return i }
  let w = batteryWidth(b.charge), h = batteryHeight
  let img = NSImage(size: NSSize(width: w * s, height: h * s), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    ctx.scaleBy(x: s, y: s)
    let c = b.low ? NSColor.systemRed.cgColor : NSColor.black.cgColor
    drawBattery(ctx, at: .zero, level: b.level, state: b.charge, color: c, style: style, size: size)
    return true
  }
  img.isTemplate = !b.low
  if batteryCache.count > 200 { batteryCache.removeAll() }
  batteryCache[key] = img
  return img
}

struct StatusIslands: View {
  @ObservedObject var m: BarModel

  func chip<C: View>(_ key: String, @ViewBuilder _ c: () -> C) -> some View {
    let s = m.scale
    return c()
      .padding(.horizontal, 10 * s)
      .frame(height: m.style.island * s)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: m.style.radius * s, style: .continuous))
      .hit(key)
  }

  var body: some View {
    let s = m.scale
    HStack(spacing: m.style.gap) {
      chip("input") {
        Text(m.status.input).font(m.font(true)).foregroundStyle(.secondary)
          .frame(minWidth: 18 * s)
      }
      if let b = m.status.battery {
        chip("battery") {
          Image(nsImage: batteryImage(b, style: m.style.primary, size: m.style.battery, scale: s))
            .foregroundStyle(.primary)
        }
      }
      chip("clock") {
        HStack(spacing: 6 * s) {
          Text(m.status.date).font(m.font(true)).foregroundStyle(.secondary)
          Text(m.status.time).font(m.font(true)).monospacedDigit().foregroundStyle(.primary)
        }
      }
    }
  }
}

struct BarView: View {
  @ObservedObject var m: BarModel

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      SpacesIsland(m: m)
      Spacer(minLength: 0)
      StatusIslands(m: m)
    }
    .padding(.horizontal, m.style.gap)
    .padding(.top, m.style.gap)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // the whole strip takes the mouse (a right click anywhere opens the menu);
    // fully transparent pixels would let clicks through to the desktop
    .background(Color.black.opacity(0.002))
    .coordinateSpace(name: "bar")
    .onPreferenceChange(HitKey.self) { m.hits = $0 }
  }
}

// MARK: - Windows

/// Mouse handling for a daemon window: the daemon's app is never active, so
/// tracking must be activeAlways and the first click must count.
class TrackingHost<V: View>: NSHostingView<V> {
  var onMove: ((CGPoint?) -> Void)?
  var onClick: ((CGPoint, Bool) -> Void)? // point, right button
  var onPress: ((CGPoint) -> Void)?       // left button down (the click is on up)
  var onDrag: ((CGPoint) -> Void)?

  required init(rootView: V) { super.init(rootView: rootView) }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }
  /// top-left origin, like the SwiftUI layout
  func point(_ e: NSEvent) -> CGPoint {
    let p = convert(e.locationInWindow, from: nil)
    return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
  }
  override func mouseMoved(with e: NSEvent) { onMove?(point(e)) }
  override func mouseEntered(with e: NSEvent) { onMove?(point(e)) }
  override func mouseExited(with e: NSEvent) { onMove?(nil) }
  override func mouseDown(with e: NSEvent) { onPress?(point(e)) }
  override func mouseDragged(with e: NSEvent) { onDrag?(point(e)) }
  override func mouseUp(with e: NSEvent) { onClick?(point(e), false) }
  override func rightMouseDown(with e: NSEvent) { onClick?(point(e), true) }
}

/// Glass in a key window blurs harder and adds a brightening layer (the
/// "active" look); the daemon's windows never become key (that would take the
/// keyboard from the app in front), so they got the dull inactive look. No
/// public API covers this (Apple Developer Forums thread 818901, unanswered);
/// AppKit asks the window's private _hasActiveAppearance: say yes, like the
/// Dock. If it is ever renamed the bar just looks inactive again.
final class ActivePanel: NSPanel {
  @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }
}

func barPanel(level: NSWindow.Level) -> NSPanel {
  let p = ActivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  p.isOpaque = false
  p.backgroundColor = .clear
  p.hasShadow = false
  p.hidesOnDeactivate = false
  p.acceptsMouseMovedEvents = true
  p.level = level
  p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
  return p
}

func screen(_ did: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { displayID($0) == did } }

// MARK: - Popups

/// The theme menu: text weight, each in its own face (the selection is the
/// same lens as the workspaces', it slides to a new pick on the same spring;
/// hover slides too), and the corner radius slider. Stays open after a pick
/// (the new state re-renders it in place), closes on a click elsewhere.
final class MenuModel: ObservableObject {
  @Published var style = BarStyle()
  @Published var scale: CGFloat = 1
  @Published var hover: String?
  @Published var open = false // the glass is in (inserted / removed on .bouncy)
  var hits: [String: CGRect] = [:]
}

struct MenuView: View {
  @ObservedObject var m: MenuModel
  @Namespace var ns

  var pad: CGFloat { (m.style.popupH - 24) / 2 * m.scale }
  /// the system menu radius (not the slider's)
  var radius: CGFloat { m.style.popupR * m.scale }
  var pill: RoundedRectangle { RoundedRectangle(cornerRadius: max(0, radius - pad), style: .continuous) }

  /// live: false is the invisible copy that sizes the panel while the glass is out
  func row(_ kind: String, _ items: [String], _ selected: String, live: Bool,
           face: @escaping (String) -> String) -> some View {
    let s = m.scale, st = m.style, w = 84 * s, gap = 6 * s
    let i = items.firstIndex(of: selected)
    return HStack(spacing: gap) {
      ForEach(items, id: \.self) { item in
        let id = "\(kind).\(item)"
        Text(item).font(Font(helper_font(st.family, face(item), st.size * s) as CTFont))
          .foregroundStyle(item == selected ? .primary : .secondary)
          .frame(width: w, height: 24 * s)
          .background {
            if live && id == m.hover && item != selected {
              pill.fill(.primary.opacity(0.18)).matchedGeometryEffect(id: "hover", in: ns)
            }
          }
          .hit(live ? id : "")
      }
    }
    .background(alignment: .leading) {
      // the bar's lens: interactive glass, its frame animated on .bouncy
      if live, let i {
        let lo = CGFloat(i) * (w + gap)
        Color.clear.glassEffect(lensGlass, in: pill)
          .modifier(LensFrame(lo: lo, hi: lo + w, maxX: .infinity, height: 24 * s))
          .animation(.bouncy, value: i)
      }
    }
  }

  /// The system slider, drawn only: the daemon's windows take the mouse
  /// themselves (GlassMenu.drag); its frame is the "corner" hit.
  func slider(live: Bool) -> some View {
    let s = m.scale, st = m.style
    return HStack(spacing: 8 * s) {
      Image(systemName: "square").foregroundStyle(.secondary)
      Slider(value: .constant(Double(st.corner)), in: 0...Double(max(st.cornerMax, 1)))
        .tint(.secondary)
        .allowsHitTesting(false)
        .hit(live ? "corner" : "")
      Image(systemName: "capsule").foregroundStyle(.secondary)
    }
    .font(.system(size: st.size * s))
    .padding(.horizontal, 8 * s)
    .frame(width: (84 * 3 + 6 * 2) * s, height: 24 * s)
  }

  func rows(live: Bool) -> some View {
    let st = m.style
    return VStack(alignment: .leading, spacing: 6 * m.scale) {
      row("weight", st.weights, st.primary, live: live) { $0 }
      slider(live: live)
    }
    .padding(pad)
  }

  var body: some View {
    // Like the prototype: the menu is glass inserted into a container, so it
    // materializes (and dematerializes) the system way, not a window fade.
    ZStack {
      rows(live: false).hidden()
      GlassEffectContainer {
        if m.open {
          rows(live: true)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEffectTransition(.materialize)
        }
      }
    }
    .padding(popupMargin)
    .coordinateSpace(name: "bar")
    .onPreferenceChange(HitKey.self) { m.hits = $0.filter { !$0.key.isEmpty } }
  }
}

/// Transparent room around a popup: (de)materializing glass blurs past its
/// shape, and the panel's edge cut it off (a hard edge on the left). Fully
/// transparent pixels let clicks through.
let popupMargin: CGFloat = 20

/// Width of the system slider's knob (measured on macOS 26).
let sliderKnob: CGFloat = 22

/// Inserts / removes a popup's glass on .bouncy; the panel stays ordered in
/// until the glass is gone.
func popupGlass(_ open: Bool, set: @escaping (Bool) -> Void, removed: @escaping () -> Void) {
  if open { withAnimation(.bouncy) { set(true) }; return }
  withAnimation(.bouncy, completionCriteria: .removed) { set(false) } completion: { removed() }
}

final class GlassMenu {
  let model = MenuModel()
  lazy var host: TrackingHost<MenuView> = {
    let h = TrackingHost(rootView: MenuView(m: model))
    h.onMove = { [weak self] p in self?.hover(p) }
    h.onClick = { [weak self] p, right in if !right { self?.click(p) } }
    h.onPress = { [weak self] p in self?.press(p) }
    h.onDrag = { [weak self] p in self?.drag(p) }
    return h
  }()
  lazy var panel: NSPanel = {
    let p = barPanel(level: .popUpMenu)
    p.contentView = host
    return p
  }()
  var shownOn: CGDirectDisplayID = 0
  var clicked = Date.distantPast
  var isOpen: Bool { shownOn != 0 }
  /// the slider is being dragged; every value is shown at once (GlassBar
  /// previews it on all displays), Lua gets the last one on release
  var dragging = false
  var onPreview: ((CGFloat) -> Void)?

  func place(on sc: NSScreen, style: BarStyle, strip: CGFloat) {
    model.style = style
    model.scale = max(0.5, (strip - style.gap) / style.island)
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    let f = sc.frame
    // right edge at the islands', top popupOffset below them (the strip's bottom)
    let m = popupMargin
    panel.setFrame(NSRect(x: f.maxX - style.gap - size.width + m, y: f.maxY - strip - style.popupOffset - size.height + m,
                          width: size.width, height: size.height), display: true)
  }

  func show(on did: CGDirectDisplayID, style: BarStyle, strip: CGFloat) {
    guard let sc = screen(did) else { return }
    if model.open { model.open = false } // closing on another display: start over here
    place(on: sc, style: style, strip: strip)
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    shownOn = did
    // once the (empty) panel is on screen, so the insertion is seen
    DispatchQueue.main.async {
      guard self.shownOn == did else { return }
      popupGlass(true, set: { self.model.open = $0 }, removed: {})
    }
  }

  /// A new panel's first render takes longer than the animation (the menu
  /// popped in): draw it once, invisible, at start.
  func warm(style: BarStyle, strip: CGFloat) {
    guard !isOpen, let sc = NSScreen.screens.first else { return }
    place(on: sc, style: style, strip: strip)
    model.open = true
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard !self.isOpen else { return }
      self.model.open = false
      self.panel.orderOut(nil)
    }
  }

  func update(style: BarStyle) {
    guard isOpen, style != model.style else { return }
    model.style = style
  }

  func toggle(on did: CGDirectDisplayID, style: BarStyle, strip: CGFloat) {
    if shownOn == did { hide() } else { show(on: did, style: style, strip: strip) }
  }

  func hide() {
    guard isOpen else { return }
    shownOn = 0
    model.hover = nil
    popupGlass(false, set: { self.model.open = $0 }) {
      if !self.isOpen { self.panel.orderOut(nil) }
    }
  }

  func hit(_ p: CGPoint?) -> String? {
    guard let p, isOpen else { return nil }
    return model.hits.first { $0.value.contains(p) }?.key
  }

  func hover(_ p: CGPoint?) {
    let id = hit(p)
    if id != model.hover { withAnimation(.smooth(duration: 0.2)) { model.hover = id } }
  }

  func click(_ p: CGPoint) {
    if dragging {
      dragging = false
      clicked = Date()
      triggerAsync("menu_select", ["ID": "corner.\(model.style.corner)"])
      return
    }
    guard let id = hit(p), id != "corner" else { return }
    clicked = Date()
    triggerAsync("menu_select", ["ID": id])
  }

  func press(_ p: CGPoint) {
    guard hit(p) == "corner" else { return }
    dragging = true
    drag(p)
  }

  /// x → value along the slider's track (the knob's center travels between
  /// knob / 2 from each end)
  func drag(_ p: CGPoint) {
    guard dragging, let f = model.hits["corner"] else { return }
    clicked = Date()
    let knob = sliderKnob * model.scale, st = model.style
    let t = min(1, max(0, (p.x - f.minX - knob / 2) / max(1, f.width - knob)))
    let v = (t * st.cornerMax * 4).rounded() / 4
    guard v != st.corner else { return }
    model.style.corner = v
    onPreview?(v)
  }
}

/// The battery tooltip, centered under the battery island.
final class TipModel: ObservableObject {
  @Published var text = ""
  @Published var style = BarStyle()
  @Published var scale: CGFloat = 1
  @Published var open = false
}

struct TipView: View {
  @ObservedObject var m: TipModel

  var label: some View {
    let s = m.scale
    return Text(m.text).font(Font(helper_font(m.style.family, m.style.secondary, m.style.size * s) as CTFont))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10 * s)
      .frame(height: m.style.island * s)
  }

  var body: some View {
    // glass inserted into a container, like the menu (GlassMenu)
    ZStack {
      label.hidden()
      GlassEffectContainer {
        if m.open {
          label
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: m.style.radius * m.scale, style: .continuous))
            .glassEffectTransition(.materialize)
        }
      }
    }
    .fixedSize()
    .padding(popupMargin)
  }
}

final class GlassTip {
  let model = TipModel()
  lazy var host = NSHostingView(rootView: TipView(m: model))
  lazy var panel: NSPanel = {
    let p = barPanel(level: .popUpMenu)
    p.ignoresMouseEvents = true
    p.contentView = host
    return p
  }()
  var shownOn: CGDirectDisplayID = 0

  /// anchor: the battery island in screen coordinates (bottom-left origin)
  func show(_ text: String, on did: CGDirectDisplayID, under anchor: NSRect, style: BarStyle, scale: CGFloat) {
    guard !text.isEmpty else { hide(); return }
    model.text = text
    model.style = style
    model.scale = scale
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    let f = screen(did)?.frame ?? anchor
    let m = popupMargin, w = size.width - 2 * m
    let x = min(max(f.minX + style.gap, anchor.midX - w / 2), f.maxX - style.gap - w)
    panel.setFrame(NSRect(x: x - m, y: anchor.minY - style.popupOffset - size.height + m,
                          width: size.width, height: size.height), display: true)
    if shownOn == 0 {
      panel.alphaValue = 1
      panel.orderFrontRegardless()
      DispatchQueue.main.async {
        guard self.shownOn != 0 else { return }
        popupGlass(true, set: { self.model.open = $0 }, removed: {})
      }
    }
    shownOn = did
  }

  /// See GlassMenu.warm.
  func warm(style: BarStyle) {
    guard shownOn == 0, let sc = NSScreen.screens.first else { return }
    model.text = "100%"
    model.style = style
    model.open = true
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    panel.setFrame(NSRect(x: sc.frame.midX, y: sc.frame.maxY - style.bar - style.popupOffset - size.height,
                          width: size.width, height: size.height), display: true)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard self.shownOn == 0 else { return }
      self.model.open = false
      self.panel.orderOut(nil)
    }
  }

  func hide() {
    guard shownOn != 0 else { return }
    shownOn = 0
    popupGlass(false, set: { self.model.open = $0 }) {
      if self.shownOn == 0 { self.panel.orderOut(nil) }
    }
  }
}

// MARK: - Bar

final class GlassBar {
  var state = BarState()
  var models: [CGDirectDisplayID: BarModel] = [:]
  var panels: [CGDirectDisplayID: NSPanel] = [:]
  let menu = GlassMenu()
  let tip = GlassTip()
  var watcher: DispatchSourceFileSystemObject?
  var stamp: Date?
  var tipOn: CGDirectDisplayID = 0
  var warmed = false

  func start() {
    menu.onPreview = { [weak self] v in self?.preview(corner: v) }
    watch()
    reload()
  }

  /// The radius slider is being dragged: show the value everywhere at once
  /// (Lua gets it on release and republishes the same style).
  func preview(corner v: CGFloat) {
    for m in models.values where m.style.corner != v { m.style.corner = v }
  }

  func watch() {
    let dir = (barStatePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let fd = open(dir, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
    src.setEventHandler { [weak self] in self?.reload() }
    src.setCancelHandler { close(fd) }
    src.resume()
    watcher = src
  }

  func reload() {
    let st = (try? FileManager.default.attributesOfItem(atPath: barStatePath))?[.modificationDate] as? Date
    guard st != stamp || st == nil else { return }
    stamp = st
    guard let data = FileManager.default.contents(atPath: barStatePath), let s = parseBarState(data) else { return }
    apply(s)
  }

  /// Screens changed: re-place the windows (the state names displays by id).
  func screensChanged() {
    menu.hide()
    tip.hide()
    apply(state, force: true)
  }

  func apply(_ new: BarState, force: Bool = false) {
    var new = new
    if menu.dragging { new.style.corner = menu.model.style.corner } // the slider wins until released
    guard new != state || force else { return }
    let old = state
    state = new
    var seen = Set<CGDirectDisplayID>()
    for d in new.displays {
      guard let sc = screen(d.did) else { continue }
      seen.insert(d.did)
      let m: BarModel
      if let x = models[d.did] { m = x } else {
        m = BarModel(d)
        models[d.did] = m
        panels[d.did] = makePanel(m)
      }
      let p = panels[d.did]!
      let f = sc.frame
      let frame = NSRect(x: f.minX, y: f.maxY - d.strip, width: f.width, height: d.strip)
      if p.frame != frame { p.setFrame(frame, display: true) }
      let moved = old.displays.first { $0.did == d.did }?.spaces != d.spaces
      let update = {
        if m.style != new.style { m.style = new.style }
        if m.display != d { m.display = d }
        if m.status != new.status { m.status = new.status }
      }
      if moved { withAnimation(.bouncy, update) } else { update() }
      if new.hidden { p.orderOut(nil) } else if !p.isVisible { p.orderFrontRegardless() }
    }
    for (did, p) in panels where !seen.contains(did) {
      p.orderOut(nil)
      panels[did] = nil
      models[did] = nil
    }
    if new.hidden {
      menu.hide()
      tip.hide()
      tipOn = 0
    }
    menu.update(style: new.style)
    if !warmed, let d = new.displays.first {
      warmed = true
      menu.warm(style: new.style, strip: d.strip)
      tip.warm(style: new.style)
    }
    if tipOn != 0, let b = new.status.battery, tip.model.text != b.status { showTip(on: tipOn) }
  }

  func makePanel(_ m: BarModel) -> NSPanel {
    let p = barPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu))))
    let h = TrackingHost(rootView: BarView(m: m))
    let did = m.did
    h.onMove = { [weak self] pt in self?.hover(did, pt) }
    h.onClick = { [weak self] pt, right in self?.click(did, pt, right: right) }
    p.contentView = h
    return p
  }

  /// The workspace under a point: its cell widened by half the gap between cells.
  func workspace(_ m: BarModel, at p: CGPoint) -> Int? {
    let half = m.style.inset * m.scale / 2
    for (k, r) in m.hits where k.hasPrefix("ws.") {
      if r.insetBy(dx: -half, dy: -half).contains(p) { return Int(k.dropFirst(3)) }
    }
    return nil
  }

  func hover(_ did: CGDirectDisplayID, _ p: CGPoint?) {
    guard let m = models[did] else { return }
    let n = p.flatMap { workspace(m, at: $0) }
    if n != m.hover { withAnimation(.smooth(duration: 0.2)) { m.hover = n } }
    let onBattery = p.map { m.hits["battery"]?.contains($0) ?? false } ?? false
    if onBattery { showTip(on: did) } else if tipOn == did { tipOn = 0; tip.hide() }
  }

  func showTip(on did: CGDirectDisplayID) {
    guard let m = models[did], let b = m.status.battery, let r = m.hits["battery"], let p = panels[did] else { return }
    tipOn = did
    // the island's rect in screen coordinates
    let f = p.frame
    let anchor = NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    tip.show(b.status, on: did, under: anchor, style: m.style, scale: m.scale)
  }

  func click(_ did: CGDirectDisplayID, _ p: CGPoint, right: Bool) {
    guard let m = models[did] else { return }
    if right {
      menu.toggle(on: did, style: m.style, strip: m.display.strip)
      return
    }
    menu.hide()
    if let n = workspace(m, at: p) {
      if !(m.display.focused && m.display.spaces.first(where: { $0.n == n })?.shown == true) {
        run(aerospaceBin, ["workspace", "\(n)"])
      }
    } else if m.hits["input"]?.contains(p) == true {
      nextLayout()
    } else if m.hits["clock"]?.contains(p) == true {
      run("/usr/bin/open", ["-a", "Calendar"])
    }
  }

  /// System icon theme changed: icons are re-read from NSWorkspace.
  func iconsChanged() {
    iconCache.removeAll()
    for m in models.values { m.iconEpoch += 1 }
  }

  func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
  }
}

