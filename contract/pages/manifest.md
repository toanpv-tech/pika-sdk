# manifest.json and the pack folder

What the robot reads from a game pack before any Lua runs: the folder, `manifest.json` and
`icon.png`. Every rule below is enforced by the firmware; breaking one either rejects the
pack (it never opens) or is ignored as stated. The Lua calls that use these aliases are in
the [API reference](api.md).

## Pack folder

```text
<game_id>/                 folder name = game id
├── manifest.json          required
├── icon.png               optional menu icon
├── scripts/main.lua       entry script ("main")
├── libs/                  optional, require("libs/<name>")
├── assets/  fonts/        images, strips, animations, sounds, fonts
└── s.json                 added at publish; never create or edit it
```

| Rule | Limit | If broken |
| --- | --- | --- |
| Game id | the folder name, at most {{game_id_chars}} bytes; no leading `.`, no `/`, `\`, `:`, `..` or control characters | pack not found (`PACK_NOT_FOUND`) |
| Menu listing | the robot lists a game only when the server's game list names it and `<game_id>/manifest.json` exists on the SD card | hidden from the menu |
| Menu title | comes from the server's game list, not from the manifest | — |
| Every file | paths as in [API conventions](api.md#conventions); scripts, JSON and media must match `s.json` | pack refused (`VALIDATOR`) |
| Everything in the folder ships | keep demos, sources and notes elsewhere | — |

`icon.png`: optional PNG, at most {{icon_max_file_mib}} MiB and {{icon_max_px}} px per side,
shown in a {{icon_cell_px}} × {{icon_cell_px}} menu cell (scaled to fit, alpha blended).
Without it, or if it cannot be decoded, the menu draws a tinted tile.

## Example

```json
{
  "name": { "vi": "Phiêu lưu cùng Pika", "en": "Pika Adventure" },
  "version": "1.0.0",
  "main": "scripts/main.lua",
  "peripherals": ["voice", "servo", "led", "audio", "button", "display"],

  "input": {
    "actions": {
      "confirm": ["button:enter"],
      "left":    ["button:left"],
      "right":   ["button:right"],
      "any":     ["button:left", "button:enter", "button:right"]
    }
  },

  "audio": {
    "sounds": {
      "coin":  { "path": "assets/sounds/coin.wav" },
      "bgm":   { "path": "assets/sounds/loop.mp3", "loop": true },
      "story": { "remote": true }
    }
  },

  "servos": { "neck": "head", "torso": "base", "arm_l": "left", "arm_r": "right" },
  "poses":  { "hello": "say_hi", "win": "cheer_jump", "sad": "system_error" }
}
```

## Top-level fields

| Field | Type | Required | Used by | Rule |
| --- | --- | --- | --- | --- |
| `main` | string | set it | engine, menu | Entry script, relative to the pack folder, at most {{manifest_main_chars}} bytes (longer is cut and then fails to load). The engine defaults to `scripts/main.lua`, but the menu's detail panel reports `NO_ENTRY` without it and `tools/smoke.py` treats it as an error. |
| `version` | string | no | menu detail panel | Shown to the user. |
| `name` | object `{ "vi", "en" }` (convention) or string | no | engine log (string only) | Pack convention: an object with a Vietnamese and an English title, as in the example and every SD pack. The engine reads `name` only when it is a string (at most {{manifest_name_chars}} bytes, longer is cut) and only for the `pack_load ok` log line, so an object logs `name=""`. The menu title comes from the server's game list, not from this field. |
| `peripherals` | array of strings | no | engine, menu detail panel | See [peripherals](#peripherals). |
| `input` | object | no | engine | See [input](#input). |
| `audio` | object | no | engine | See [audio](#audio). |
| `servos`, `poses` | object | no | engine | See [servos and poses](#servos-and-poses). |

Other keys (`author`, `description`, ...) are ignored. A wrong type in `name`, `version`,
`main` or `peripherals` is ignored as if the field were absent, and so is an `input` that is
not an object (defaults apply). A wrong type in `audio`, `servos` or `poses` rejects the pack.

## peripherals

Values: `"voice"`, `"servo"`, `"led"`, `"audio"`, `"button"`, `"display"`. Only `"voice"`
changes behaviour:

- With `"voice"`, the robot sets up a voice session when the game starts, and ends the game
  if that session cannot be kept (see [Voice](api.md#voice)).
- Without it, there is no voice session: `on_voice_event` never receives keyword events.

The other values are shown in the menu's detail panel. Every binding works regardless of
this list; declare what the pack uses so the list stays true.

## input

```json
"input": { "actions": { "<action>": ["<source>", ...] } }
```

| Rule | Limit |
| --- | --- |
| Sources | `button:enter`, `button:left`, `button:right` |
| Actions | at most {{input_actions_max}} |
| Action name | 1..{{input_action_name_chars}} bytes, unique |
| Sources per action | at least 1; a source may appear in several actions |

- `input` or `input.actions` absent or not an object: three default actions, `confirm`
  (enter), `left` and `right`.
- `input.actions` present but empty (`{}`): no actions, no input events (a warning is logged).
- A button bound to several actions fires `on_input` once per action, in manifest order.
- HOME is never an action; see [on_home](api.md#hooks).

Rejected: an action value that is not an array, an empty array, a source that is not one of
the three tags, an empty, too long or repeated name, or too many actions.

## audio

```json
"audio": { "sounds": { "<alias>": { <source>, "loop": false } } }
```

Each alias has exactly one source:

| Source | Meaning |
| --- | --- |
| `"path": "assets/x.wav"` | File in the pack; must exist at load. |
| `"url": "http://..."` | Remote file with a fixed URL. |
| `"remote": true` | Remote file whose URL the game sets with `Speaker.set_url`; `Speaker.play` returns `false` until then. |

`"loop": true` restarts the sound on completion; it never fires `REASON_COMPLETED`.

| Rule | Limit |
| --- | --- |
| Aliases | at most {{sound_aliases_max}} |
| Alias | 1..{{sound_alias_chars}} bytes, unique |
| `path` | at most {{sound_path_chars}} bytes; no leading `/`, no `\`, no control character, no empty, `.` or `..` segment |
| `url` | `http://` or `https://` (rewritten to `http://` with a warning), printable non-space ASCII, at most {{sound_url_chars}} bytes |

