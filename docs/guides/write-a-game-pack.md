# Write a Lua game pack

> **For:** developers, or anyone directing an AI assistant · **Needs:** [Getting started](../start/getting-started.md) · **Result:** a Lua pack that passes smoke (stages S4–S5)

A **game pack** is a folder the Pika Engine loads into a fresh, sandboxed Lua 5.5 VM; the
engine calls your **hooks** every frame and you drive the robot through a closed set of
globals. This guide is the shape of a pack and the habits that make it run on the robot the
first time. Every call is in the [API reference](../reference/api.md), every manifest rule in
[manifest.json](../reference/manifest.md). Starting from a browser demo? Read
[Port a demo](port-a-demo.md) too.

## Start from a template

Copy the closest starting point instead of a blank folder:

| Start from | When |
| --- | --- |
| `skill/templates/minimal-game/` | one screen, a few objects |
| `skill/templates/structured-game/` | several scenes, rules split from wiring, a leaderboard |
| an example in `examples/` | the same engine area (`test_button`, `test_font`, `test_audio`, `test_voice`, `pick_word`) |

Reuse `libraries/` (state machine, tweens, easing, UI selector, settings screen, utils):
copy a module and its dependencies into your pack's `libs/` and `require("libs/<name>")`.

## A minimal pack

`manifest.json`:

```json
{
  "version": "1.0.0",
  "main": "scripts/main.lua",
  "input": { "actions": {
    "confirm": ["button:enter"], "left": ["button:left"], "right": ["button:right"] } },
  "audio": { "sounds": { "ok": { "path": "assets/sounds/ok.wav" } } }
}
```

`scripts/main.lua` (ship a WAV at `assets/sounds/ok.wav`):

```lua
local label

function game_start(params)
  local err
  label, err = Text.new("Press ENTER", 16, 16)
  if not label then error("Text.new: " .. tostring(err)) end  -- raise only while loading
end

-- Hooks are globals defined at the top level: on_tick and on_input are bound once, at load.
function on_input(action, phase, hold_ms)
  if action == "confirm" and phase == Input.PRESS then
    label:set("Pressed ENTER")
    if not Speaker.play("ok") then print("ok not played") end
  end
end

function on_tick(dt_ms)
end
```

## Habits that decide whether it runs

1. **Only contract names.** A call that is not in the [API reference](../reference/api.md)
   does not exist on the robot. [Calls that do not exist](../reference/api.md#calls-that-do-not-exist)
   lists the usual inventions.
2. **Hooks at the top level; state inside.** Define every hook once, at the top level of the
   entry script, and switch scenes with a state variable. Reassigning `on_tick` later is
   ignored ([hooks](../reference/api.md#hooks)).
3. **Time from `Timer.millis()`**, never by adding `dt_ms` ([timing](../reference/api.md#timing)).
4. **Check every return.** Factories return `nil, reason`; peripherals return `false`; some
   setters return `nil, reason` on failure. Raise only in `game_start`; an error in
   `on_tick`, `on_input` or `on_sound_end` ends the game, so degrade instead (hide the
   element, skip the frame). See [failure modes](../reference/api.md#conventions).
5. **Keep a reference to every handle**, or garbage collection removes it from the screen.
6. **Integer coordinates**: round computed positions with `math.floor(x + 0.5)`.
7. **Start voice from `on_tick`**, never from `game_start` ([Voice](../reference/api.md#voice)).
8. **Buttons must always be enough.** Voice, ranking and sound completion may never arrive;
   every wait has a `Timer.millis()` timeout.
9. **Nothing heavy per frame.** Load assets in `game_start` or on a scene change, spread big
   loads over several frames, and change engine state only when it changed. The cost model
   and patterns are in [skill/performance.md](../../skill/performance.md).

## Check it

Run the [S5 gate](../reference/pipeline.md#gates) with steps that reach every branch, until it
passes. Smoke runs your pack in real Lua 5.5 against a stub built from the contract and
reports invented calls, undeclared sounds and actions, pool overflows, voice sent too early
and errors in hooks. It does not draw, play sound or measure time: play it in Pika Studio
(S6), and prove speed on a robot (S9). Before calling the game done, work through the
[release checklist](release-checklist.md).
