# Desktop setup: sketchybar + AeroSpace + JankyBorders

Context file for new sessions. Keep it short; update "Status" and "TODO" as work progresses.
The user speaks Russian; answer in Russian. Details of every change are in `git log` of the three repos.

## Repos (each its own git repo)
- `~/.config/sketchybar` — bar (Lua via SbarLua) + native helper `helper/main.swift` (`make -C helper`)
- `~/.config/borders` — `bordersrc`, `patches/focus-latency.patch`, `build.sh` → `~/.local/bin/borders`
- `~/.config/aerospace` — `aerospace.toml`, `patches/{switch-flicker,monitors}.patch`,
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
  `sbar.query("displays")` → arrangement id. Status (right) is one item on all displays, width capped
  (`config.status_max`); spaces width per display (`config.left_width`). sketchybarrc reloads only
  when the MAIN screen geometry changes. Ranges identical on all displays (left-aligned).
- AeroSpace: a hidden workspace remembers its monitor by the monitor's top-left point
  (`assignedMonitorPoint`); a missing monitor maps to the nearest one → reconnect returns them natively.
  BUT Sidecar disconnect makes its windows "die" briefly → AeroSpace's closed-windows cache
  (`closedWindowsCache.swift`) snapshots the world with approximated monitors and restores it → iPad
  workspaces got re-homed to main. monitors.patch stores/restores the home point instead.
  Also: showing a workspace re-homes it — so while its home monitor is disconnected, monitors.patch
  does NOT re-home it (user switches to 4/5 on main while iPad is off; they must still go back);
  a monitor that merely moved takes its workspaces along (rearrange remaps old point → new).
- AeroSpace moves windows via AX, per app, async; no atomic switch possible without SIP. Patches reorder/wait.
- AeroSpace forgets window→workspace on restart; `build.sh --install` snapshots and restores it.
- AeroSpace build is signed with local cert `aerospace-local-codesign` (login keychain) so the Accessibility
  grant survives rebuilds. Build uses Command Line Tools (Xcode license not accepted).
- borders runs from `~/.local/bin/borders` (brew agent disabled via `launchctl disable`), patched:
  focus latency, `glow_radius=` option, window-radius (windows reporting no corner radius, e.g. WezTerm
  without a title bar, get the smallest radius other windows report instead of 9). `build.sh` builds
  offline from `~/.cache/borders-src`.
- `sketchybarrc` runs `pkill -f 'barhelper daemon'`: never put that literal string in your own shell
  command during a reload (it kills your shell) — use `pgrep -f 'barhelpe[r] daemon'`.

## Design
- One gap G = 6 (`config.lua` `bar.gap`, derived geometry below it): screen edge → island → window →
  window → edge, and between islands. Bar h 32 = notch strip; islands h 32 − G = 26 hang G from the top
  and end flush with the strip (item y_offset −G/2). Windows start at 38 (outer.top built-in 6 / others
  38), outer.bottom 5 (AeroSpace lays out 1pt short). aerospace.toml gaps must be changed by hand.
  The user tried: G=10 (islands too thin, gap under bar too big), counting the border into the gap
  (rejected) — keep gaps measured from the window.
- Islands: squircle (SwiftUI continuous corners), r = h/3.056; inner pill h−6, concentric (inset 3).
- Active border: `config.lua` `border = { width = 4, glow = 10 }` → `lib/theme.lua` → borders args.
- Accent: wallpaper hue via ScreenCaptureKit (aerial wallpapers have no file), tones in OKLCH
  (`lib/color.lua` `tone`), or custom (macOS accents / NSColorPanel). Also drives borders glow.
- Text: SF Pro Text, optically centered on cap height by the helper. Battery tooltip wording = macOS menu.

## How to verify visually (Screen Recording is granted to WezTerm)
- `screencapture -x -R x,y,w,h out.png` / `-v -V secs out.mov`; ffmpeg `-fps_mode passthrough` → frames;
  diff frames with PIL/numpy (venv with pillow+numpy was in the session scratchpad; recreate if needed).
- Window order/position probe: `CGWindowListCopyWindowInfo` polled every 2–5ms (small Swift script).
- Real mouse moves for hover tests: post `CGEvent` mouseMoved (small Swift script).

## Status (2026-09-25)
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
  the user never has to look around for a workspace; workspaces living on another monitor are marked
  as foreign: digit + app icons dimmed as a whole (~40%), same numeric order, no separate group, no
  pill even if visible there. Right side (status) identical on every monitor.
  Focused-monitor indicator: visible ws pill is bright on the focused monitor, dimmed on the others;
  on the other monitors' bars the focused workspace (foreign there) gets a dashed accent outline.
  Bar clicks behave like cmd-N.

## TODO (user, for 2026-09-26)
1. Clock lags behind real time. Likely cause: `items/status.lua` checks the minute on a 10s
   `routine` (up to ~10s late) + render latency; align the update to the minute boundary.
2. F6 doesn't turn off the second monitor (there is an F6 rule in `~/.config/karabiner/karabiner.json`).
3. Battery glyph: when the fill edge crosses the digits, they become unreadable (digits are knocked
   out of the fill and solid over the empty part — see `drawBattery` in `helper/main.swift`).
4. Performance review — run as a SEPARATE agent (Agent tool): bar render/refresh latency, helper
   daemon CPU, AeroSpace switch timing, prerender volume with several displays.
5. Bug test — run as a SEPARATE agent: exercise the multi-monitor spec end to end (cmd-N, cmd-alt-N,
   cmd-shift-N/h/l, clicks/hover per display, empty/new workspaces, display disconnect/reconnect),
   themes, battery tooltip; report findings before fixing.
