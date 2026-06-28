-- examples/hello — minimal HUD + Input + single-line selector (engine_level 1)
-- Copy this folder to <pub>/<game>/ to make it appear in the browser.
-- Callbacks are GLOBAL functions the engine calls; there is no `Game` table.

local ui = require("@sdk/libs/ui")

local menu

function game_start(level_json)
  menu = ui.selector({ "Play", "About", "Quit" })
  menu:render()
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "next" then
    menu:next():render()
  elseif action == "prev" then
    menu:prev():render()
  elseif action == "fire" then
    local item = menu:current()
    if item == "About" then
      HUD.set_label("Pika SDK hello example")
    elseif item == "Quit" then
      Engine.exit()
    else
      HUD.set_label("Playing: " .. item)
    end
  end
end

function on_tick(dt_ms) end

function game_end() end
