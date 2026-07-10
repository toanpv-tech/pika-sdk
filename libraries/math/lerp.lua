-- libs/math/lerp — lerp + clamp helpers
-- Resolve: require("libs/math/lerp")

local M = {}

function M.lerp(a, b, t) return a + (b - a) * t end
function M.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
function M.map(v, in_lo, in_hi, out_lo, out_hi)
  local t = (v - in_lo) / (in_hi - in_lo)
  return out_lo + (out_hi - out_lo) * t
end

return M
