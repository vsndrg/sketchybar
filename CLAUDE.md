# Desktop setup: sketchybar + AeroSpace + JankyBorders

Context file for new sessions. Keep it short; update "Status" and "TODO" as work progresses.
The user speaks Russian; answer in Russian. Details of every change are in `git log` of the three repos.

## Repos (each its own git repo)
- `~/.config/sketchybar` — bar (Lua via SbarLua) + native helper `helper/main.swift` (`make -C helper`)
- `~/.config/borders` — `bordersrc`, `patches/focus-latency.patch`, `build.sh` → `~/.local/bin/borders`
- `~/.config/aerospace` — `aerospace.toml`, `patches/switch-flicker.patch`, `patches/build.sh [--install|--restore]`
- `~/.config` is also a repo with NO commits and secrets staged (`github-copilot/auth.db`) — don't commit it.

## Hard constraints (found the hard way, don't re-derive)
- macOS 26+: sketchybar can't batch window updates (moves/resizes and content land in different frames).
  → Each bar side is ONE fixed-width item showing ONE image rendered by the helper (`render` subcommand).
  Never change item width/position on state changes; only swap the image.
- sketchybar → Lua events go over a tiny mach queue; per-item mouse.entered/exited on many items deadlocked
  the bar. → No per-item hover; the helper daemon tracks the cursor (global mouse monitor) against
  `~/.local/state/sketchybar/regions` (written via `lib/regions.lua`) and fires `bar_hover REGION=…` on change.
- Clicks: `barhelper cursor` → "x_on_screen screen_width"; mapped to hit ranges from the renderer.
- AeroSpace moves windows via AX, per app, async; no atomic switch possible without SIP. Patches reorder/wait.
- AeroSpace forgets window→workspace on restart; `build.sh --install` snapshots and restores it.
- AeroSpace build is signed with local cert `aerospace-local-codesign` (login keychain) so the Accessibility
  grant survives rebuilds. Build uses Command Line Tools (Xcode license not accepted).
- borders runs from `~/.local/bin/borders` (brew agent disabled via `launchctl disable`).
- `sketchybarrc` runs `pkill -f 'barhelper daemon'`: never put that literal string in your own shell
  command during a reload (it kills your shell) — use `pgrep -f 'barhelpe[r] daemon'`.

## Design
- Islands: squircle (SwiftUI continuous corners), h 26, r 8.5; inner pill h 20 r 5.5 (concentric).
- Bar h 32 = notch strip; 10pt rhythm: margins 10, windows start at 39 (outer.top built-in 7 / others 39),
  outer.bottom 9 (AeroSpace lays out 1pt short).
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
reload only on real geometry change).

Open issues:
- Battery tooltip "blinks" on first hover (user report) — NOT reproduced (tried event, real mouse,
  stale image). Ask the user for a screen recording and analyze frames.
- Second display: lower accordion window flashes on switch again. Planned fix (not implemented):
  replace timeouts with confirmed ordering — per monitor only; place + confirm the top window before
  revealing lower accordion windows; hide old windows top-down only after the ones below are gone;
  timeouts only as ~1s liveness fallback; no waits for non-overlapping (tiles) layouts.
- Performance review (separate agent) proposed, not run yet.

## TODO (user, for 2026-09-26)
1. Design bar + workspace logic for multiple monitors (each bar shows its own monitor's workspaces;
   workspace 11 on Sidecar is currently not shown; bar lists are global).
2. Fix vertical symmetry: gaps between bar and windows and at the screen edges.
3. Clock lags behind real time. Likely cause: `items/status.lua` checks the minute on a 10s
   `routine` (up to ~10s late) + render latency; align the update to the minute boundary.
