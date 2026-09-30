# Release checklist

> **For:** whoever publishes and tests a game (QA) · **Needs:** a pack that passes smoke (S5) and Pika Studio (S6) · **Result:** a published pack checked on a robot (stages S8–S9)

Part A runs on a PC, part B publishes, part C lists what **only a robot shows**. Telemetry
lines and fields are defined in [Telemetry](../reference/telemetry.md).

## A. Before publishing (PC)

- [ ] The [S5 gate](../reference/pipeline.md#gates) passes with steps that reach every branch,
      including `voice:<keyword>` steps if the game uses voice. Every warning is explained.
- [ ] In Pika Studio, every path played twice: start → play → win and lose → play again → exit.
- [ ] Every sound the code plays has an alias in `manifest.json`, and every declared file exists.
- [ ] The game can be finished with buttons only.
- [ ] No demo files, sources or screenshots inside the pack folder.

## B. Publish

- [ ] The pack is published through the Pika platform ([S8](../reference/pipeline.md#gates)),
      which issues `s.json`. Nothing is edited afterwards: any change means publishing again;
      never copy single files onto the card.

## C. On the robot

Play at least three full rounds, then exit and relaunch, with a serial monitor attached.

### Telemetry gates

| Check | Line | Pass |
| --- | --- | --- |
| The pack opens | `game.error` | no `phase=load` or `phase=render` line |
| It ended cleanly | `game.stop` | `end=norm` (or `end=home` after HOME), no `err=` |
| No call failed silently | `game.stop` | `api_fail=0` and no `drop=` field |
| Frames keep time | `game.running` (ignore the first line), `game.stop` | `tick_hz` close to `tick_hz_max` = 33 in steady play; low `slow_pm` |
| No heavy frames in play | `game.running` | no `tick_us` or `gap_us` spike outside scene changes 🧪 |
| Real time is real | wall clock | 60 s on a watch is 60 s in the game (timers use `Timer.millis()`) |
| No leak between rounds | `game.running`, `game.start` | `arena`, `heap` and `psram` return to the same level after each round; `psram` in `game.start` does not fall from one launch to the next |
| Nothing stalled | `game.stalled` | no line |

### Repeated plays

- [ ] No score, rank, label or sound from a previous round shows up after replay or relaunch.

### Voice and network *(if the game uses voice or ranking)*

- [ ] Keywords work with the network on; the game shows when it is listening.
- [ ] With Wi-Fi off, the behaviour matches the brief (a voice pack ends from the menu when
      its voice connection fails; see [Voice](../reference/api.md#voice)); nothing waits forever.
- [ ] The leaderboard appears after a menu launch, or the game stops waiting for it.

### HOME

- [ ] A short HOME press does what the brief says (exit, or `on_home` keeps the game and
      asks), including on loading and result screens.
- [ ] Holding HOME exits from any screen.

### Audio

- [ ] Spoken instructions are not cut off by effects (one channel).
- [ ] Every flow that waits for a sound to finish also has a time limit.
- [ ] Volume is even across files.

### Screen

- [ ] Every character renders (no boxes); diacritics are not clipped.
- [ ] Nothing important sits under the edge of the robot's frame.
