-- @sdk/libs/math/easing — easing curves [0..1] -> [0..1]
-- Resolve: require("@sdk/libs/math/easing")

local M = {}

function M.linear(t) return t end
function M.quad_in(t) return t * t end
function M.quad_out(t) return 1 - (1 - t) * (1 - t) end
function M.quad_inout(t)
  if t < 0.5 then return 2 * t * t end
  return 1 - (-2 * t + 2) ^ 2 / 2
end
function M.cubic_in(t) return t * t * t end
function M.cubic_out(t) local p = 1 - t; return 1 - p * p * p end
function M.bounce_out(t)
  local n, d = 7.5625, 2.75
  if t < 1 / d then return n * t * t
  elseif t < 2 / d then t = t - 1.5 / d; return n * t * t + 0.75
  elseif t < 2.5 / d then t = t - 2.25 / d; return n * t * t + 0.9375
  else t = t - 2.625 / d; return n * t * t + 0.984375 end
end

return M
