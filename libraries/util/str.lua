-- libs/util/str — string utilities
-- Resolve: require("libs/util/str")

local M = {}

function M.split(s, sep)
  local out, pat = {}, "([^" .. sep .. "]+)"
  for piece in string.gmatch(s, pat) do out[#out + 1] = piece end
  return out
end

function M.starts_with(s, prefix)
  return string.sub(s, 1, #prefix) == prefix
end

function M.ends_with(s, suffix)
  return suffix == "" or string.sub(s, -#suffix) == suffix
end

function M.trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

return M
