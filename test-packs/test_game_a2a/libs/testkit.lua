-- libs/testkit — test harness for game-side tests and on-robot feature probes
-- Resolve: require("libs/testkit")
--
-- Two layers:
--   * expect / expect_eq / reg_sync / run_sync: plain unit tests, no screen.
--   * suite(opts): the on-robot runner every test-packs/test_<module> pack uses:
--     a test list driven by three buttons, RUN SUITE + Reset rows, sync and
--     async tests under pcall, one Text HUD and a fixed UART log format:
--       <tag> [NN/NN] BEGIN  <group> :: <name>
--       <tag> [NN/NN] PASS   <group> :: <name> :: <detail>      (FAIL / SKIP)
--       <tag> SUITE BEGIN / SUITE END / SUMMARY :: PASS=.. FAIL=.. SKIP=..

local M = {}
local sync_tests, async_tests = {}, {}

local function fmt_msg(msg) return tostring(msg or "") end

function M.expect(cond, msg)
  if not cond then error("[expect] " .. fmt_msg(msg), 2) end
end

function M.expect_eq(a, b, msg)
  if a ~= b then
    error(string.format("[expect_eq] %s: %s != %s", fmt_msg(msg), tostring(a), tostring(b)), 2)
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

-- ── suite ────────────────────────────────────────────────────────────

local fmt, concat, ssub = string.format, table.concat, string.sub
local R_PASS, R_FAIL, R_SKIP = "PASS", "FAIL", "SKIP"

local DEFAULTS = {
  title     = "TEST",
  tag       = "test",
  font      = nil,          -- pack-relative TTF; nil keeps the engine default
  font_px   = 14,
  x = 6, y = 4,
  panel_w   = 52,           -- chars per HUD line; longer lines are clipped
  settle_ms = 1200,         -- gap between tests during RUN SUITE
  render_ms = 100,          -- HUD redraw throttle
  live      = false,        -- redraw every tick (for live counters)
  abortable = true,         -- LEFT stops a running test / RUN SUITE
  prev = "prev", next = "next", fire = "fire",
}

local GROUP_FALLBACK = { label = "TEST", what = "" }

local Suite = {}
Suite.__index = Suite

-- opts: see DEFAULTS, plus
--   groups   = { <code> = { label = "...", what = "..." } }  readable HUD names
--   status   = function() -> string    extra HUD lines (may contain "\n")
--   on_abort = function()              called when a running test is aborted
--   on_reset = function()              called by the "Reset results" row
function M.suite(opts)
  opts = opts or {}
  local s = setmetatable({}, Suite)
  for k, v in pairs(DEFAULTS) do s[k] = v end
  for k, v in pairs(opts) do s[k] = v end
  s.groups   = opts.groups or {}
  s.rule     = string.rep("-", s.panel_w)
  s.tests    = {}
  s.results  = {}
  s.pass_n, s.fail_n, s.skip_n = 0, 0, 0
  s.cursor   = 1
  s.mode     = "single"   -- single | between | running
  s.in_suite = false
  s.active, s.st = nil, nil
  s.settle_until = 0
  s.hud, s.hud_dirty, s.hud_last_ms, s.hud_last = nil, true, 0, ""
  s.hud_buf  = {}
  s.tests[1] = { group = "runner", name = "RUN SUITE (all tests)", meta = "suite" }
  s.tests[2] = { group = "runner", name = "Reset results",         meta = "reset" }
  if not s.groups.runner then
    s.groups.runner = { label = "SUITE CONTROL", what = "run all tests / reset results" }
  end
  return s
end

-- Options shared by sync and async tests:
--   settle_ms  = gap after this test in RUN SUITE
--   manual     = true: RUN SUITE skips it (a test that ends the game)
-- Async only:
--   prompt     = string or function(st) -> string, shown while it runs
--   input      = function(st, action, phase, hold_ms): the test owns the
--                buttons while it runs (navigation and abort are suspended),
--                so step() must end on its own within a bounded time.
--   fullscreen = true: while it runs the HUD shrinks to title + prompt so
--                the test can draw on the rest of the screen.
local function apply(t, o)
  if o then
    t.settle_ms, t.manual = o.settle_ms, o.manual
    t.prompt, t.input, t.fullscreen = o.prompt, o.input, o.fullscreen
  end
  return t
end

