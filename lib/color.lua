-- ARGB (0xAARRGGBB) helpers.
local M = {}

local function split(c)
  return (c >> 24) & 0xff, (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff
end

local function join(a, r, g, b)
  local function clamp(x) return math.max(0, math.min(255, math.floor(x + 0.5))) end
  return (clamp(a) << 24) | (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
end

-- Replace alpha (0..1).
function M.alpha(c, a)
  local _, r, g, b = split(c)
  return join(a * 255, r, g, b)
end

-- Linear mix of two colors, t = share of `b`.
function M.mix(a, b, t)
  local aa, ar, ag, ab = split(a)
  local ba, br, bg, bb = split(b)
  return join(aa + (ba - aa) * t, ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end

function M.hex(c)
  return string.format("0x%08x", c & 0xffffffff)
end

function M.parse(s)
  local v = s and tonumber((s:gsub("^0x", "")), 16)
  return v and (v & 0xffffffff) or nil
end

-- OKLCH: perceptual lightness/chroma/hue, so tones derived from any accent
-- read the same regardless of its hue.
local function to_linear(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function to_srgb(c) return c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055 end
local function cbrt(x) return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3) end

function M.to_oklch(c)
  local _, r, g, b = split(c)
  r, g, b = to_linear(r / 255), to_linear(g / 255), to_linear(b / 255)
  local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  local L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
  local A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
  local B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  return L, math.sqrt(A * A + B * B), math.atan(B, A)
end

local function from_oklch(L, C, h)
  local A, B = C * math.cos(h), C * math.sin(h)
  local l = (L + 0.3963377774 * A + 0.2158037573 * B) ^ 3
  local m = (L - 0.1055613458 * A - 0.0638541728 * B) ^ 3
  local s = (L - 0.0894841775 * A - 1.2914855480 * B) ^ 3
  local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  for _, v in ipairs({ r, g, b }) do
    if v < -0.0005 or v > 1.0005 then return nil end
  end
  return r, g, b
end

-- Same hue as `c`, at lightness L and (at most) chroma C, clamped into sRGB.
function M.tone(c, L, C, alpha)
  local _, c0, h = M.to_oklch(c)
  C = math.min(C, c0)
  while C >= 0 do
    local r, g, b = from_oklch(L, C, h)
    if r then
      return join((alpha or 1) * 255, to_srgb(math.max(0, r)) * 255, to_srgb(math.max(0, g)) * 255,
        to_srgb(math.max(0, b)) * 255)
    end
    C = C - 0.005
  end
  return join((alpha or 1) * 255, L * 255, L * 255, L * 255)
end

M.transparent = 0x00000000

return M
