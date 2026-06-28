-- @sdk/libs/ui — single-line HUD helpers (selector + yes/no confirm)
-- Resolve: require("@sdk/libs/ui")
--
-- HUD exposes only set_label (one persistent line, no clear/timer/x-y). These
-- helpers keep selection/choice state and render ONE line via HUD.set_label.
-- The game drives them: call :next/:prev/:toggle from on_input, then :render.

local M = {}

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
    if n == 0 then HUD.set_label(""); return self end
    HUD.set_label(string.format(fmt, tostring(items[idx]), idx, n))
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
    local line = yes
      and string.format("%s  [%s] %s", question, yes_txt, no_txt)
      or  string.format("%s  %s [%s]", question, yes_txt, no_txt)
    HUD.set_label(line)
    return self
  end
  return c
end

return M