-- fn() -> pass, msg   (pass may be "skip")
function Suite:sync(group, name, fn, o)
  local t = apply({ group = group, name = name, sync = fn }, o)
  self.tests[#self.tests + 1] = t
  return t
end

-- arm() -> st; step(st) -> done, pass, msg   (pass may be "skip")
function Suite:async(group, name, arm, step, o)
  local t = apply({ group = group, name = name, arm = arm, step = step }, o)
  self.tests[#self.tests + 1] = t
  return t
end

-- Operator verdict for what only a person can judge (glyphs, images, LEDs,
-- servo motion). show(st) draws or starts it and may return cleanup, detail:
-- cleanup() runs once the operator answered, detail is appended to the log.
-- ENTER (fire) = looks right, RIGHT (next) = looks wrong. o: settle_ms,
-- manual, timeout_ms (30000), fullscreen (default true).
function Suite:look(group, name, show, question, o)
  o = o or {}
  local timeout = o.timeout_ms or 30000
  local yes, no = self.fire, self.next
  local function arm()
    local st = { t_end = Timer.millis() + timeout }
    local ok, cleanup, detail = pcall(show, st)
    if not ok then
      st.verdict, st.msg = false, "show error: " .. tostring(cleanup)
    else
      st.cleanup, st.detail = cleanup, detail
    end
    return st
  end
  local function step(st)
    if st.verdict == nil and Timer.millis() < st.t_end then return false end
    if st.cleanup then
      local ok, err = pcall(st.cleanup)
      if not ok then print(self.tag .. ": cleanup error: " .. tostring(err)) end
    end
    if st.verdict == nil then
      return true, false, fmt("no answer within %d s", timeout // 1000)
    end
    local msg = st.msg or (st.verdict and "operator: looks right" or "operator: looks wrong")
    if st.detail then msg = msg .. "; " .. tostring(st.detail) end
    return true, st.verdict, msg
  end
  local function input(st, action, phase)
    if phase ~= Input.PRESS or st.verdict ~= nil then return end
    if action == yes then st.verdict = true
    elseif action == no then st.verdict = false end
  end
  return self:async(group, name, arm, step, {
    settle_ms = o.settle_ms, manual = o.manual, input = input,
    fullscreen = o.fullscreen ~= false,
    prompt = question .. "   ENTER=yes RIGHT=no",
  })
end

function Suite:dirty() self.hud_dirty = true end

function Suite:counts() return self.pass_n, self.fail_n, self.skip_n end

function Suite:record(idx, status, msg)
  local old = self.results[idx]
  if old then
    if old.status == R_PASS then self.pass_n = self.pass_n - 1
    elseif old.status == R_FAIL then self.fail_n = self.fail_n - 1
    else self.skip_n = self.skip_n - 1 end
  end
  self.results[idx] = { status = status, msg = msg }
  if status == R_PASS then self.pass_n = self.pass_n + 1
  elseif status == R_FAIL then self.fail_n = self.fail_n + 1
  else self.skip_n = self.skip_n + 1 end
  self.hud_dirty = true
end

function Suite:_log_end(idx, status, msg)
  local t = self.tests[idx]
  if msg == nil or msg == "" then msg = "(no detail)" end
  print(fmt("%s [%02d/%02d] %-4s   %-9s :: %s :: %s",
            self.tag, idx, #self.tests, status, t.group, t.name, msg))
end

-- pass: true, false, or "skip" (the test could not run here, e.g. no server)
function Suite:_finish(idx, pass, msg)
  local status = (pass == "skip") and R_SKIP or (pass and R_PASS or R_FAIL)
  msg = msg and tostring(msg) or ""
  self:record(idx, status, msg)
  self:_log_end(idx, status, msg)
end

function Suite:_banner(line)
  print(self.tag .. " ============================================")
  print(self.tag .. " " .. line)
  print(self.tag .. " ============================================")
end

function Suite:_first_test()
  for i, t in ipairs(self.tests) do
    if not t.meta then return i end
  end
  return #self.tests + 1
end

-- Tests RUN SUITE walks (meta and manual rows excluded).
function Suite:_test_count()
  local n = 0
  for _, t in ipairs(self.tests) do
    if not t.meta and not t.manual then n = n + 1 end
  end
  return n
end

function Suite:_reset()
  self.pass_n, self.fail_n, self.skip_n = 0, 0, 0
  for k in pairs(self.results) do self.results[k] = nil end
  self.hud_dirty = true
end

-- Runs test idx. Returns true when it completed synchronously.
function Suite:_fire(idx)
  local t = self.tests[idx]
  if not t then return true end
  if t.meta == "suite" then self:_suite_start(); return false end
  if t.meta == "reset" then
    self:_reset()
    if self.on_reset then pcall(self.on_reset) end
    print(self.tag .. ": results reset")
    return true
  end

  print(fmt("%s [%02d/%02d] BEGIN  %-9s :: %s",
            self.tag, idx, #self.tests, t.group, t.name))
  if t.sync then
    local ok, a, b = pcall(t.sync)
    if ok then self:_finish(idx, a, b)
    else self:_finish(idx, false, "lua error: " .. tostring(a)) end
    return true
  end

  local ok, st = pcall(t.arm)
  if not ok then
    self:_finish(idx, false, "arm error: " .. tostring(st))
    return true
  end
  self.active, self.st = idx, st or {}
  self.mode = "running"
  self.hud_dirty = true
  return false
end

function Suite:_step()
  local idx = self.active
  local t = self.tests[idx]
  local ok, done, pass, msg = pcall(t.step, self.st)
  if not ok then
    done, pass, msg = true, false, "step error: " .. tostring(done)
  end
  if not done then return end
  self.active, self.st = nil, nil
  self.mode = "single"
  self:_finish(idx, pass, msg)
  self:_advance(t.settle_ms)
end

function Suite:_advance(settle_ms)
  if not self.in_suite then self.mode = "single"; return end
  self.cursor = self.cursor + 1
  while self.cursor <= #self.tests and self.tests[self.cursor].manual do
    self.cursor = self.cursor + 1
  end
  if self.cursor > #self.tests then
    self.in_suite = false
    self.mode = "single"
    self.cursor = #self.tests
    self:_banner(fmt("SUITE END :: PASS=%d  FAIL=%d  SKIP=%d  (of %d total)",
                     self.pass_n, self.fail_n, self.skip_n, self:_test_count()))
    self.hud_dirty = true
    return
  end
  self.settle_until = Timer.millis() + (settle_ms or self.settle_ms)
  self.mode = "between"
  self.hud_dirty = true
end

function Suite:_suite_start()
  self:_reset()
  if self.on_abort then pcall(self.on_abort) end
  self.in_suite = true
  self.cursor = self:_first_test() - 1
  self:_banner(fmt("SUITE BEGIN :: %d tests queued", self:_test_count()))
  self:_advance(0)
end

function Suite:abort(reason)
  reason = reason or "aborted by user"
  if self.active then
    local idx = self.active
    self.active, self.st = nil, nil
    self:record(idx, R_SKIP, reason)
    self:_log_end(idx, R_SKIP, reason)
  end
  if self.on_abort then pcall(self.on_abort) end
  self.in_suite = false
  self.mode = "single"
  self.hud_dirty = true
  print(self.tag .. ": aborted")
end

-- ── engine hooks: call these from game_start / on_input / on_tick / game_end

function Suite:start()
  local hud, err = Text.new("", self.x, self.y)
  if not hud then print(self.tag .. ": HUD Text.new failed: " .. tostring(err)) end
  self.hud = hud
  if hud and self.font then
    local _, ferr = hud:set_font(self.font, self.font_px)
    if ferr then print(self.tag .. ": set_font failed: " .. tostring(ferr)) end
  end
  print(fmt("%s: game_start tests=%d", self.tag, self:_test_count()))
  self.hud_dirty = true
end

-- Returns true when the suite consumed the event.
function Suite:input(action, phase, hold_ms)
  if self.mode == "running" then
    local t = self.tests[self.active]
    if t.input then
      local ok, err = pcall(t.input, self.st, action, phase, hold_ms)
      if not ok then print(self.tag .. ": input error: " .. tostring(err)) end
      return true
    end
  end
  if phase ~= Input.PRESS then return false end

  if action == self.prev then
    if self.mode ~= "single" then
      if self.abortable then self:abort() end
      return true
    end
    self.cursor = (self.cursor > 1) and (self.cursor - 1) or #self.tests
    self.hud_dirty = true
    return true
  end
  if action == self.next then
    if self.mode ~= "single" then return true end
    self.cursor = (self.cursor < #self.tests) and (self.cursor + 1) or 1
    self.hud_dirty = true
    return true
  end
  if action == self.fire then
    if self.mode ~= "single" then return true end
    self:_fire(self.cursor)
    return true
  end
  return false
end

function Suite:tick()
  if self.mode == "between" and Timer.millis() >= self.settle_until then
    if self:_fire(self.cursor) then
      self:_advance(self.tests[self.cursor].settle_ms)
    end
  elseif self.mode == "running" then
    self:_step()
  end
  if self.live then self.hud_dirty = true end
  self:_render()
end

function Suite:summary(extra)
  self:_banner(fmt("SUMMARY :: PASS=%d  FAIL=%d  SKIP=%d  total=%d",
                   self.pass_n, self.fail_n, self.skip_n, self:_test_count()))
  for i, t in ipairs(self.tests) do
    if not t.meta then
      local r = self.results[i]
      if r then
        print(fmt("%s [%02d/%02d] %-4s   %-9s :: %s :: %s",
                  self.tag, i, #self.tests, r.status, t.group, t.name, r.msg))
      else
        print(fmt("%s [%02d/%02d] ----   %-9s :: %s :: not run",
                  self.tag, i, #self.tests, t.group, t.name))
      end
    end
  end
  if extra then print(self.tag .. " FINAL " .. tostring(extra)) end
end

-- ── HUD ──────────────────────────────────────────────────────────────

function Suite:_clip(s)
  if #s > self.panel_w then return ssub(s, 1, self.panel_w - 1) .. "~" end
  return s
end

function Suite:_group(g) return self.groups[g] or GROUP_FALLBACK end

function Suite:_prompt(t)
  local p = t.prompt
  if type(p) == "function" then
    local ok, v = pcall(p, self.st)
    p = ok and tostring(v) or "?"
  end
  return p
end

function Suite:_format()
  local b, n = self.hud_buf, 0
  local t = self.tests[self.cursor]
  local gi = self:_group(t.group)
  local function add(s) n = n + 1; b[n] = s end
  local running = self.mode == "running" and self.tests[self.active]

  if running and running.fullscreen then
    add(self:_clip(fmt("%s  %02d/%02d  %s", self.title, self.active, #self.tests,
                       running.name)))
    if running.prompt then add(self:_clip(self:_prompt(running))) end
    for i = n + 1, #b do b[i] = nil end
    return concat(b, "\n", 1, n)
  end

  add(fmt("%s   %02d/%02d", self.title, self.cursor, #self.tests))
  add(fmt("%-7s  PASS %d  FAIL %d  SKIP %d",
          self.mode, self.pass_n, self.fail_n, self.skip_n))
  add(self.rule)
  add(self:_clip("NOW  > " .. gi.label))
  if gi.what ~= "" then add(self:_clip("     " .. gi.what)) end
  add(self:_clip("     case: " .. t.name .. (t.manual and "  (manual)" or "")))

  if running and running.prompt then
    add(self:_clip("ACTION  " .. self:_prompt(running)))
  else
    local r = self.results[self.cursor]
    if r then
      add("RESULT  " .. r.status)
      if r.msg ~= "" then add(self:_clip("        " .. r.msg)) end
    else
      add("RESULT  (not run)")
    end
  end
  add(self.rule)

  if self.cursor > 1 then
    local p = self.tests[self.cursor - 1]
    add(self:_clip("prev <  " .. self:_group(p.group).label .. " / " .. p.name))
  end
  if self.cursor < #self.tests then
    local nx = self.tests[self.cursor + 1]
    add(self:_clip("next >  " .. self:_group(nx.group).label .. " / " .. nx.name))
  end

  if self.status then
    local ok, v = pcall(self.status)
    if ok and v and v ~= "" then
      for line in tostring(v):gmatch("[^\n]+") do add(self:_clip(line)) end
    end
  end

  if running and running.input then
    add("test owns the buttons; it ends on its own")
  elseif self.in_suite then
    add("SUITE running   LEFT = abort")
  else
    add("ENTER=run   LEFT/RIGHT=move   row 1=suite")
  end

  for i = n + 1, #b do b[i] = nil end
  return concat(b, "\n", 1, n)
end

function Suite:_render()
  if not self.hud_dirty or not self.hud then return end
  local now = Timer.millis()
  if now - self.hud_last_ms < self.render_ms then return end
  local s = self:_format()
  if s ~= self.hud_last then
    self.hud:set(s)
    self.hud_last = s
  end
  self.hud_last_ms = now
  self.hud_dirty = false
end

return M
