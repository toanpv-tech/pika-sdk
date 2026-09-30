# Recipe: localized text (UI language vs learning language)

> **Load when** a game shows text in more than one language, or any non-ASCII text. Runnable
> mini pack: the manifest, a TTF at `fonts/ui-bold.ttf` that covers every character in
> `libs/i18n.lua`, and the two Lua files below.

API: [`Text.new`, `t:set`, `t:set_font`, `t:align`](../../docs/reference/api.md#text),
[fonts](../../docs/reference/api.md#fonts), [`params.language`](../../docs/reference/api.md#params).

## Rules

- **I18N-FONT** MUST ship a TTF that contains every glyph shown — the default font covers little beyond ASCII and a missing glyph renders as a box or nothing. Subset it to the characters used, within the font file limit ([constraints.md](../constraints.md)); check the licence allows embedding.
- **I18N-FACES** MUST stay within (`font_slots` = 4) (path, size) faces; one TTF for every language saves faces.
- **I18N-SPLIT** MUST store strings pre-split with `\n` and in final case — no wrap, no width query; `str:upper()` changes ASCII only. Break only at spaces.
- **I18N-COUNT** MUST count characters with `utf8.len`, not `#` (bytes).
- **I18N-LONGEST** MUST size each label for its longest string across languages; check it in Pika Studio.
- 🧪 Below ~14 px stacked diacritics (Vietnamese ể, ứ) lose strokes; a bold face holds better over busy art (not measured).

## Two languages, two jobs

| Kind | Chosen by | Examples |
| --- | --- | --- |
| **UI language** | `params.language` (ISO 639-1), with a fallback | buttons, instructions, score |
| **Learning language** | the game's content | target words, sentences the child reads or says |

Learning content does not follow `params.language`. Voice keywords are English, and the word
on screen must be the exact string passed to `Voice.set_keywords`.

## `manifest.json`

```json
{
  "version": "0.1.0",
  "name": {"vi": "Chữ đa ngôn ngữ", "en": "Localized text"},
  "main": "scripts/main.lua",
  "peripherals": ["display", "button"],
  "input": { "actions": { "confirm": ["button:enter"] } }
}
```

## `libs/i18n.lua`

```lua
-- UI strings only, pre-split with "\n", already in display case
return {
  vi = { title = "HỨNG SAO", start = "Nhấn ENTER\nđể chơi" },
  en = { title = "STAR CATCH", start = "Press ENTER\nto play" },
}
```

## `scripts/main.lua`

```lua
local I18N = require("libs/i18n")
local FONT = "fonts/ui-bold.ttf"        -- covers every glyph in I18N
local SIZE_TITLE, SIZE_BODY = 26, 18    -- faces: 2 of 4
local T
local labels = {}                       -- keep every handle referenced

local function label(str, size, dy)
  local t, err = Text.new(str, 0, 0)
  if not t then print("Text.new failed: " .. tostring(err)); return nil end
  local ok, msg = t:set_font(FONT, size)
  if ok == nil and msg then print("set_font failed: " .. tostring(msg)) end
  t:align("center", 0, dy)
  labels[#labels + 1] = t
  return t
end

function game_start(params)
  T = I18N[params.language] or I18N.en
  label(T.title, SIZE_TITLE, -40)
  label(T.start, SIZE_BODY, 30)
end

function on_tick(dt_ms) end

function on_input(action, phase, hold_ms) end
```

`tools/check_spec.py` checks demo text against the shipped font at stage S3.

## Check

`python tools/smoke.py <pack>` and `python tools/smoke.py <pack> --language vi` (once per
language the game supports) both end `0 error(s)`, exit 0 (with the TTF present); then read every
language in Pika Studio (`params.language`).
