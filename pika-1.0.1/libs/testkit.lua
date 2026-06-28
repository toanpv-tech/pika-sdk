-- @sdk/libs/testkit — minimal test harness for game-side unit tests
-- Resolve: require("@sdk/libs/testkit")

local M = {}
local sync_tests, async_tests = {}, {}

local function fmt(msg) return tostring(msg or "") end

function M.expect(cond, msg)
  if not cond then error("[expect] " .. fmt(msg), 2) end
end

function M.expect_eq(a, b, msg)
  if a ~= b then
    error(string.format("[expect_eq] %s: %s != %s", fmt(msg), tostring(a), tostring(b)), 2)
  end
end

function M.reg_sync(name, fn)
  sync_tests[#sync_tests + 1] = { name = name, fn = fn }
end

function M.reg_async(name, fn, timeout_ms)
  async_tests[#async_tests + 1] = { name = name, fn = fn, timeout = timeout_ms or 5000 }
end

function M.run_sync()
  local passed, failed = 0, 0
  for _, t in ipairs(sync_tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. t.name .. ": " .. tostring(err)) end
  end
  return passed, failed
end

return M
