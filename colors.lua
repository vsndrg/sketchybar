return {
  black       = 0xff0d0d0f,
  white       = 0xffffffff,
  red         = 0xffff6b8a,
  green       = 0xff9ed072,
  blue        = 0xffb0a8ff,
  yellow      = 0xffe7c664,
  orange      = 0xfff39660,
  magenta     = 0xffc9b8ff,
  grey        = 0xffe8e4f8,
  transparent = 0x00000000,

  -- Bar: розово-фиолетовый, хорошо прозрачный
  bar = {
    bg     = 0x40180f1e,  -- ~88% opacity, без blur нужна большая непрозрачность
    border = 0x00000000,
  },

  popup = {
    bg     = 0xff1a1020,
    border = 0x40c9b8ff,
  },

  -- Поверхности элементов — едва видимые, стеклянные
  bg1 = 0x48c0aecc,   -- нейтрально-лиловый, ~27% opacity
  bg2 = 0x40b09aff,   -- чуть плотнее, 25% opacity

  -- Активный воркспейс / акцент
  accent = 0xffcfb8ff,  -- мягкий лавандовый

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
