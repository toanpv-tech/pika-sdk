-- @sdk/libs/save — tiny per-game persistence helper over State.
-- Resolve: require("@sdk/libs/save")
--
-- The engine gives each game ONE opaque save slot (<game_id>.sav). This helper
-- packs a flat table of scalars into that single slot so a game can keep its
-- high score AND an in-progress session together (use a marker field like
-- ip=1 to tell "resumable session" from "high-score only"). It deliberately
-- does NOT use load()/json — both are blocked in the Lua sandbox — so encode is
-- a line format the decode side parses with string ops only.
--
-- Format:  one entry per line, "key=<t>:<value>" where <t> is n(umber),
--          b(ool) or s(tring). Numbers/bools are safe; STRING values must not
--          contain a newline (they terminate the entry). Keys are identifiers.
--
-- Hot-loop hazard: write() hits FATFS via State.save — call it only at safe
-- checkpoints (pause/level/turn boundaries), never from on_tick.

local M = {}

-- Serialise a flat table {k=v,...} (string/number/boolean values) to a string.
-- Unsupported value types are skipped.
function M.encode(t)
  local parts = {}
  for k, v in pairs(t) do
    local ty = type(v)
    if ty == "number" then
      parts[#parts + 1] = k .. "=n:" .. tostring(v)
    elseif ty == "boolean" then
      parts[#parts + 1] = k .. "=b:" .. (v and "1" or "0")
    elseif ty == "string" then
      parts[#parts + 1] = k .. "=s:" .. v
    end
  end
  return table.concat(parts, "\n")
end

-- Parse a string produced by encode() back into a table. Returns nil for a
-- non-string / empty input; unknown lines are skipped.
function M.decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local t = {}
  for line in s:gmatch("[^\n]+") do
    local k, ty, val = line:match("^(.-)=(%a):(.*)$")
    if k then
      if ty == "n" then t[k] = tonumber(val)
      elseif ty == "b" then t[k] = (val == "1")
      elseif ty == "s" then t[k] = val end
    end
  end
  return t
end

-- Read the per-game save into a table, or nil when there is no save (or the
-- slot holds a non-blob payload, e.g. a legacy State KV save -> State.load()
-- returns a boolean, not our string).
function M.read()
  if not (State and State.load) then return nil end
  local s = State.load()
  if type(s) ~= "string" then return nil end
  return M.decode(s)
end

-- Persist a flat table as the per-game save (replaces any previous save).
-- Returns true on success.
function M.write(t)
  if not (State and State.save) then return false end
  return State.save(M.encode(t)) and true or false
end

-- Cheap "is there a save file" probe (does not read/parse it).
function M.has()
  return (State and State.has_save and State.has_save()) and true or false
end

-- Delete the per-game save. Returns true when no save remains afterwards.
function M.clear()
  if State and State.clear then return State.clear() end
  return false
end

return M
