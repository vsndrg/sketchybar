# Desktop setup: sketchybar + AeroSpace + JankyBorders

Context file for new sessions. Keep it short; update "Status" and "TODO" as work progresses.
The user speaks Russian; answer in Russian. Details of every change are in `git log` of the three repos.

## Repos (each its own git repo)
- `~/.config/sketchybar` — bar (Lua via SbarLua) + native helper `helper/main.swift` (`make -C helper`)
- `~/.config/borders` — `bordersrc`, `patches/focus-latency.patch`, `build.sh` → `~/.local/bin/borders`
- `~/.config/aerospace` — `aerospace.toml`, `patches/{switch-flicker,monitors,queries}.patch`,
  `patches/build.sh [--install|--restore]` (source in `~/.cache/aerospace-src`, builds offline)
- `~/.config` is also a repo with NO commits and secrets staged (`github-copilot/auth.db`) — don't commit it.

## Hard constraints (found the hard way, don't re-derive)
- macOS 26+: sketchybar can't batch window updates (moves/resizes and content land in different frames).
  → Each bar side is ONE fixed-width item showing ONE image rendered by the helper (`render` subcommand).
  Never change item width/position on state changes; only swap the image.
- sketchybar → Lua events go over a tiny mach queue; per-item mouse.entered/exited on many items deadlocked
  the bar. → No per-item hover; the helper daemon tracks the cursor (global mouse monitor) against
  `~/.local/state/sketchybar/regions` (written via `lib/regions.lua`) and fires
  `bar_hover REGION=… DISPLAY=<CGDirectDisplayID>` on change.
- Clicks: `barhelper cursor` → "x_on_screen screen_width"; mapped to hit ranges from the renderer.
- Multi-display: one `spaces.<CGDirectDisplayID>` item per display (`display=` arrangement id), added/
  removed LIVE on display_change (user dislikes the visible bar reload). AeroSpace monitor = NSScreen
  index (`monitor-appkit-nsscreen-screens-id`) → `barhelper screens` → CGDirectDisplayID →
  `sbar.query("displays")` → arrangement id (shared list: `lib/displays.lua`). Status (right) is also one
  item per display (`status.<did>`, same content), width capped
  (`config.status_max`); spaces width per display (`config.left_width`). sketchybarrc reloads only
  when the MAIN screen geometry changes, never while asleep: with the lid closed macOS swaps in a
  virtual 1920×960 @1x display (the reload it caused, plus the one back after wake, left the main
  bar stale: sketchybar skips drawing a bar whose display has no space, sid 0, and a reload +
  Sidecar reconnect hit that window). Re-checked on system_woke. Click/hover ranges per display (device glyphs differ).
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
  first). Opening the lid changes the main screen → sketchybarrc restarts the daemon right after wake
  (before didWake reaches it), so the list lives in `~/.local/state/sketchybar/sidecar-reconnect` and a
  fresh daemon picks it up. Log: `~/.local/state/sketchybar/sleep.log`.
- AeroSpace moves windows via AX, per app, async; no atomic switch possible without SIP. Patches reorder/wait.
- AeroSpace forgets window→workspace on restart; `build.sh --install` snapshots and restores it.
- AeroSpace build is signed with local cert `aerospace-local-codesign` (login keychain) so the Accessibility
  grant survives rebuilds. Build uses Command Line Tools (Xcode license not accepted).
- borders runs from `~/.local/bin/borders` (brew agent disabled via `launchctl disable`), patched:
  focus latency, `glow_radius=` option, window-radius (windows reporting no corner radius, e.g. WezTerm
  without a title bar, get the smallest radius other windows report instead of 9). `build.sh` builds
  offline from `~/.cache/borders-src`.
