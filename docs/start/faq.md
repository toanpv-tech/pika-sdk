# Frequently asked questions

Short answers to what developers ask first. Each answer links to the page that owns the
fact; when the two disagree, the linked page is right.

## Tools and setup

### Can I build a game without a robot?

Yes, up to publishing. Sketch in the browser with the [kit](../guides/design-a-demo.md), write
the Lua pack and run `python tools/smoke.py <pack>`, then play it in Pika Studio, which runs
the real engine compiled for a PC. Speed, HOME, LED, servos, real voice and `s.json` are only
proven on a robot: [PC vs robot](../reference/known-issues.md#pc-vs-robot).

### Can I build it with an AI assistant?

Yes. Point the assistant at [skill/SKILL.md](../../skill/SKILL.md) and follow
[Vibe-code a game](../guides/vibe-coding.md).

### What is the fastest way to a first game?

Open this SDK folder in your AI editor and paste
[prompt E](../templates/prompts.md#e-quick-first-game): Lua directly from a template,
placeholder art, buttons only. Then play it in Pika Studio.

In Claude Code, type `/pika-game <your idea>` instead: it agrees a short plan with you, then
its `pika-game-maker` agent writes the pack under `games/` and runs the smoke check until it
passes.

### Which firmware does this SDK match?

The firmware does not report an API version. Use the latest `sdk_version`; the maintainers
prove a match with `tools/gen_contract.py --check` ([README](../../README.md#versioning)).

## Lua and the sandbox

### Which Lua, and which libraries?

Lua 5.5 with `string`, `table`, `math` and `utf8`. There is no `io`, `os`, `load`, `debug`,
`package` or `coroutine`, and `require` only loads `libs/<name>` from your own pack:
[Sandbox](../reference/api.md#sandbox). Reusable modules to copy into `libs/` are in
[libraries/](../../libraries/README.md).

### My numbers overflow or `set_pos` raises on the robot but not on my PC

Integers are 32-bit on the robot (`lua_int_bits` = 32), and integer arguments reject
fractions such as `10.5`. Round with `math.floor(x + 0.5)`:
[Conventions](../reference/api.md#conventions).

### Where may I call `error()`?

Only in `game_start`, to reject bad data at load. An error in `on_tick` or `on_input` ends the
game: [Hooks](../reference/api.md#hooks).

### A call from another engine or an old document does not exist

The robot has no `Engine.now_ms`, `State.save`, `Timer.after`, `spr:rotate` and so on. <!-- not-an-api -->
The replacement for each is in [Calls that do not exist](../reference/api.md#calls-that-do-not-exist).

## Lifecycle and timing

### Which hooks are there?

`game_start(params)`, `on_tick(dt_ms)`, `on_input(action, phase, hold_ms)`, `on_home()`,
`game_end()` and the sound and voice events: [Hooks](../reference/api.md#hooks). Define
`on_tick` and `on_input` at the top level of the entry script; assigning them later is
ignored.

### My timers run fast or slow

`dt_ms` is always the nominal value (`dt_ms` = 33) while frames are
(`tick_period_ms` = 30) apart. Use `Timer.millis()` for anything time-based:
[Timing](../reference/api.md#timing).

### How does my game end?

Call `Engine.exit()` and `return` from the hook; `game_end()` then runs during teardown:
[Engine](../reference/api.md#engine).

### How do I know the player's language?

Read `params.language` in `game_start(params)`: [params](../reference/api.md#params). Ship a
font that covers that language's glyphs ([Text and fonts](../guides/prepare-assets.md#5-text-and-fonts)).

## Buttons and HOME

### Which buttons can I use?

Left, enter and right, mapped to your own action names in the manifest:
[input](../reference/manifest.md#input). Without an `input` block the actions are `confirm`,
`left` and `right`.

### How do I detect a long press?

Holding a button sends `Input.REPEAT` after (`button_repeat_delay_ms` = 400), then every
(`button_repeat_rate_ms` = 80); `hold_ms` is 0 until the first repeat and keeps the release
value after release: [Input](../reference/api.md#input). The browser kit does the same.

### Does HOME always quit my game?

A short press calls `on_home()`; return a truthy value to keep the game, for example to show a
pause screen. Holding HOME for (`home_force_exit_ms` = 1500) always exits:
[Hooks](../reference/api.md#hooks).

## Graphics

### Which image formats?

PNG for sprites (alpha allowed), `.rgb565` for large opaque images, GIF or MJPEG for
animations. How to choose and convert: [Prepare assets](../guides/prepare-assets.md#1-pick-the-format).

### How many sprites and labels can I have?

Sprites are limited only by free image memory; labels are not: there are
(`text_slots` = 8) Text slots, (`line_slots` = 8) lines and (`font_slots` = 4) fonts.
Reuse labels instead of creating new ones: [Limits](../reference/api.md#limits).

### A sprite covers my text

Text and sprites share one stacking order, and `set_z` clamps a large value to the top, so a
sprite raised with a big `set_z` hides every label. Create labels last or keep `set_z`
values small: [Sprite](../reference/api.md#sprite).

### Can I rotate or scale an image?

Only small ones: `set_rotation` and `set_scale` need both sides at most
(`transform_max_px` = 96): [Transform limit](../reference/api.md#transform-limit).

### My game drops frames

Read the `game.running` line of the robot log: [Telemetry](../reference/telemetry.md#frames).
Spread image loads over several ticks instead of loading everything in one hook.

## Sound

### Which audio formats?

WAV or MP3, declared as aliases in the manifest and played with `Speaker.play("<alias>")`:
[audio](../reference/manifest.md#audio) and [Audio](../guides/prepare-assets.md#7-audio). More
than (`sound_aliases_max` = 64) aliases rejects the whole pack.

### Some of my sounds do not play or are cut off

There is one sound channel: a new `Speaker.play` stops the current sound, and a play within
(`sound_cooldown_ms` = 150) of the previous one returns `false`: [Speaker](../reference/api.md#speaker).

### Can I play a sound from the internet?

Yes, with `url` or `remote` in the manifest: [audio](../reference/manifest.md#audio).

## Voice

### How does voice input work?

English keyword spotting, not free speech: send a short list with `Voice.set_keywords`, which
also starts listening, and read the result in `on_voice_event`: [Voice](../reference/api.md#voice).

### I send keywords but nothing is ever heard

Voice commands sent from the top level or `game_start` are dropped. Send them from `on_tick`:
[Voice](../reference/api.md#voice).

### Should I list `"voice"` in `peripherals`?

Only if the game needs voice. Once listed, voice is required: if the robot cannot keep the
voice connection, the game ends: [peripherals](../reference/manifest.md#peripherals).

## Saving and network

### How do I save a high score or progress?

Nothing persists between sessions and Lua cannot write files. Keep scores on the leaderboard
with `Ranking.report` and read it back with `Ranking.get_result`: [Ranking](../reference/api.md#ranking).

### Can I make HTTP requests from Lua?

No. The only network features are sounds from a URL ([audio](../reference/manifest.md#audio)),
the leaderboard ([Ranking](../reference/api.md#ranking)) and, inside a talk-flow session
(`params.is_a2a`), `Engine.report_result{event = ...}` ([Engine](../reference/api.md#engine)).

## Packaging and release

### What is `s.json` and do I create it?

No. It is the integrity file the robot checks before a pack runs, and the Pika platform issues
it when you publish. Any change after that means publishing again:
[Release checklist](../guides/release-checklist.md#b-publish).

### How do I name the folder, the files and the game?

The folder name is the game id, at most (`game_id_chars` = 31) bytes. Keep file names
lowercase ASCII: [File names](../guides/prepare-assets.md#8-file-names). In `manifest.json`
write `"name": {"vi": "...", "en": "..."}`; the menu title itself comes from the server's
game list: [Top-level fields](../reference/manifest.md#top-level-fields).

### My game does not show in the menu or does not open

The menu lists a game only when the server's list names it and its `manifest.json` is on the
SD card: [Pack folder](../reference/manifest.md#pack-folder). For a pack that is listed but
fails to start, see [When a pack does not open](../reference/manifest.md#when-a-pack-does-not-open).

### Pika Studio says `bad absolute path` / `PACK_MANIFEST`, but my paths look right

The games folder path is too long for the engine's path buffers on a PC; the same pack runs on
the robot. Keep it at most (`pc_games_root_chars` = 63) characters, for example
`E:/pika-games`, and clone the SDK to a short path if your packs live in its `games/`.
`tools/smoke.py` warns `PC-ROOT-LEN` when the folder is too deep:
[PC vs robot](../reference/known-issues.md#pc-vs-robot).

### Does everything in my folder ship?

Yes. Keep drafts, source art and archives out of the pack folder:
[Release checklist](../guides/release-checklist.md).

## Debugging on the robot

### My game exits by itself

Attach a serial monitor and read the `game.error` and `game.stop` lines:
[Telemetry](../reference/telemetry.md#the-lines). Symptoms with their causes are listed in
[skill/pitfalls.md](../../skill/pitfalls.md).
