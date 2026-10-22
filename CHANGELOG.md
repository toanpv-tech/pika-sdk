# Changelog

Release history of the **Pika SDK**. Every release (a commit that bumps
`sdk_version`) adds an entry at the top.

Versions follow [SemVer](https://semver.org/) on the **API contract the SDK is
written against**, not on how many files changed:

| Bump | When |
| --- | --- |
| **MAJOR** | A Lua API, hook or manifest key is changed or removed — old game packs must be edited to run |
| **MINOR** | An API, binding, library, example or tool is added, or docs are corrected to match the engine |
| **PATCH** | Typos, broken links, wording — no contract change |

The firmware does not report an API version yet; `tools/gen_contract.py --check` is what
proves the SDK matches a firmware build — see [README](README.md#versioning).

Change kinds: `Added` · `Changed` · `Removed` · `Fixed` · `Docs`.
Entries before 1.2.0 are in Vietnamese.

---

## Unreleased

Docs re-verified against the firmware on `dev` after audio v2 (3ec73958), `Telemetry.event`
(9e898fdb) and ON/OFF-in-game (76d5ee41); the SDK becomes a Claude Code plugin marketplace
with two plugins and the game agents; `test-packs/` becomes a set of single-feature robot test
packs, one per public Lua global, and smoke.py models the calls they test the way the firmware
does. An API, AI tools, examples, a library function, tools and checks were added and
docs were corrected to match the engine; no API, hook, manifest key or limit changed or was removed.

### Added

- `test-packs/test_<global>` for every public global: `test_input`, `test_speaker`, `test_text`,
  `test_sprite`, `test_anim`, `test_shape`, `test_led`, `test_servo`, `test_voice`,
  `test_telemetry`, `test_ranking`, `test_timer`, `test_engine`. Each pack covers argument
  guards, return values and failure values, timed behaviour, and on-screen or on-robot checks
  the operator confirms (ENTER = right, RIGHT = wrong). UART lines read
  `<tag> [NN/NN] PASS|FAIL|SKIP group :: case :: detail`. Rows that end the game are manual.
  All use Nunito (OFL, `fonts/OFL.txt`).
- `libs/testkit` `tk.suite(opts)`: three-button test menu, RUN SUITE / Reset rows, sync and
  async tests under `pcall`, `S:look` operator checks, `manual`, `fullscreen`, `"skip"`, one
  `Text` HUD. The earlier `expect` / `reg_sync` / `run_sync` functions are unchanged.
- `test-packs/examples.index.json`: `covers` (globals and hooks a pack tests) and `needs`
  (robot, operator, network, voice-server) per entry.
- `tools/gen_tel_vectors.py`: builds `test-packs/test_telemetry/libs/tel_vectors.lua` from
  `contract/telemetry_vectors.json`; `--check` reports drift.
- `tools/check_docs.py` check 11: every public global has an `test-packs/test_<global>` pack that
  lists it in `covers`; every pack's `libs/testkit.lua` equals `libraries/testkit.lua`;
  `tel_vectors.lua` is up to date.
- `.claude-plugin/marketplace.json` (`pika-sdk`): plugin `pika-game` for every game developer
  (source: the SDK root, so agents read `knowledge/`, `tools/` and `contract/` at
  `${CLAUDE_PLUGIN_ROOT}` and write packs in `games/<id>/` of any folder) and plugin
  `pika-sdk-maintainer` for the Pika team (`plugins/pika-sdk-maintainer/`). Install with
  `/plugin install pika-game --marketplace toanpv-tech/pika-sdk`.
- `agents/pika-game-tester.md`: independent tester; branch-covering smoke runs per UI
  language, serial log scoring, PASS / FAIL / BLOCKED with a JSON block; never edits the pack.
- `agents/pika-game-cleaner.md` (clean-code agent): walks `knowledge/review-checklist.md` in mode `light` or `full`,
  applies only behaviour-preserving fixes, defers the rest; reruns smoke.
- `agents/pika-game-optimizer.md`: works from a robot log; classifies the symptom, applies the
  `knowledge/frame-budget.md` patterns in cut order without changing gameplay, marks each change
  `-- perf:`, proves logic with smoke and asks for a new robot log; BLOCKED without a log.
  The porter no longer diagnoses robot logs.
- `knowledge/review-checklist.md` REVIEW-PERF-MARK: measured optimizations carry `-- perf:`, and a
  cleanup keeps their shape.
- Performance lessons from the team's shipped packs, each checked against the engine source:
  `knowledge/performance.md` PERF-COUNT (factory calls per hook; `Sprite.image` of a path a live
  sprite uses shares its pixels, `Sprite.new` always reads), PERF-RESTACK (a changed `set_z` /
  `to_front` / Shape line repaints the whole screen), PERF-PIXELS (`set_opacity` is never
  compared; fewer changed pixels per frame), PERF-FILES (every pack file is checked at launch),
  lazy creation with its two traps, pools by file and the PSRAM peak across scenes;
  `knowledge/frame-budget.md` BUDGET-SCENE, per-scene tick timing and a symptoms-to-patterns table;
  `knowledge/pitfalls.md` P36 (`set_z` clamp and runs of objects sent to one position).
- `evals/agent-cleaner-routes`, `evals/agent-tester-routes`: scaffolded with a small pack that
  has deliberate clean-code findings (`fixture.sh`, run with `--scaffold`).
- `skills/pika-test` (`/pika-test`): runs the tester on a pack and an optional log.
  `skills/pika-engine`: answers Pika Engine questions from the SDK instead of memory.
- `plugins/pika-sdk-maintainer/skills/pika-sdk-release` (`/pika-sdk-release`): the release
  gates and one version for `sdk_version`, `sdk.index.json` and both plugins.
- `tools/check_robot_log.py`: scores a robot or Pika Studio serial log against the release
  checklist's telemetry gates (FAIL on hard rules, WARN on heuristics, INCONCLUSIVE when the
  log cannot decide; exit 0 / 1 / 3).
- `tools/check_docs.py` check 13: plugin versions equal `sdk_version`; agent and skill names
  match their files; adapters name no engine API; every SDK path they quote exists.
- `evals/`: `claude plugin eval` cases for the tester, cleaner, log scoring, engine facts and a
  negative generic-Lua case. `.githooks/pre-commit`: plugin validate, contract and docs checks.
- `agents/pika-game-porter.md`: ports a brief (art + design doc + a demo, kit-based or
  not) to `games/<id>/`, stopping after intake, fit and budget for approval; diagnoses robot
  frame drops; costs engagement ideas. Workflow only, like `pika-game-maker`.
- `knowledge/port-from-brief.md` (BRIEF-*): inventory, parity table, scale factor, layout tables
  with the longest string, control mapping, approval stop, missing API reported to the Pika team.
- `knowledge/frame-budget.md` (BUDGET-*): planned-vs-measured worksheet mapped to limit keys and
  telemetry fields, cut order, robot-log diagnosis steps, verdict.
- `knowledge/juice.md` (JUICE-*): costed engagement backlog; servo duty, LED range and one sound
  channel as the limits of robot reactions.
- `knowledge/review-checklist.md` (REVIEW-*): hand-over review, each engine rule linked to its owner.
- `knowledge/performance.md`: allocation-free per-frame code.
- Load values `on_brief`, `on_budget`, `on_juice`, `on_review` in `knowledge/skill.index.json` and
  the `knowledge/SKILL.md` load table.
- `Telemetry.event` / `Telemetry.caps`, `libs/tel` (listed in the library catalog and README),
  `contract/telemetry_vectors.json` and `tools/check_telemetry.py`.
- New contract keys read from firmware: body-board servo clamps and duty limit
  (`servo_*`), `button_click_debounce_ms`, `show_hold_max_s`, `exit_defer_ms`,
  `text_dedup_max_len`, `tel_pv_max`, `servo_pose_busy_ms`, `rank_result_buf_max`, `todo_root`.
- Known issues KI-SOUND-QUEUE, KI-STOPALL-PLAY, KI-SOUND-CUT; PC-vs-robot rows PC-SOUND and
  PC-STUB.

### Changed

- `skill/` renamed to `knowledge/` so it is not confused with `skills/` (Claude Code
  commands); `sdk.index.json` section `knowledge`. File names inside are unchanged.
- `AGENTS.md` (with `CLAUDE.md` importing it) at the root: where an AI assistant starts, which
  files are generated, and the check commands.
- `examples/` renamed to `test-packs/`: the packs test one API each and are not game examples.
  `sdk.index.json` keeps the section key `examples` and `test-packs/examples.index.json`, which
  Pika Studio reads.
- `knowledge/templates/` moved to `starters/` (new `sdk.index.json` section `starters`), the
  game skeletons to copy into `games/<id>/`.
- smoke.py follows the firmware where it used to simplify (each change cites its binding):
  - methods on a value that is not that kind of handle raise; Text and Shape support `<close>`;
  - Sprite: integer and number arguments are checked, `set_pivot` outside -480..960 x -320..640
    returns `false`, `Sprite.new` with a size of 0 returns `nil`, `Sprite.solid` needs its
    colour, a destroyed sprite reads 0, 0 and its boolean calls return `false`;
  - Text: `str`, `where` and `path` follow `luaL_checkstring`, `set_color` needs an integer,
    a destroyed label returns `nil, msg` from `align` / `set_font`;
  - Shape: coordinate range, strict style table, bbox (pad 4 + half the width) and the 256 KiB
    raster budget, `set_points` / `set_style` return nothing on success and `nil, reason` on a
    refusal;
  - Anim: extension checked before the path, a file that is not a GIF / JPEG returns `nil`,
    `play(1)` is a one-shot, MJPEG ends after one engine frame per JPEG;
  - Led: non-number arguments return `false`, `is_available` is `false` before the game runs,
    `get_brightness` mirrors `set_brightness` (rounded), the 8-slot ring with set() merging,
    `Led.stats`;
  - Servo: angle, duration and easing checks, `body` maps to the base joint, `is_busy`
    predictions, the 32-slot ring with move merging, `Servo.stats` (body-board rejects stay 0);
  - Speaker: `set_volume` / `get_volume`, `played_total` and `cooldown_reject` counters, every
    `Speaker.stats` field;
  - Engine: `report_result` raises on a non-table and rejects an empty or over-255-byte event,
    `Engine.show` holds and releases the loading screen like the engine;
  - Ranking: a numeric-string score is accepted.
- The S0 gate is `python tools/smoke.py test-packs/test_input`.
- `docs/guides/port-a-demo.md`, `design-a-demo.md`, `getting-started.md` and `knowledge/porting.md`
  pair the kit demo with `starters/minimal-game/`.
- `knowledge/SKILL.md`: mode C covers a brief as well as a kit demo; mode D links frame-drop
  diagnosis; an engagement route; the self-check starts with the review checklist.
- `knowledge/porting.md`: a demo not built on the kit goes through `port-from-brief.md`.
- `/pika-game` runs the loop: maker or porter builds, cleaner `light`, tester; FAIL returns to
  the builder (three rounds at most); PASS → cleaner `full` → tester regression.
- `.claude/agents/` and `.claude/skills/` moved to `agents/` and `skills/` (plugin layout); the
  adapters now work from the installed plugin in any folder, not only inside an SDK clone.
- `MAINTAINING.md`: plugin layout, roles, decision rights and how to add an agent.
- `README.md`, `docs/start/faq.md`: install the plugin instead of opening the SDK folder.

### Removed

- `lua-5.5.0/`: nothing in the SDK built or read it (smoke.py runs lupa; Pika Studio and the
  firmware build `head_esp32/components/lua-5.5.0`). `tools/gen_contract.py` still reads the
  robot's Lua build flags from the firmware into the contract.
- `test-packs/pick_word`, `test_button`, `test_audio`, `test_font` (replaced by the packs above).

### Fixed (tools)

- `smoke.py` and `smoke_stub.lua` give a pack without `input.actions` the engine's default
  actions (`confirm`, `left`, `right`) instead of reporting `error ACTION`.

### Fixed (documented behaviour that was wrong)

- **Speaker:** a new `Speaker.play` does not cut the playing game sound; it is queued behind it
  while the old alias is already reported `REASON_PREEMPTED` (KI-SOUND-QUEUE, seen on a robot;
  the audio engine behaved the same before audio v2). `stop_all` stops
  game sounds only and is sent at frame end. Sounds cut by the robot get no `on_sound_end`.
  `is_busy` = any audio request active, filler and conversation streaming excluded.
- **Exits:** ON/OFF ends a game (`end=home`, `game_end` runs) and the robot sleeps. HOME in
  talk-flow ends the game without `on_home`. A short HOME that `on_home` does not keep logs
  `end=norm`; an error in `on_home` logs `end=err`. A HOME press within the click debounce of
  another click is ignored. `game_end` also runs when a launch is cancelled after `game_start`.
- **Engine:** `Engine.exit` freezes the screen on the last published frame and must not be
  called from the top level or `game_start`; `Engine.show()` takes effect at the end of the next
  frame. `params.is_a2a` is also `true` for to-do journey packs. Pack paths are prefixed with
  the pack root (`/sd/games` or `/sd/to-do`).
- **Sprite:** same-path `Sprite.image` sprites share one pixel buffer; `set_pivot` refuses
  out-of-range values; the transform-refusal log text; PC-STRIP (alpha PNG sprites are refused by
  `set_frame`).
- **Servo:** `Servo.stop` returns the joint to its rest angle; the robot clamps angle and
  duration and throttles motion; `system_error` is refused by the robot (removed from the
  manifest example).
- **Voice:** a second `set_keywords` while connecting replaces the pending list; talk-flow
  forwards every list and `Voice.stop` does nothing there; a fractional `sensitivity` is sent as
  0; the `keywords_configured` server frame is documented.
- **Telemetry:** `game.start` `trigger=todo` and `pv`; `game.stop` `tel`, `tel_us_max`,
  `tel_off`; `game.tel` serial lines; `Telemetry.event` fail and bad-argument lists, held calls
  from the top level, event envelope (`ev`). Manifest `version` is sent as `pv`.
- **Ranking:** numeric-string scores are accepted; `false` only when encoding fails; result
  depth and size caps; a late result is returned to the next game.
- Font-face budget in examples and recipes is 8 faces, not 4; stale firmware line citations
  updated across `contract/semantics.json`, `knowledge/` and `open-questions.md`.

### Docs

- KI PC-STUB lists what smoke.py still simplifies: one action per button, sorted
  `Input.actions()`, tables as handles, no body-board servo rejects, no ranking result, zero
  error / send-fail counters.
- `Anim:play`: a paused Anim is still the active one, so another Anim's `play` rewinds it and
  its `:resume` does nothing; `a:play(1)` plays once.
- `Servo.stop`: a call from `game_end` is never sent (teardown wipes the queue); the robot
  returns the joints to rest itself.

---

## 2.0.0 — 2026-09-30

Every document was re-verified against the firmware source. The API behaviour is now written
once (`contract/semantics.json`) and the reference pages are generated from it, so the
human and AI pages can no longer disagree. MAJOR because documented behaviour that game code
relies on was wrong (voice start, hook binding, flip after frame) and several pages were
merged or became generated; no firmware API changed.

### Fixed (documented behaviour that was wrong)

- **Voice:** `Voice.set_keywords` sends the list *and* starts listening; `Voice.start` is not
  needed. Voice commands sent from the top level or `game_start` are dropped by the robot:
  start voice from `on_tick`. A second `set_keywords` while listening returns an
  `error`/`busy` event (swap = `Voice.stop` then `set_keywords`). The 9 error codes are listed;
  4 of them end the game. The voice recipe and the reference example started voice in
  `game_start` and are corrected.
- **Hooks:** `on_tick` and `on_input` are bound once after the top level; reassigning them is
  ignored. `on_home` keeps the game on any truthy return; holding HOME force-exits.
  The watchdog outcome differs per hook.
- **Timing:** the frame period is 30 ms (about 33 Hz) while `dt_ms` stays 33; healthy
  telemetry shows `tick_hz` ≈ 33. `tick_us` includes waiting for the display lock; `print`
  in a hook costs that frame's `tick_us`.
- **Sprites:** `set_frame` works on any sprite whose raw strip matches its own format;
  `set_frame` keeps a stale flip state (KI-FLIP-FRAME). `set_scale` clamps by the larger
  side. Handles are garbage-collected when unreferenced.
- **Anim:** `Anim.new` stops nothing; `play()` stops the other Anim and rewinds only an ended
  one. **Speaker:** `on_sound_end` after `stop` arrives next frame; `set_url` also works on
  `url` aliases.
- **Lua build:** integers are 32-bit; nested C calls are limited to 30, including while
  parsing (about 20 chained `..` fail to load).
- **Paths:** the whole `/sd/games/<id>/<path>` must stay under 200 bytes.
- **Manifest:** `name` is used only in the log; the menu title comes from the server.
- **Telemetry:** the `game.warn` body has no braces on the serial log; the first
  `game.running` covers one frame; `draw_pm` is low on a static screen by design.
- Opaque PNG sprites cost `w*h*2` everywhere (one page said `w*h*3`).

### Fixed (kit and templates)

- **`structured-game` random generator is 32-bit safe:** `libs/rules.lua` used an LCG with
  modulus 2^31 whose literal becomes a float and whose product overflows on the robot's 32-bit
  integers, so the robot's sequence differed from a PC's. It is now Park-Miller (16807,
  2^31 − 1) computed with Schrage's method: every intermediate stays below 2^31 and the
  sequence is the same on the robot, smoke.py and Pika Studio.
- **Kit buttons match the engine:** holding a button sends `Input.REPEAT` after
  `button_repeat_delay_ms`, then every `button_repeat_rate_ms`; `hold_ms` is the hold time of
  the last REPEAT/RELEASE (kept after release, largest across bound buttons) instead of a live
  timer that dropped to 0; one button event reaches `on_input` once for every action bound to
  that button, in manifest order (the kit fired only the first); `is_down`/`just_*` change when
  the frame drains the event, as in `input.c`.
- **Kit `Led.is_available()`** is `false` during the top level and `game_start`, like the robot.
  The stale PC-VOICE-AVAIL known issue is removed (the kit's `Voice.is_available` already matched).
- **Kit `Anim`** draws on a black background: the robot's canvas is opaque RGB565.
- **Prepare assets:** a looping animation is not transparent (the table said "either"); the
  `Anim` reference now says the canvas is opaque.

### Added

- `contract/semantics.json`: the behaviour of every call and hook with its firmware source,
  known issues (KI-*) and PC-vs-robot gaps (PC-*). `tools/render_docs.py` renders
  `docs/reference/api.md`, `docs/reference/known-issues.md`, `skill/api-contract.md` and
  `skill/constraints.md` from it; `contract/pages/` renders `manifest.md` and `telemetry.md`.
  All numbers come from `constraints.json` through `{{key}}` placeholders.
- `contract/constraints.json`: new limits read from the firmware (start params, report event,
  line raster budget, game id and manifest string caps, icon, watchdog sampling, stall
  detector, sound finish queue, RTOS tick, HOME hold, Lua C-call limit and integer width,
  telemetry cadence and thresholds) and a `derived` block with the formula of each value.
- `docs/reference/pipeline.md`: stages S0–S9 with owner, input, output and the exact gate
  command and pass string; every guide, prompt and checklist uses these IDs.
- `docs/reference/known-issues.md`, prompt D (review a robot run), `tools/png2rgb565.py`
  (PNG to `.rgb565` images and frame strips, standard library only).
- `tools/smoke.py` / `tools/smoke_stub.lua`: errors `VOICE-EARLY`, `HOOK-REBIND`, and `API`,
  `TEXT`, `XFORM` promoted to errors; warnings `KI-FLIP-FRAME`, `HANDLE-GC`, `PC-CCALLS`,
  `INT32`. The stub now follows the robot for voice sessions, hook binding, Anim, Speaker,
  PNG cost from the file header and handle garbage collection.
- `kit/pika-frame.js`: blocking lints `L-VOICE-EARLY`, `L-HOOK-REBIND`; warning
  `L-FLIP-FRAME`; the same Anim, Speaker and `on_home` rules.
- `tools/check_docs.py`: anchors, (`key` = value) pairs, bare limit numbers in guides,
  generated pages stale or edited, completeness of every index, and every recipe run
  through smoke.
- `skill/SKILL.md` frontmatter; golden rules as ID · rule · why · check; mode D (diagnose).
  `skill/skill.index.json` gains token sizes, recipe triggers and every gate tool.
- **PC-ROOT-LEN:** Pika Studio builds `<games folder>/<game_id>/<path>` into the engine's
  `sound_abs_path_max` buffer, so a long games folder fails a pack at load
  (`bad absolute path`, `PACK_MANIFEST`) that runs on the robot. New known issue with the safe
  length (`pc_games_root_chars`, derived in `gen_contract.py`), a `PC-ROOT-LEN` warning in
  `tools/smoke.py`, and an FAQ entry.
- **`smoke.py --language <code>`:** sets `params.language` for `game_start` (default `en`), so
  each UI language of a pack can be smoke-tested; the pipeline S5 gate, the localized-text
  recipe, prompt E and the `pika-game-maker` agent run it once per language.
- **Claude Code adapters:** `/pika-game <idea>` (`.claude/skills/pika-game/`) agrees a short
  plan with the user and hands the build to the `pika-game-maker` agent
  (`.claude/agents/`), which copies `structured-game` to `games/<id>/`, writes the pack and
  loops `tools/smoke.py` until it passes. Both point at `skill/SKILL.md` and copy no rule.

### Changed

- Skill pages are rule lists with IDs (`LUA-*`, `ARCH-*`, `PERF-*`, `PORT-*`, `R1`–`R9`);
  `skill/pitfalls.md` is a table (symptom, log signature, cause, fix, evidence).
- Human guides no longer repeat the AI procedures: `design-a-demo.md` and `port-a-demo.md`
  link to `skill/demo-kit.md` and `skill/porting.md`; `team-workflow.md` covers owners and
  hand-offs only. Confidence labels are ✅ code · 🤖 robot · 🧪 heuristic · ⚠️ open.
- `lua-5.5.0/CMakeLists.txt` and `luaconf.h` are copied from the firmware build
  (`LUAI_MAXCCALLS=30` was missing).
- `docs/docs.index.json` schema 2: `stages`, `needs`, `produces`, `gate`, `generated`.
- Open questions Q1 (keyword swap) and Q2 (voice error frames) are closed with firmware
  evidence; the `VOICE_COMMAND` body and talk-flow swap stay open.
- **Examples:** every example manifest now uses the pack convention
  `"name": {"vi": "...", "en": "..."}`, like the SD game packs. The root `s.json` of each
  example is restamped for the new `manifest.json`.
- **Templates and recipes:** the `minimal-game` and `structured-game` manifests and the
  manifest blocks of the six recipes use the same `{vi, en}` name.

### Examples

- `test_voice` 0.2.0: sessions start with `Voice.set_keywords` alone (no `Voice.start`);
  an `error`/`busy` event no longer marks the session stopped; the LATENCY one-shot now
  closes its session, so a second ENTER is not refused as `busy`; latency is measured from
  `set_keywords`.
- `test_button` 0.1.1: the idle test expected `Input.hold_ms() == 0` after a release and
  failed on the robot, which keeps the release value; it now checks that `hold_ms` does not
  change while idle.
- `pick_word` 1.0.1 and `kit/template/`: the "wrong" face returns to idle after a timeout
  even if `on_sound_end` never arrives.
- `test_audio` 0.3.1, `test_font` 0.1.1: comments and diagnostics no longer name firmware
  internals that do not exist (`engine_level`, the sound bridge).
- Every example declares `peripherals`; `s.json` regenerated for all five packs.
- `tools/smoke.py`: frames advance 30 ms while `on_tick` receives 33, as on the robot; a held
  button now sends `REPEAT` events on the body board's timing, and `Input.hold_ms` reports
  the last event's hold (0 until the first `REPEAT`, the release value after `RELEASE`).

### Docs

- **Prompt E, quick first game:** a copy-paste prompt for a first playable pack right after
  cloning (Lua from `structured-game`, placeholder art, buttons only), linked from Getting
  started and the FAQ; `games/` is git-ignored for the packs it creates.
- **Demo kit (skill):** `Speaker.set_url` exists in the kit (validation only); button and
  `is_available` behaviour described.
- **FAQ:** new `docs/start/faq.md` with short answers to the questions developers ask first,
  each linking to the page that owns the fact; listed in `docs/docs.index.json`,
  `docs/README.md` and `README.md`.
- **Manifest reference:** `name` documents the `{vi, en}` object as the pack convention and
  states that the engine reads only a string (an object logs `name=""`); the menu title comes
  from the server's game list.

### Removed

- The `assets` section of `sdk.index.json` and the README asset/licence notes: the `assets/`
  folder is no longer part of the SDK. Pika Studio's asset library has no SDK source until it
  returns.
- `engine_api.min` from `sdk.index.json` and `skill/skill.index.json`: `sdk_version` is the
  only version; `gen_contract.py --check` proves the firmware match.

---

## 1.4.0 — 2026-09-30

Docs are reorganised by kind so new guides can be added without repeating facts.
No Lua API changed. Links to the old flat `docs/*.md` paths must be updated.

### Added

- `docs/guides/vibe-coding.md`: one person and an AI assistant, idea to finished game,
  with what to check at each step and the signs the AI has drifted.
- `docs/templates/_guide-template.md`: the skeleton every guide follows
  (`> **For:** · **Needs:** · **Result:**` line, Do / Check / Done-when steps).
- `tools/check_docs.py` also fails when a doc under `docs/` is missing from
  `docs/docs.index.json` (or listed but absent), when a relative Markdown link is
  broken, or when a guide lacks its header line.
- `docs/docs.index.json` entries carry `type`, `audience` and `order`.

### Changed

- `docs/` is split into `start/`, `guides/`, `concepts/`, `reference/` and `templates/`:

  | Old | New |
  | --- | --- |
  | `getting-started.md` | `start/getting-started.md` |
  | `workflow.md` | `guides/team-workflow.md` |
  | `design-a-demo.md` | `guides/design-a-demo.md` |
  | `porting-a-demo.md` | `guides/port-a-demo.md` |
  | `guide.md` | `guides/write-a-game-pack.md` |
  | `asset-guide.md` | `guides/prepare-assets.md` |
  | `release-checklist.md` | `guides/release-checklist.md` |
  | `overview.md` | `concepts/overview.md` |
  | `api.md`, `manifest.md` | `reference/api.md`, `reference/manifest.md` |
  | `monitor.md` | `reference/telemetry.md` |
  | `brief-template.md` | `templates/brief-template.md` |
  | `start-prompt.md` | `templates/prompts.md` |

- `docs/README.md` finds a guide by "who you are × what you want to do".
- `examples/pick_word/s.json` regenerated (a comment path changed).

---

## 1.3.0 — 2026-09-29

Adds a way to run a Lua pack on a PC without the simulator, and folds in the
lessons of an earlier draft skill, each re-checked against the engine source.
No Lua API changed.

### Added

- **`tools/smoke.py`** (+ `tools/smoke_stub.lua`, `tools/requirements.txt`) — lints a pack
  and plays it through a scripted run in real Lua 5.5 (via `lupa`), inside the engine's
  sandbox. Every engine global is built from `contract/api.json`; pools, font faces, the
  96 px transform gate, hidden-until-placed sprites, frame strips, the sound channel and
  cooldown follow the engine's rules. Steps use the same words as `tools/playtest.js`.
- **Skill**: `lua-language.md`, `game-architecture.md`, `performance.md`, `libs-catalog.md`,
  `open-questions.md`; recipes `leaderboard`, `localized-text`, `scenes`; template
  `structured-game` (rules separated from wiring). `skill.index.json` entries carry
  `audience` and a `load` condition so an assistant reads only what the task needs.
- **Docs**: `workflow.md`, `start-prompt.md`, `brief-template.md` (with learning goals),
  `asset-guide.md`, `release-checklist.md`. **Root**: `MAINTAINING.md`, `RATIONALE.md`.

### Changed

- `skill/workflow.md` and `skill/start-prompt.md` moved to `docs/` (they are for people).
- `skill/pitfalls.md` merged to 26 symptom-indexed entries with confidence labels
  (✅ engine code · 🧪 seen on a robot · ⚠️ open).

### Fixed

- Packaging: `s.json` checksums are issued when a pack is published through the Pika
  store. Pika Studio's Export neither creates nor checks them (several docs said it did).
- `set_pivot` is not limited to 96 px (only `set_scale` / `set_rotation` are).
- New sprites stay hidden until their first `set_pos` / `set_visible`; the kit now does the
  same and lints it (`L-HIDDEN`), and the template places its background.
- Frame strips: frames are raw bytes in the sprite's own format (`w*h*2` for `Sprite.new`,
  `w*h*3` for PNG sprites); a PNG is never a valid strip.
- Lua 5.5: only the numeric-for variable and the first generic-for variable are read-only;
  `global` is not reserved in the engine build (`LUA_COMPAT_GLOBAL`).
- `Voice.is_available()` is always false inside `game_start`; `Led.set_brightness` rejects
  values outside 0..100 instead of clamping.
- **Examples** `test_voice`: the `too_many_keywords` and `payload_too_big` probes used
  wrong limits (16 keywords, 1024 B) and would have failed on a robot; they now use 64
  keywords and 2048 B. `test_button`, `test_audio`, `test_voice`: dropped calls the engine
  never had (`Engine.now_ms`, `Engine.version`, the `Voice.mode` probe), the ignored
  `assets` manifest key and references to firmware internals; `s.json` regenerated.
- `contract/constraints.json` gains `voice_keywords_max`, `voice_start_json_max_bytes`,
  `voice_table_max_depth`, `voice_table_max_keys`, `input_ring_slots`,
  `button_repeat_delay_ms` and `button_repeat_rate_ms`.

---

## 1.2.0 — 2026-09-29

The SDK becomes the single, English, source of truth for building PIKA games, with
generated facts instead of hand-copied ones. No Lua API changed; existing packs run
as before.

### Added

- **`contract/`** — `api.json` (every global, function, method, constant and hook the
  engine registers, read from its `luaL_Reg` tables) and `constraints.json` (every hard
  limit, read from C macros and the effective `sdkconfig`). Generated by
  `tools/gen_contract.py`; `--check` fails when stale.
- **`kit/`** — `pika-frame.js`, a browser robot frame with the engine's hooks, API names
  and limits, live lints, a budget panel and `pika-spec.json` export. It checks itself
  against `contract/api.json` at boot so it never offers a call the robot lacks.
  `kit/template/` is a complete demo to copy.
- **`tools/`** — `check_docs.py` (fails on any doc that names a non-existent call, omits a
  real one from `docs/reference/api.md`, or quotes a wrong limit), `playtest.js` (scripted headless
  playthrough), `check_spec.py` (demo hand-off gate: glyph coverage via fontTools, file
  sizes, alias limits, recording list), `package.json` (Playwright dev dependency).
- **`examples/pick_word`** — the kit template ported line by line to Lua.
- **Docs** `design-a-demo.md` and `porting-a-demo.md`; skill files `demo-kit.md` and
  `porting.md`. The AI skill now routes three modes: design a demo, write Lua, port.
- `sdk.index.json` sections `contract`, `kit`, `skill`, `tools`.

### Changed

- All docs, the AI skill, library and example indexes are rewritten in English for an
  international audience; internal firmware detail is removed.

### Removed

- `docs/module.md` (firmware internals; kept in the firmware repository).

### Fixed

- The skill said sprites cannot be scaled or rotated. `spr:set_scale`, `spr:set_rotation`
  and `spr:set_pivot` exist when both sprite sides are at most 96 px.
- `docs/reference/api.md` lacked `Shape`, `Speaker.set_url`, three `Speaker.REASON_*` constants,
  `Engine.report_result` and six hooks (`game_end`, `on_home`, `on_input`,
  `on_input_lost`, `on_sound_lost`, `on_pack_cmd`).
- `set_frame` reads raw frames in the sprite's own pixel format from a strip file; it
  never reads a PNG. Multi-frame sprites are opaque `.rgb565` strips.

---

## 1.1.1 — 2026-09-14

Đồng bộ toàn bộ tài liệu/skill/example với triển khai thật của engine
(`head_esp32/components/game_engine`). Trước bản này tài liệu SDK là một nhánh
fork đã trôi khỏi engine: một số API ghi trong tài liệu **không còn tồn tại**,
và một số con số là sai.

### Gỡ

- **`State.*`** (`set`/`get`/`save`/`load`/`has_save`/`clear`) — binding đã bị gỡ
  khỏi engine. **Hiện không có API lưu trạng thái**: Lua không ghi được file nào,
  trạng thái chỉ sống trong một phiên chơi. Muốn giữ điểm thì dùng `Ranking.report`.
- **`Voice.mode()`** — thay bằng `params.is_a2a` trong `game_start(params)`.
- **`libraries/save.lua`** — dựng hoàn toàn trên `State.*`, mọi hàm no-op (không
  crash nhưng cũng không lưu gì). Xoá khỏi `libs.index.json` và `libraries/README.md`.
- **Nhánh Continue/resume trong `libraries/settings.lua`** (`has_save`/`on_resume`/
  `_resume_row`) — không có persistence thì `has_save` vĩnh viễn false, code không
  bao giờ chạy tới.

### Sửa (breaking với pack cũ)

- **Manifest v2**: `display_name`/`entry_script` → **`name`/`main`**, thêm
  `peripherals`. Parser **không còn fallback** — pack chỉ dùng tên v1 sẽ có tên
  rỗng và không nạp được entry script. Đã cập nhật cả 4 example và template.
- **`game_start(params)`**: tham số là **table** (luôn là table — body rỗng/hỏng
  decode thành `{}`), không phải string JSON. Engine tự thêm `params.is_a2a` và
  `params.language`.

### Thêm

- **`Ranking.*`** (`report` / `get_result`) — leaderboard qua IPC sang back.
  `duration_ms` do engine tự tính, không nhận từ Lua. `get_result` là
  **consume-once**, phải poll từ `on_tick()`.
- **`Engine.stack_hwm()`** (debug).
- **[docs/reference/manifest.md](docs/reference/manifest.md)** — schema manifest v2 đầy đủ.

### Sai số liệu (đối chiếu Kconfig + source)

| Mục | Ghi sai | Thực tế |
| --- | --- | --- |
| Cooldown `Speaker.play` | 80 ms | **150 ms** (`CONFIG_GAME_SOUND_PLAY_COOLDOWN_MS`; 80 chỉ là fallback khi Kconfig vắng) |
| Trần sprite | "tối đa 32" | **không có trần** — giới hạn là PSRAM còn trống |
| `audio.sounds` vượt 64 | "âm thầm bỏ bớt" | **reject cả pack** (`install_entry` fail → `goto bad`) |
| Tên action / alias | ≤ 24 ký tự | **≤ 23** (buffer 24 gồm NUL; `n >= 24` là reject) |
| `path` của sound | ≤ 64 ký tự | **≤ 63** |

Hai dòng cuối dễ mất thời gian debug: viết đúng 24 ký tự theo tài liệu cũ thì
pack **bị từ chối nạp**.

### Tài liệu

- Gỡ 46 link chết trỏ tới mã firmware (`../../head_esp32/...`) — hợp lệ khi ở
  `docs/pika-engine/` nhưng hỏng trong SDK vì đây là repo độc lập không chứa mã
  firmware. Chuyển thành tên file dạng code.
- `monitor.md` thay bằng bản viết lại theo pha vòng đời (`game.start` /
  `running` / `stop` / `error` / `warn`).
- `getting-started.md`: bảng example đúng với 4 pack đang có, bảng phím
  simulator, và những hành vi simulator **không** mô phỏng (HOME/`on_home`,
  servo/LED, Voice).
- `skill/` (nguồn chống-bịa-API cho AI sinh game): cập nhật `api-contract.md`,
  `constraints.md`, `pitfalls.md`, recipes và template.

---

## 1.0.2 và trước đó

Không có changelog — xem `git log`.
