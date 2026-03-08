-- Невидимый item на центр бара — ловит клики по пустой области
sbar.add("item", "zen.trigger", {
  position     = "center",
  width        = 400,
  icon         = { drawing = false },
  label        = { drawing = false },
  background   = { drawing = false },
  updates      = true,
  click_script = "$CONFIG_DIR/helpers/zen_toggle.sh",
})
