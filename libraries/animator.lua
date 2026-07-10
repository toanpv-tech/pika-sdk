-- libs/animator — tween/easing for Sprite movement
-- Resolve: require("libs/animator")

local easing = require("libs/math/easing")

local M = {}
local Tween = {}
Tween.__index = Tween

function M.tween(target, from, to, duration_ms, ease)
  return setmetatable({
    target = target,
    from = from,
    to = to,
    duration = duration_ms,
    elapsed = 0,
    ease = ease or easing.linear,
    done = false,
  }, Tween)
end

function Tween:step(dt_ms)
  if self.done then return end
  self.elapsed = self.elapsed + dt_ms
  local t = math.min(self.elapsed / self.duration, 1.0)
  local v = self.from + (self.to - self.from) * self.ease(t)
  if self.target then self.target.value = v end
  if t >= 1.0 then self.done = true end
end

return M
