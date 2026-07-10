-- libs/ui — single-line text helpers (selector + yes/no confirm)
-- Resolve: require("libs/ui")
--
-- Renders ONE persistent line via a shared Text object (created lazily, pinned
-- top-left). These helpers keep selection/choice state; the game drives them:
-- call :next/:prev/:toggle from on_input, then :render.

local M = {}

-- Shared one-line label, created on first render (Text.new needs the game screen).
local line               -- Text handle
local function set_line(s)
  if not Text then return end
  if line then line:set(s) else line = Text.new(s, 4, 4) end
end

-- selector(items[, opts]) — one-line scrollable choice.
-- opts.format: string.format pattern receiving (item, idx, count); default "< %s (%d/%d) >".
-- Methods: next()/prev() (clamped to bounds), current()->item,idx, index()->idx, render().
function M.selector(items, opts)
  opts = opts or {}
  local fmt = opts.format or "< %s (%d/%d) >"
  local n = #items
  local idx = 1
  local sel = {}
  function sel:next() if n > 0 then idx = math.min(idx + 1, n) end; return self end
  function sel:prev() if n > 0 then idx = math.max(idx - 1, 1) end; return self end
  function sel:index() return idx end
  function sel:current() return items[idx], idx end
  function sel:render()
    if n == 0 then set_line(""); return self end
    set_line(string.format(fmt, tostring(items[idx]), idx, n))
    return self
  end
  return sel
end

-- confirm(question[, opts]) — one-line yes/no prompt. Starts on "yes".
-- opts.yes / opts.no: label text (default "Yes"/"No").
-- Methods: toggle(), choice()->bool (true = yes), render().
function M.confirm(question, opts)
  opts = opts or {}
  question = question or ""
  local yes_txt, no_txt = opts.yes or "Yes", opts.no or "No"
  local yes = true
  local c = {}
  function c:toggle() yes = not yes; return self end
  function c:choice() return yes end
  function c:render()
    local s = yes
      and string.format("%s  [%s] %s", question, yes_txt, no_txt)
      or  string.format("%s  %s [%s]", question, yes_txt, no_txt)
    set_line(s)
    return self
  end
  return c
end

return M
