-- @sdk/libs/math/vec2 — 2D vector
-- Resolve: require("@sdk/libs/math/vec2")

local M = {}
local V = {}
V.__index = V

function M.new(x, y) return setmetatable({ x = x or 0, y = y or 0 }, V) end

function V:add(o) return M.new(self.x + o.x, self.y + o.y) end
function V:sub(o) return M.new(self.x - o.x, self.y - o.y) end
function V:scale(s) return M.new(self.x * s, self.y * s) end
function V:len() return math.sqrt(self.x * self.x + self.y * self.y) end
function V:dot(o) return self.x * o.x + self.y * o.y end

return M
