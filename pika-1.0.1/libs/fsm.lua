-- @sdk/libs/fsm — finite state machine helper
-- Resolve: require("@sdk/libs/fsm")

local M = {}
local FSM = {}
FSM.__index = FSM

function M.new(initial)
  local self = setmetatable({
    state = initial,
    transitions = {},
    on_enter = {},
    on_exit = {},
  }, FSM)
  return self
end

function FSM:add(from, event, to)
  self.transitions[from] = self.transitions[from] or {}
  self.transitions[from][event] = to
  return self
end

function FSM:on(state, enter_fn, exit_fn)
  if enter_fn then self.on_enter[state] = enter_fn end
  if exit_fn then self.on_exit[state] = exit_fn end
  return self
end

function FSM:fire(event)
  local t = self.transitions[self.state]
  if not t or not t[event] then return false end
  local prev, next_state = self.state, t[event]
  if self.on_exit[prev] then self.on_exit[prev]() end
  self.state = next_state
  if self.on_enter[next_state] then self.on_enter[next_state]() end
  return true
end

function FSM:get() return self.state end

return M
