-- Minimal JSON encoder (strings, numbers, booleans, arrays, objects).
local M = {}

function M.encode(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "number" then
    return (math.type(v) == "integer") and tostring(v) or string.format("%.4f", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      local out = {}
      for i, x in ipairs(v) do out[i] = M.encode(x) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys) -- deterministic: an unchanged state encodes identically
    local out = {}
    for i, k in ipairs(keys) do out[i] = M.encode(tostring(k)) .. ":" .. M.encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

return M
