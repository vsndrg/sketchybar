return {
  black       = 0xff070817,
  white       = 0xffffffff,
  red         = 0xfff6708e,
  green       = 0xff86e2b2,
  blue        = 0xff5aa9ff,
  yellow      = 0xffe9cf73,
  orange      = 0xfff39660,
  magenta     = 0xff9d8bff,
  grey        = 0xffcdd9ff,
  transparent = 0x00000000,

  -- Bar: глубокое сине-индиговое стекло под обои
  bar = {
    bg     = 0x40080c20,  -- deep navy glass, ~25% opacity
    border = 0x00000000,
  },

  popup = {
    bg     = 0xff0c1024,
    border = 0x405aa9ff,
  },

  -- Поверхности элементов — едва видимые, холодное стекло
  bg1 = 0x4889a0e6,   -- перванш, ~28% opacity
  bg2 = 0x405b80d8,   -- чуть плотнее и синее, 25% opacity

  -- Активный воркспейс / акцент — в тон свечению рамки (#8ec8ff) с лёгким уклоном в перванш
  accent = 0xff93c2ff,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
