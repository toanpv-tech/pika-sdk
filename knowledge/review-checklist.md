# Review checklist: before handing over Lua

> **Load when** a pack is about to be handed over (modes B and C, after a fix in mode D), or
> when asked to review someone's Lua. Each item names the rule that owns it; items without an
> owner elsewhere are defined here as `REVIEW-*`. Run it on your own output: reviewing is part
> of writing. Then run the smoke gate ([SKILL.md §6](SKILL.md#6-self-check-then-hand-over)).

## Engine rules (owned elsewhere)

- [ ] Only names from the contract (G1); every limit from [constraints.md](constraints.md) (G2).
- [ ] `on_tick`/`on_input` at the top level, never reassigned (G4, LUA-HOOKS, LUA-REBIND).
- [ ] Every handle referenced for its whole life (G6, ARCH-HANDLES).
- [ ] Every factory and mutator return checked; raise only in `game_start` (G7, PORT-RETURNS).
- [ ] Integer coordinates (G8, LUA-COORD); integers below 2^31 (LUA-INT32).
- [ ] Time from `Timer.millis()` differences, fixed step with a catch-up cap (G9, ARCH-TIME).
- [ ] Every wait has a timeout; buttons alone finish the game (G10).
- [ ] Voice from `on_tick` only (G5); `on_voice_event` checks `type(e)` first.
- [ ] Rules in `libs/rules.lua` with no engine call (ARCH-SPLIT); feedback in one `react()` (ARCH-EVENTS).
- [ ] Per-frame code: no loads (PERF-LOCK), mutators only on change (PERF-SEND), no allocation
      ([performance.md](performance.md#allocation-free-per-frame-code)), no `print` (PERF-PRINT).
- [ ] `Text` created last (ARCH-LAYERS); live counts inside the planned budget (BUDGET-HEADROOM).

## House style

- **REVIEW-LOCAL** Every variable `local`; only hooks are globals (LUA-LOCALS). Check: the grep in [lua-language.md](lua-language.md#rules).
- **REVIEW-CFG** MUST keep every tunable (speeds, counts, timings, colours, layout anchors) in one `CFG` table at the top of `main.lua`, each with a comment; no unexplained number in logic. Check: numbers in rule code are `CFG.*` or named locals.
- **REVIEW-CONST** MUST compare with engine constants (`Input.PRESS`, `Speaker.REASON_COMPLETED`), never with their numeric values. Check: grep `phase == [0-9]`, `reason == [0-9]`.
- **REVIEW-ENUM** MUST use integer constants grouped in one table for game states and kinds (`local KIND = { NONE = 0, BOMB = 1 }`) instead of bare strings compared in hot paths. Check: review.
- **REVIEW-SEED** MUST draw randomness in the rules from a generator seeded through the rules state, so a bug can be replayed and `libs/testkit` tests are stable ([../starters/structured-game/](../starters/structured-game/)). Check: no `math.random` inside `libs/rules.lua` without a seed parameter.
- **REVIEW-RESTART** MUST reset every module-level value in `game_start` (or the rules' start function): a restart after game over starts clean, with no sprite, timer, sound or score from the last round. Check: smoke steps include `restart`; [release-checklist.md](../docs/guides/release-checklist.md#repeated-plays).
- **REVIEW-PCALL** NEVER wrap code in `pcall` to hide a bug; use it only where failure is expected and recoverable (parsing data), with a comment. Nested `pcall` counts toward (`lua_maxccalls` = 30). Check: every `pcall` has a comment.
- **REVIEW-PERF-NOTE** MUST leave a one-line comment where a construct exists for speed rather than clarity (a swap-remove, a hoisted local), so nobody "cleans it up". Check: review.

## Hygiene

- **REVIEW-DEAD** NEVER ship dead code, commented-out blocks, unread variables, empty functions or history comments (`-- added for X`, dates). Check: review.
- **REVIEW-ASSETS** MUST give every file in the pack a consumer, and every path in the Lua and the manifest a file; no demo files, sources or screenshots in the pack. Check: list the pack folder against the code; [release-checklist.md](../docs/guides/release-checklist.md#a-before-publishing-pc).
- **REVIEW-DEBUG** NEVER leave per-frame debug output; a debug switch, if any, is a `CFG` flag that defaults off. Check: grep `print(`.
- **REVIEW-MINIMAL** When editing an existing pack, MUST match its style and change only what the task needs. Check: the diff.
- **REVIEW-SJSON** NEVER create or edit `s.json` (G11, PORT-SJSON).

## Comments

English; say *why*, not what (`-- 12 * 40 = 480: the grid spans the screen`). Open `main.lua`
with the block list and the budget comment ([game-architecture.md](game-architecture.md#file-order-of-mainlua)).

- **REVIEW-PERF-MARK** MUST mark a measured optimization with a `-- perf:` comment that names
  the symptom it fixed and the measurement (`-- perf: dots created 4 per tick, game_start was
  over the watchdog`). A cleanup keeps the shape of marked code and only fixes its comments or
  names. Check: every pool, staggered loop or hoisted lookup that reads oddly carries the mark.
