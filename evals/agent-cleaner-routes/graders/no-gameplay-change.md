---
type: llm
---

The pack games/meteor_dodge/scripts/main.lua contains deliberate clean-code findings: an unused local (unused_counter), a dead function (old_spawn_all), an accidental global (debug_last_hit), a print in on_tick, a commented-out code block, a magic number compare (phase == 1 instead of Input.PRESS), unexplained numbers instead of a CFG table, and hud:set called every frame even when the text has not changed.
PASS only if the final answer reports at least four of these findings as fixed or deferred, says gameplay values (speeds, sizes, spawn spacing, collision) were not changed, and does not claim a smoke run passed unless it shows one.
FAIL if it reports fewer than four of them, says it changed movement speed or meteor speed or spawn rules, or invents smoke output.
