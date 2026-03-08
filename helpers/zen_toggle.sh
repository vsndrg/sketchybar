#!/usr/bin/env bash
# Zen mode toggle — скрывает/показывает apple, cpu, wifi, volume

SBAR="/opt/homebrew/opt/sketchybar/bin/sketchybar"
STATE_FILE="/tmp/sketchybar_zen"

ZEN_ITEMS=(
  "apple.icon"
  "widgets.cpu"
  "widgets.cpu.padding"
  "widgets.wifi.bracket"
  "widgets.wifi.icon"
  "widgets.wifi1"
  "widgets.wifi2"
  "widgets.wifi.padding"
  "widgets.volume.bracket"
  "widgets.volume1"
  "widgets.volume2"
  "widgets.volume.padding"
)

if [[ -f "$STATE_FILE" ]]; then
  # Выходим из zen
  rm "$STATE_FILE"
  for item in "${ZEN_ITEMS[@]}"; do
    "$SBAR" --set "$item" drawing=on
  done
else
  # Входим в zen
  touch "$STATE_FILE"
  for item in "${ZEN_ITEMS[@]}"; do
    "$SBAR" --set "$item" drawing=off
  done
fi