- sketchybar shows a popup on the display with the FOCUSED window, anchored at the item's rect there:
  a popup of a single-display item lands at -9999 elsewhere. So the battery tooltip is the helper
  daemon's own window (`Tooltips`): Lua renders it per display and lists it in
  `~/.local/state/sketchybar/tooltips`, the daemon shows it on hover (no process spawn). The theme menu
  likewise (`Menu`, `items/theme_menu.lua`, `~/.local/state/sketchybar/menu` with hit rects): the
  daemon opens it on a right click ANYWHERE on the bar (global monitor; the click's target window
  must be sketchybar's), fires `menu_select ID=…`, stays open (re-renders in place), closes on a
  click elsewhere / app activation. A click on another display makes AeroSpace focus that display
  (native leftMouseUp handler) → activation right after a menu click is ignored. Hover = a
  highlight layer over the image (no re-render). Shadow drawn into the image (a non-key window's
  system shadow is invisible); fill L 0.34 (`palette.menu`) — at the popup's L 0.25 it matched
  WezTerm's background and blended in (user briefly found it too much, then kept it).
  Pills / hover highlights never touch: 6pt apart (`widths.sep`), as in the first row.
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
  (`config.strip(strip).scale` = (strip−G)/(32−G); helper renders at higher pixel density, crisp),
  gap between islands kept at G on screen; hover regions per display (5th field = display id), clicks
  scaled via `barhelper cursor` (prints display id). Windows start at 38 built-in / 36 others (outer.top built-in 6 / others
  36), outer.bottom 5 (AeroSpace lays out 1pt short). aerospace.toml gaps must be changed by hand.
  The user tried: G=10 (islands too thin, gap under bar too big), counting the border into the gap
  (rejected) — keep gaps measured from the window.
- Islands: squircle (SwiftUI continuous corners), r = h/3.056; inner pill h−6, concentric (inset 3).
- Active border: `config.lua` `border = { width = 4, glow = 10 }` → `lib/theme.lua` → borders args.
- Built-in display bottom corners are masked to match the physical top ones: helper daemon `Corners`
  (`barhelper daemon <radius>`, `config.lua` `screen_corner`, user-tuned 21): Apple continuous corner,
  rendered once into static layer contents (no redraws), hidden on a native fullscreen Space
  (`CGSCopyManagedDisplaySpaces` type 4), `sharingType = .none` (not in screenshots — to check it
  visually, build a copy with `.readOnly`).
- Accent: wallpaper hue via ScreenCaptureKit (aerial wallpapers have no file), tones in OKLCH
  (`lib/color.lua` `tone`), or custom (macOS accents / NSColorPanel). Also drives borders glow.
- Island fill: OKLCH L 0.30, C 0.07 (tinted by the accent) — lifts macOS 26 dark-theme app icons
  (near-black plates, L≈0.18). Tried: L 0.22 neutral (icons vanish), L 0.40 gray (user: "muddy,
  looks inactive"). User keeps the dark icon theme; don't force light icon variants.
- App icons follow the system icon theme (`AppleIconAppearanceTheme`/`…TintColor`): the daemon
  watches `~/Library/Preferences` → `icon_theme_change`, theme is part of the islands' cache key.
  Lag 5–10s = cfprefsd flushing .GlobalPreferences.plist; user accepted it (no polling). AppKit's
  `NSWorkspaceIconAppearanceConfigurationDidChangeNotification` didn't reach a test process.
- Text: SF Pro Text, optically centered on cap height by the helper. Weight picked in the menu
  (Regular/Medium/Semibold = primary text, secondary one step lighter; `config.font.weights`),
  saved in the theme state. User found Semibold too heavy → Medium. Battery tooltip wording = macOS menu.
- Clock: the daemon fires `minute_change` on every minute boundary (one timer, re-aligned on wake /
  clock change); the next minute's image is pre-rendered, so the swap is a cache hit. Measured on
  screen: +55ms after :00. The 60s routine (battery) is the clock's fallback.

## How to verify visually (Screen Recording is granted to WezTerm)
- `screencapture -x -R x,y,w,h out.png` / `-v -V secs out.mov`; ffmpeg `-fps_mode passthrough` → frames;
  diff frames with PIL/numpy (venv with pillow+numpy was in the session scratchpad; recreate if needed).
- Window order/position probe: `CGWindowListCopyWindowInfo` polled every 2–5ms (small Swift script).
- Real mouse moves for hover tests: post `CGEvent` mouseMoved (small Swift script).

## Status (2026-09-26)
Done and committed: bar rewrite, whole-island rendering, hover (workspaces + battery tooltip), themes,
borders focus patch, AeroSpace flicker patch (+ race fix, bottom-up hide, layout restore, signing),
bug-review fixes (15 items), multi-display basics (clicks/hover per screen, widths fit narrowest screen,
reload only on real geometry change), multi-monitor spec below (2026-09-26, verified by the user:
iPad disconnect/reconnect returns its workspaces, no bar reload, cross-monitor switches instant).

Open issues:
- Battery tooltip "blinks" on first hover (user report) — NOT reproduced (tried event, real mouse,
  stale image). Ask the user for a screen recording and analyze frames.
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
  Focused-monitor indicator: visible ws pill is bright on the focused monitor, dimmed on the others;
  on the other monitors' bars the focused workspace (foreign there) gets a dashed accent outline.
  Bar clicks behave like cmd-N.

## TODO (user, for 2026-09-26)
1. (done 2026-09-26) F6 doesn't turn off the second monitor.
2. Battery glyph: when the fill edge crosses the digits, they become unreadable (digits are knocked
   out of the fill and solid over the empty part — see `drawBattery` in `helper/main.swift`).
3. (done 2026-09-26) Performance review + 4. bug test (multi-monitor spec, sleep/Sidecar) — both
   report-only. Findings + agreed fix order with checkboxes: `docs/review-2026-09-26.md` (evidence
   and probe tools in `~/.local/state/sketchybar/review-2026-09-26/`). Step 1 (sleep/iPad: B1–B4) done,
   awaiting the user's F6 / lid test. NEXT: step 2; tick checkboxes there as items land.
