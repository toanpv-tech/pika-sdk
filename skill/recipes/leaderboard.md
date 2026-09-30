# Recipe: leaderboard on the game-over screen

> **Load when** a game reports a score and shows the player's rank. The working code is the
> ranking block of the structured template: [`../templates/structured-game/scripts/main.lua`](../templates/structured-game/scripts/main.lua)
> lines 126-145 (`finish_run`, `poll_rank`, `discard_stale_rank`), called from `react` (line 225),
> `on_tick` (line 270) and `on_input` (line 277), and drawn by `render_over` (lines 190-209).
> Copy that block; do not rewrite it.

API: [`Ranking.report`, `Ranking.get_result`](../../docs/reference/api.md#ranking), `Timer.millis`.

## Rules

- **RANK-QUEUED** MUST treat `Ranking.report` `true` as "queued", not "ranked" — it only means the score left the head board. The robot drops it when the game was not started from the menu, and in talk-flow (A2A) it goes to the conversation; in both cases no result ever arrives.
- **RANK-DEADLINE** MUST poll `Ranking.get_result()` only while waiting and give up after a deadline — 🧪 the template uses 6 s (`RANK_TIMEOUT_MS`), not measured.
- **RANK-STALE** MUST call `Ranking.get_result()` once when a round starts and discard it — the call is consume-once, and 🧪 a slow answer to the previous round can arrive during the next.
- **RANK-TEXT** MUST reuse play-screen `Text` labels for rank lines (`text_slots` = 8).
- **RANK-A2A** MUST use `Engine.report_result` for a talk-flow outcome (`params.is_a2a`), not `Ranking` ([api.md#engine](../../docs/reference/api.md#engine)).

## Display

| State | Show |
| --- | --- |
| waiting (report returned `true`, before the deadline) | score + "Loading ranking..." |
| result arrived | score + `r.my_rank.rank` when `type(r.my_rank) == "table"`; a few `r.top` rows at most |
| report `false`, or deadline passed | score only; no error message; the player can replay |

Never mix sample scores into real data.

## Check

`python tools/smoke.py skill/templates/structured-game` ends `0 error(s)`, exit 0. smoke.py does
not model the leaderboard server; check a real rank on a robot launched from the menu.
