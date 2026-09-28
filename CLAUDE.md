# Archived: the sketchybar-based glass bar

Replaced on 2026-09-28 by VsndBar (`~/.config/vsndbar`, one Swift app) — its CLAUDE.md carries the
constraints and design decisions that were kept here. The user speaks Russian; answer in Russian.

sketchybar is disabled, not uninstalled (user's wish): nothing starts it any more (AeroSpace's
after-startup-command and hooks now point at vsndbar). To go back: restore the sketchybar lines in
`~/.config/aerospace/aerospace.toml` (git history of that repo) and stop the VsndBar LaunchAgent
(`make -C ~/.config/vsndbar uninstall`). The theme and Sidecar state moved to `~/.local/state/vsndbar`.
