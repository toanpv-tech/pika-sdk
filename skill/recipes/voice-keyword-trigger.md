# Recipe: trigger actions with voice keywords

> **Load when** the game reacts to spoken English command words. Runnable mini pack: the
> manifest, a sound file under the declared path, and `scripts/main.lua` below. Voice is keyword
> spotting, not speech-to-text ([api.md#voice](../../docs/reference/api.md#voice)).

## Rules

- **VOICE-TICK** MUST send keywords from the first `on_tick`, never from the top level or `game_start` — the voice session starts after `game_start` returns and earlier commands are dropped. Check: smoke.py error `VOICE-EARLY`, kit `L-VOICE-EARLY`.
- **VOICE-ONE** MUST call only `Voice.set_keywords` to start listening — it sends the list and starts; `Voice.start` is not needed (idle → `no_keywords` error).
- **VOICE-SWAP** MUST swap words with `Voice.stop()` then `Voice.set_keywords(new)` — a second `set_keywords` while active is refused with `busy` and the old list stays ([open-questions.md](../open-questions.md#q-keyword-swap)).
- **VOICE-CODE** MUST branch on `e.code`: only `connect_failed`, `connect_timeout`, `ws_disconnected`, `ws_error` are fatal, and the robot ends the game for them; the rest continue ([api.md#voice-events](../../docs/reference/api.md#voice-events)).
- **VOICE-BUTTONS** MUST keep the game finishable with buttons when voice is down.
- **VOICE-ALIAS** MUST declare every sound alias the handlers play (here `laser`).

## `manifest.json`

```json
{
  "version": "0.1.0",
  "name": {"vi": "Kích hoạt bằng giọng nói", "en": "Voice trigger"},
  "main": "scripts/main.lua",
  "peripherals": ["display", "button", "audio", "voice"],
  "input": {
    "actions": {
      "confirm": ["button:enter"],
      "left":    ["button:left"],
      "right":   ["button:right"]
    }
  },
  "audio": {
    "sounds": {
      "laser": { "path": "assets/sounds/laser.wav" }
    }
  }
}
```

`"voice"` in `peripherals` is required for a session and makes voice a hard requirement: declare
it only when the game uses voice.

## `scripts/main.lua`

```lua
local KEYWORDS = { "jump", "fire", "stop" }    -- English only
local player, hint
local voice_sent, voice_ok = false, false

local function voice_tick()                    -- once, from on_tick
  if voice_sent then return end
  voice_sent = true
  local ok, reason = Voice.set_keywords(KEYWORDS)
  if not ok then print("voice: " .. tostring(reason)) end
  voice_ok = ok == true
  if hint then hint:show(voice_ok) end
end

local function handle_keyword(kw)
  if kw == "jump" and player then
    local x, y = player:get_pos()
    player:set_pos(x, y - 30)
  elseif kw == "fire" then
    Speaker.play("laser")
  elseif kw == "stop" then
    Engine.exit("voice_stop")
  end
end

function game_start()
  player = Sprite.solid(24, 24, 0x07E0)
  if player then player:set_pos(228, 200) end
  hint = Text.new("Say: jump, fire, stop", 8, 8)
  if hint then hint:show(false) end
end

function on_tick(dt_ms)
  voice_tick()
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "confirm" then handle_keyword("jump")   -- buttons always work
  elseif action == "right" then handle_keyword("fire") end
end

function on_voice_event(e)
  if type(e) ~= "table" then return end        -- raw string past the decoder caps
  if e.type == "VOICE_COMMAND" and type(e.data) == "table" then
    if type(e.data.keyword) == "string" then handle_keyword(e.data.keyword)
    elseif e.data.status == "unavailable" then voice_ok = false end
  elseif e.type == "error" then
    print("voice error: " .. tostring(e.code))
    if e.code ~= "busy" then voice_ok = false end     -- busy: the old list stays
  end
  if hint then hint:show(voice_ok) end
end

function game_end()
  Voice.stop()
end
```

The `VOICE_COMMAND` body (`e.data.keyword`, `e.data.status`) is the server's shape, not yet
confirmed ([q-voice-shape](../open-questions.md#q-voice-shape)); the checks above work either way.

## Check

`python tools/smoke.py <pack> "wait:500,voice:jump,voice:fire,wait:500,voice:stop"` ends
`0 error(s)`, exit 0. Test voice on a robot: smoke.py does not model the voice server (PC-VOICE).