Rejected: `audio` or `audio.sounds` not an object, an entry that is not an object or has no
source or two, a rule above broken, a missing `path` file, or **more than
{{sound_aliases_max}} aliases** (the whole pack fails; nothing is dropped). `audio` absent:
no sounds.

## servos and poses

```json
"servos": { "<alias>": "<joint>" },
"poses":  { "<alias>": "<gesture>" }
```

- `servos` maps an alias to a joint: `head`, `base` (also `body`), `left`, `right`. Used by
  `Servo.move`, `Servo.stop`, `Servo.is_busy`.
- `poses` maps an alias to a built-in gesture, used by `Servo.pose`: `default`, `poke`,
  `talk_random_v1`, `talk_random_v2`, `say_hi`, `raise_both`, `idle_talk_1`, `idle_talk_2`,
  `greeting`, `noaction`, `left_arm_rotate`, `open_menu`, `admiring`, `cheer_jump`,
  `left_wave`, `system_error`.

| Rule | Limit |
| --- | --- |
| Servo aliases | at most {{servo_aliases_max}} |
| Pose aliases | at most {{pose_aliases_max}} |
| Alias | 1..{{sound_alias_chars}} bytes, unique |

Rejected: a block that is not an object, a value that is not a string, an unknown joint or
gesture, an empty, too long or repeated alias, or too many aliases. A block absent: every
`Servo` call with an alias returns `false` (`Servo.stop()` without an argument still works).

## When a pack does not open

The log shows `game.error phase=load` ([Telemetry](telemetry.md#gameerror)); the line
before it names the rule, e.g. `sound 'coin': path too long (70, max 63)`
<!-- number-ok --> or `action 'jump': unknown binding tag 'button:up'`.

| Stage | Cause | `code` |
| --- | --- | --- |
| before Lua | unsafe folder name, no or unreadable `manifest.json`, or one over {{manifest_max_kib}} KiB | `PACK_NOT_FOUND` |
| before Lua | a pack file does not match `s.json` | `VALIDATOR` |
| before Lua | invalid JSON, or an `input`, `audio`, `servos` or `poses` rule broken | `PACK_MANIFEST` |
| Lua | the Lua VM cannot be created (no memory) | `LUA_VM_CREATE` |
| Lua | entry script missing, not matching `s.json`, a syntax error, or precompiled bytecode | `LUA_LOAD` |
| Lua | the entry script's top level or `game_start` raises | `LUA_RUNTIME` (`LUA_WATCHDOG` or `OOM` when that was the cause) |

The menu's detail panel (hold ENTER on a game) shows the same verdicts early: `MANIFEST`,
`NO_ENTRY`, `NO_SCRIPT` or `CRC`.
