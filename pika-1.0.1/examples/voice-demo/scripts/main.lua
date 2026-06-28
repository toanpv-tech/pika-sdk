-- examples/voice-demo — speech recognition via Voice (engine_level 7)
--
-- ASSET REQUIRED: none on the SD card, but this needs the BACK board plus an
-- active server voice session. Without them Voice.start fails or no events
-- arrive. The config schema is defined by the server; the documented STT form
-- is used here (see Lua/P5c-Voice-Plan.md §B.1).

function game_start(level_json)
  HUD.set_label("ENTER = talk, LEFT = stop")
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "fire" then
    local ok, reason = Voice.start({ type = "start", task = "speech_recognition" })
    if not ok then HUD.set_label("voice start fail: " .. tostring(reason)) end
  elseif action == "prev" then
    Voice.stop()
    HUD.set_label("stopped")
  end
end

-- The engine marshals the server's JSON frame into a Lua table (not a string).
function on_voice_event(e)
  if e.type == "state" then
    if e.state == "listening" then HUD.set_label("Listening...") end
  elseif e.type == "transcript" then
    HUD.set_label(e.text or "")
  elseif e.type == "score" then
    HUD.set_label("Score: " .. tostring(e.score))
  elseif e.type == "error" then
    HUD.set_label("voice err: " .. tostring(e.code))
  end
end

function on_tick(dt_ms) end

function game_end() Voice.stop() end
