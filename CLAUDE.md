# Desktop setup: glass bar (sketchybar logic) + AeroSpace

Context file for new sessions. Keep it short; update "Status" and "TODO" as work progresses.
The user speaks Russian; answer in Russian. Details of every change are in `git log` of the three repos.

## Repos (each its own git repo)
- `~/.config/sketchybar` — bar logic (Lua via SbarLua) + native helper `helper/{main,bar}.swift` (`make -C helper`);
  the helper daemon DRAWS the bar (`bar.swift`, SwiftUI Liquid Glass)
- `~/.config/borders` — JankyBorders patches; NOT started any more (removed 2026-09-28 with the accent)
- `~/.config/aerospace` — `aerospace.toml`, `patches/{switch-flicker,monitors,queries}.patch`,
  `patches/build.sh [--install|--restore]` (source in `~/.cache/aerospace-src`, builds offline)
- `~/.config` is also a repo with NO commits and secrets staged (`github-copilot/auth.db`) — don't commit it.

## Hard constraints (found the hard way, don't re-derive)
- The bar is the helper daemon's windows (`helper/bar.swift`), one NSPanel per display at the
  backstopMenu level (-20, like sketchybar's; the auto-hidden menu bar covers it), no
  fullScreenAuxiliary (not on fullscreen Spaces). Real Liquid Glass (SwiftUI `glassEffect`) refracts
  what is behind the window → can't be baked into images; sketchybar's bar is `hidden=on`, it only
  delivers events. Lua writes the whole state to `~/.local/state/sketchybar/bar.json` (`lib/bar.lua`,
  atomic, only on change); the daemon watches the dir (kqueue) — no process per update. One state
  change = one SwiftUI transaction per window (islands, lens, text together).
- Old sketchybar limits that forced one-image items, the hover-regions file, `barhelper cursor`,
  prerendering and the geometry reload are gone with it. The mach-queue deadlock still means: don't
  add per-item mouse events to sketchybar items (the daemon handles mouse itself).
- Mouse in daemon windows (app policy .prohibited, never key): tracking areas must be activeAlways,
  acceptsFirstMouse; hit testing uses frames the SwiftUI layout reports (HitKey), not SwiftUI
  gestures. Fully transparent pixels let clicks through to the desktop → the strip has a 0.002-alpha
  background (right click anywhere on the strip opens the theme menu).
- Glass looks "active" (harder blur + brightening layer, bright rims) only in a key window; the bar's
  panels must never be key (a key nonactivating panel takes the keyboard — verified). Public knobs
  (appearsActive, controlActiveState, canBecomeKey, isKeyWindow override, system glass tint) don't
  help; Apple forum thread 818901 unanswered. → `ActivePanel` overrides the private
  `_hasActiveAppearance` → YES (user approved the private override 2026-09-28). becomesKeyOnlyIfNeeded
  also forces the dull look.
- Lens (selected workspace): glass whose frame animates must be `.interactive()` — a plain glass
  effect re-animates from its old place once the frame animation ends (lens snapped back, ran again).
- Apple gives no public "selection lens" (the iOS Photos segmented lens): macOS segmented controls
  just jump. `glassEffectID` morph between two positions = cross-fade. Glass drips (GlassEffectContainer
  + glassEffectID) only for elements inserted next to each other; a menu under an island materializes.
  User rejected hand-made morphs/drips ("as if you wrote it yourself") → system `.bouncy`, no custom.
- Multi-display: Lua publishes one entry per display (`lib/displays.lua` from `barhelper screens`:
  NSScreen index = AeroSpace monitor id, CGDirectDisplayID, menu bar height, kind); the daemon adds/
  removes windows live and re-places them on didChangeScreenParameters. No reloads.
- AeroSpace: a hidden workspace remembers its monitor by the monitor's top-left point
  (`assignedMonitorPoint`); a missing monitor maps to the nearest one → reconnect returns them natively.
  BUT Sidecar disconnect makes its windows "die" briefly → AeroSpace's closed-windows cache
  (`closedWindowsCache.swift`) snapshots the world with approximated monitors and restores it → iPad
  workspaces got re-homed to main. monitors.patch stores/restores the home point instead.
  Also: showing a workspace re-homes it — so while its home monitor is disconnected, monitors.patch
  does NOT re-home it (user switches to 4/5 on main while iPad is off; they must still go back);
  a monitor that merely moved takes its workspaces along (rearrange remaps old point → new).
  Explicit moves (move-workspace-to-monitor, summon from another monitor) always re-home, even
  while the old home is missing (else a moved ex-iPad ws fell back to main once hidden).
  A workspace still SHOWN on main when its monitor returns must not stay there (showing it on a present
  monitor re-homes it): rearrange skips it, its monitor's stub picks it up. Happens after sleep: with no
  displays AeroSpace rearranges everything, main can come back showing the iPad's workspace.
- F6 (Karabiner `fn_function_keys`) → `barhelper sleep`: ends Sidecar sessions (private SidecarCore
  `SidecarDisplayManager`, else the iPad stays lit), sleeps (reconnects itself only if sleep fails).
  Reconnect after wake + unlock lives in the daemon (`SidecarReconnect`), so it also covers lid close /
  idle sleep: iPads connected at willSleep + ones lost in the 30s before it (the lid may drop the iPad
  first). The list lives in `~/.local/state/sketchybar/sidecar-reconnect`, so a restarted daemon
  (sketchybar reload) picks it up. Log: `~/.local/state/sketchybar/sleep.log`.
- AeroSpace moves windows via AX, per app, async; no atomic switch possible without SIP. Patches reorder/wait.
- AeroSpace forgets window→workspace on restart; `build.sh --install` snapshots and restores it.
- AeroSpace build is signed with local cert `aerospace-local-codesign` (login keychain) so the Accessibility
  grant survives rebuilds. Build uses Command Line Tools (Xcode license not accepted).
- Popups (theme menu, battery tooltip) are daemon glass panels at popUpMenu level on the display
  under the mouse (a sketchybar popup only showed on the focused display). Menu: text weight only
  (no accent), `menu_select ID=weight.X` → Lua → style republished → menu updates in place, stays
  open; closes on a click elsewhere / app activation (ignored right after a menu click: AeroSpace
  focuses the clicked display).
- SbarLua ignores SIGCHLD except around its `os.execute` (default for system()): a `sbar.exec` child
  exiting then stays a zombie, and with a zombie `io.popen`'s pclose can hang forever (XNU wait4) →
  the whole bar froze. → No `os.execute` after `require("sketchybar")` (use `lib/sh.lua` at startup),
  nothing blocking in event handlers (`sbar.exec` with a callback).
- `sketchybarrc` runs `pkill -f 'barhelper daemon'`: never put that literal string in your own shell
  command during a reload (it kills your shell) — use `pgrep -f 'barhelpe[r] daemon'`.

## Design
- One gap G = 6 (`config.lua` `bar.gap`): screen edge → island → window → window → edge, and between
  islands. Bar h 32 = notch strip. Per display strip = min(32, its menu bar height) (`barhelper screens`
  col 5, from WindowServer's menu bar windows, listed even when auto-hidden: built-in 33, iPad 30), so
  the auto-hidden menu bar covers the islands. Islands hang G from the top, end flush with the strip.
  The Mac is the reference: on a shorter strip the islands are the SAME islands scaled as a whole
  (`config.strip(strip).scale` = (strip−G)/(32−G); the daemon multiplies every size by it),
  gap between islands kept at G on screen. Windows start at 38 built-in / 36 others (outer.top built-in 6 / others
  36), outer.bottom 5 (AeroSpace lays out 1pt short). aerospace.toml gaps must be changed by hand.
  The user tried: G=10 (islands too thin, gap under bar too big), counting the border into the gap
  (rejected) — keep gaps measured from the window.
- Islands: regular Liquid Glass, no tint, continuous corners r = h/3.056; lens h−6, concentric (inset 3).
  Picked in prototypes side by side (2026-09-28): user wants "the cleanest, default Apple look".
  Lens = light glass (regular, 30% white tint; the clear one got lost on dark wallpapers) on the
  focused display, regular glass on the others. Moves on the default `.bouncy` (user picked it; slower custom
  springs rejected), clamped to the island. Hover: `.primary` fill 18% (10% was barely visible).
  No accent anywhere; no active-window border. Text/icons: system label colors (glass adapts).
- Built-in display bottom corners are masked to match the physical top ones: helper daemon `Corners`
  (`barhelper daemon <radius>`, `config.lua` `screen_corner`, user-tuned 21): Apple continuous corner,
  rendered once into static layer contents (no redraws), hidden on a native fullscreen Space
  (`CGSCopyManagedDisplaySpaces` type 4), `sharingType = .none` (not in screenshots — to check it
  visually, build a copy with `.readOnly`).
- App icons follow the system icon theme (`AppleIconAppearanceTheme`/`…TintColor`): the daemon
  watches `~/Library/Preferences` and re-reads icons (clears its icon cache).
  Lag 5–10s = cfprefsd flushing .GlobalPreferences.plist; user accepted it (no polling). AppKit's
  `NSWorkspaceIconAppearanceConfigurationDidChangeNotification` didn't reach a test process.
- Text: SF Pro Text. Weight picked in the menu
  (Regular/Medium/Semibold = primary text, secondary one step lighter; `config.font.weights`),
  saved in the theme state. User found Semibold too heavy → Medium. Date = time weight (user). Battery
  level: primary weight, `config.font.battery` 10pt, knocked out of a solid body (charged part opaque,
  rest 0.4) like macOS — readable wherever the fill edge falls; drawn as a template image (tinted like
  text), red when low. Battery tooltip wording = macOS menu.
- Clock: the daemon fires `minute_change` on every minute boundary (one timer, re-aligned on wake /
  clock change) → Lua → bar.json. The 60s routine (battery) is the clock's fallback.

## How to verify visually (Screen Recording is granted to WezTerm)
- `screencapture -x -R x,y,w,h out.png` / `-v -V secs out.mov`; ffmpeg `-fps_mode passthrough` → frames;
  diff frames with PIL/numpy (venv with pillow+numpy was in the session scratchpad; recreate if needed).
- Window order/position probe: `CGWindowListCopyWindowInfo` polled every 2–5ms (small Swift script).
- Real mouse moves / clicks for hover and click tests: post `CGEvent`s (small Swift scripts).
- The glass look depends on what is behind: judge it over the wallpaper (the real bar's backdrop),
  not over windows (over a dark terminal it just looks transparent).

## Status (2026-09-28)
Glass bar (daemon-drawn) committed and running; borders removed. Next (user-agreed): once it has
settled, consider moving the logic out of Lua/sketchybar into the daemon (AeroSpace server socket,
IOKit battery) — fewer hops, no mach queue / SbarLua pitfalls. User chose the simple Lua path first.

Earlier: Done and committed: bar rewrite, whole-island rendering, hover (workspaces + battery tooltip), themes,
borders focus patch, AeroSpace flicker patch (+ race fix, bottom-up hide, layout restore, signing),
bug-review fixes (15 items), multi-display basics (clicks/hover per screen, widths fit narrowest screen,
reload only on real geometry change), multi-monitor spec below (2026-09-26, verified by the user:
iPad disconnect/reconnect returns its workspaces, no bar reload, cross-monitor switches instant).

Open issues:
- Second display: lower accordion window flashes on switch again. Planned fix (not implemented):
  replace timeouts with confirmed ordering — per monitor only; place + confirm the top window before
  revealing lower accordion windows; hide old windows top-down only after the ones below are gone;
  timeouts only as ~1s liveness fallback; no waits for non-overlapping (tiles) layouts.
- summon-workspace from an EMPTY workspace on another monitor once landed on the main monitor (focus
  snapped back to an app window there — AeroSpace native-focus race); not reproduced on retry.

## Multi-monitor spec (agreed with user 2026-09-25, implemented + committed 2026-09-26)
Generic: no hardcoded monitor names/sizes; everything from the live monitor list. Typical use: iPad
(Sidecar) as auxiliary screen for Zoom/Telegram. Base = AeroSpace default global pool (workspaces 1–10
each live on some monitor), plus:
- cmd-N: focus workspace N on the monitor where it lives (focus/cursor go there; windows never jump).
  N doesn't exist yet (or is hidden and empty) → it opens on the MAIN monitor: `monitors.patch` makes a
  hidden empty workspace belong to main (and a reconnected monitor show what it showed before).
- cmd-alt-N: `summon-workspace N` to the focused monitor. The monitor it left shows another of its own
  (non-empty) workspaces, else a fresh stub (11, 12… — 1–10 are persistent via bindings).
- cmd-shift-N: move window to workspace N wherever it lives; focus stays.
- cmd-shift-h/l: move the WHOLE focused workspace to the next/prev monitor (keeps its number; user
  rejected moving just the window into the other monitor's shown ws). Focus and cursor stay on this
  monitor (binding = move-workspace-to-monitor + focus-monitor back), which shows another of its own.
- Cursor: `move-mouse monitor-lazy-center` on monitor focus change, run via exec-and-forget so it is
  evaluated after the whole binding (a sync callback fires per command → cursor jumped on cmd-shift-h/l).
- Disconnect: the monitor's workspaces move to main. Reconnect: they return, even if the user showed
  them on main meanwhile (monitors.patch; see constraints). `build.sh --install` also snapshots
  and restores ws → monitor across the AeroSpace restart.
- Bar: one bar per monitor, EVERY bar shows ALL existing workspaces (occupied + visible anywhere), so
  the user never has to look around for a workspace; workspaces living on another monitor carry that
  monitor's device glyph (SF Symbol: laptopcomputer / ipad.landscape / display, from `barhelper screens`
  col 6: CGDisplayIsBuiltin, Sidecar = vendor 'aapl' model 'iPad' FourCCs) between digit and icons,
  same numeric order, no separate group, no pill even if visible there. Tried: dimming the whole
  workspace to 40% (user: looks bad, meaning unclear — dimming reads as "disabled"); a superscript
  badge (fine, user picked the slot). Right side (status) identical on every monitor.
  Focused-monitor indicator: clear lens on the focused monitor, regular (subdued) on the others; the
  dashed outline of the focused ws on other bars was dropped with the glass redesign (Apple has none).
  Bar clicks behave like cmd-N.

## TODO (user, for 2026-09-26)
1. (done 2026-09-26) F6 doesn't turn off the second monitor.
2. (done 2026-09-28) Battery glyph: digits unreadable where the fill edge crosses them → macOS style.
3. (done 2026-09-26) Performance review + 4. bug test (multi-monitor spec, sleep/Sidecar) — both
   report-only. Findings + agreed fix order with checkboxes: `docs/review-2026-09-26.md` (evidence
   and probe tools in `~/.local/state/sketchybar/review-2026-09-26/`). Step 1 (sleep/iPad: B1–B4) done,
   awaiting the user's F6 / lid test. NEXT: step 2; tick checkboxes there as items land.
