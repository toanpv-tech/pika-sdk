---
name: pika-game
description: Build, port or fix a game for the PIKA robot's Pika Engine (Lua 5.5, 480x320 screen, three buttons + HOME, one sound channel, English keyword voice). Use for "make a Pika game", "browser demo for the robot", "port this demo to Lua", "why does my pack fail on the robot", "review this robot log".
version: 2.0.0
entry: SKILL.md
index: skill.index.json
---

# Skill: build a Pika robot game

> **Audience: an AI coding assistant.** People start at [../docs/README.md](../docs/README.md).
> Goal: a pack that runs on the real engine the first time, uses no invented API, and is
> proven by tool output, not by claims.

## 1. Golden rules

Each rule: **ID** MUST/NEVER — why. *Check:* how it is caught.

| ID | Rule | Why | Check |
| --- | --- | --- | --- |
| G1 | NEVER call a name that is not in [`../contract/api.json`](../contract/api.json) | the list is generated from the firmware and closed; anything else raises on the robot | smoke `API` (error on a call; reading gives `nil` + warning), kit `L-API` |
| G2 | NEVER state a limit from memory; take it from [constraints.md](constraints.md) | remembered numbers are the usual source of wrong code | review |
| G3 | MUST let the engine own the loop: hooks only; no `while true`, sleep or busy-wait | a hook that does not return trips the watchdog and ends the game | kit `L-WDOG`, `L-ASYNC`; robot `LUA_WATCHDOG` |
| G4 | MUST define `on_tick` and `on_input` at the top level; NEVER reassign a hook | they are bound once at load; a later assignment is ignored | smoke `HOOK-REBIND`, kit `L-HOOK-REBIND` |
| G5 | NEVER call `Voice.*` from the top level or `game_start`; start voice in the first `on_tick` | the robot drops voice commands sent before `game_start` returns | smoke `VOICE-EARLY`, kit `L-VOICE-EARLY` |
| G6 | MUST keep a reference to every handle | an unreferenced Sprite/Text/Shape/Anim is garbage-collected off the screen | smoke `HANDLE-GC` |
| G7 | MUST check every return value; raise only in `game_start` | factories return `nil, reason`; an error in `on_tick`, `on_input` or `on_sound_end` ends the game | review; smoke run |
| G8 | MUST pass integers where the API says integer (coordinates, sizes, frames) | a fractional number raises | kit `L-INT`; smoke run |
| G9 | MUST time everything with `Timer.millis()` differences, never by summing `dt_ms` | `dt_ms` is nominal ([KI-DT-NOMINAL](../docs/reference/known-issues.md#ki-dt-nominal)) | review |
| G10 | MUST keep the game playable with buttons only; every wait has a timeout | voice, ranking and sound completion may never arrive | release checklist |
| G11 | NEVER create or edit `s.json`; NEVER claim robot speed from a PC run | `s.json` is issued at publish; only robot telemetry measures speed | review |
| G12 | MUST say so when a capability is missing, and propose an alternative | a faked feature fails on the robot | review |
| G13 | MUST prove each stage with the tool's pasted output | "it works" without output is not a gate | the [pipeline](../docs/reference/pipeline.md) gates |

## 2. Route

| The user wants | Mode | Stages | Load, besides `always` |
| --- | --- | --- | --- |
| to try an idea / a playable mock-up in the browser | **A. Demo** | S3 | [demo-kit.md](demo-kit.md) |
| a Lua game directly | **B. Lua** | S4–S5 | §3–§5 below; the recipes that match |
| to turn a kit demo + `pika-spec.json` into a pack | **C. Port** | S4–S5 | [porting.md](porting.md) |
| to fix a failure, or read a robot log | **D. Diagnose** | S5–S9 | [pitfalls.md](pitfalls.md), [../docs/reference/telemetry.md](../docs/reference/telemetry.md) |

Unsure? Ask. Prefer A → C for games with several screens, custom art or recorded voice
lines. Before coding a new game, answer the seven questions of
[prompt A](../docs/templates/prompts.md#a-start-a-game-from-a-brief) and wait for the user.

| Load | When | File |
| --- | --- | --- |
| `always` | every task | this file, [api-contract.md](api-contract.md), [constraints.md](constraints.md), [lua-language.md](lua-language.md) |
| `on_demo` / `on_port` | mode A / mode C | [demo-kit.md](demo-kit.md) / [porting.md](porting.md) |
| `on_manifest` | writing `manifest.json` | [../docs/reference/manifest.md](../docs/reference/manifest.md) |
| `multi_scene` | several screens, or over ~300 lines | [game-architecture.md](game-architecture.md), [templates/structured-game/](templates/structured-game/) |
| `many_objects` | many sprites, big art, frame drops | [performance.md](performance.md) |
| `on_require` | using `require` | [libs-catalog.md](libs-catalog.md) |
| `on_error` | any failure or odd behaviour | [pitfalls.md](pitfalls.md), [../docs/reference/known-issues.md](../docs/reference/known-issues.md) |
| `on_warning` | a ⚠️ label, or a fact the contract does not settle | [open-questions.md](open-questions.md) |
| recipe | the task matches one | [recipes/](recipes/) (listed in [skill.index.json](skill.index.json) with their triggers) |

## 3. Pack and manifest

```text
<game_id>/                 folder name = game id (snake_case)
├── manifest.json          required; set "main"
├── icon.png               optional menu icon
├── scripts/main.lua       entry
├── libs/                  optional, require("libs/<name>")
├── assets/  fonts/        images, strips, animations, sounds, TTF fonts
```

- `input.actions` maps your action names to `button:left|enter|right`; `Input.*` and
  `on_input` use them. HOME is not an action: it calls `on_home()`.
- Every sound is an alias in `audio.sounds` with exactly one of `path`, `url`, `"remote": true`.
  A missing file or too many aliases rejects the **whole** pack.
- List `"voice"` in `peripherals` if the game calls `Voice.*`.
- `servos` / `poses` map aliases for `Servo.*`.
- Full rules and rejection reasons: [../docs/reference/manifest.md](../docs/reference/manifest.md).

## 4. Minimal game

Commented copy: [templates/minimal-game/](templates/minimal-game/). Several scenes:
[templates/structured-game/](templates/structured-game/).

```lua
local player                                   -- keep every handle referenced (G6)

function game_start(params)
  local err
  player, err = Sprite.solid(24, 24, 0x07E0)   -- RGB565 green; hidden until placed
  if not player then error("Sprite.solid: " .. tostring(err)) end
  player:set_pos(228, 280)
end

function on_tick(dt_ms)                        -- top level, never reassigned (G4)
  local x, y = player:get_pos()
  if Input.is_down("left") then x = math.max(0, x - 3) end
  if Input.is_down("right") then x = math.min(456, x + 3) end
  player:set_pos(x, y)
end
```

Poll `Input.is_down` for movement; use `on_input` with `Input.PRESS` for discrete actions.

## 5. Reuse before writing

[`../libraries/`](../libraries/libs.index.json) ships a state machine, tweens, easing, a UI
selector, a settings screen and utilities; exact functions in [libs-catalog.md](libs-catalog.md).
Copy a module and its dependencies into `<game>/libs/`, then `require("libs/<name>")`.
Working packs: [`../examples/`](../examples/examples.index.json) (`pick_word` pairs with
`../kit/template/`).

## 6. Self-check, then hand over

1. Run the S5 gate from the SDK root with a step list that reaches every branch, and paste the
   **full** output:

   ```bash
   python tools/smoke.py <pack> "wait:1200,enter,wait:600,right,wait:600,left,enter,wait:1500,restart,home"
   ```

   Pass: exit 0 and a last line `0 error(s), N warning(s)`. Explain every warning.
2. Check by hand what smoke cannot:
   - [ ] no hook can come near the watchdog; big loads are spread across frames;
   - [ ] live `Text` ≤ `text_slots` minus headroom, font faces ≤ `font_slots`, sprite PSRAM budgeted;
   - [ ] every wait has a `Timer.millis()` timeout; the game finishes with buttons only;
   - [ ] HOME: `on_home` does what the brief says.
3. Tell the user what to press in Pika Studio (S6) to reach every branch, that the pack runs
   on a robot only after it is published (S8), and that speed is proven only there (S9).
