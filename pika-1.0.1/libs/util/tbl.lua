-- @sdk/libs/util/tbl — table utilities
-- Resolve: require("@sdk/libs/util/tbl")

local M = {}

function M.size(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function M.contains(arr, v)
  for _, x in ipairs(arr) do if x == v then return true end end
  return false
end

function M.copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function M.keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  return out
end

return M
