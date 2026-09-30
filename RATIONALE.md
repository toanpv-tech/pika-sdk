# Why the SDK is organised this way

AI assistants and developers arrive with habits from other engines. Left alone they call
functions the robot does not have, exceed limits that fail silently, and write for other
Lua versions. The SDK exists to stop that, and to guide people through the stages no tool
can do for them: the brief, the art, the robot test. How to keep these principles:
[MAINTAINING.md](MAINTAINING.md).

## 1. Split by audience

`docs/` is for people (designers, artists, developers, QA): one page per goal, organised by
kind. `skill/` is for AI assistants: routing, rules with IDs and checks, recipes and
templates, with no installation steps. Neither has to wade through material written for the
other.

## 2. One source of truth, generated from the firmware

Every API name and number comes from `contract/`, which `tools/gen_contract.py` reads out of
the engine source. The behaviour of each call is written once, in `contract/semantics.json`,
with the firmware line that proves it, and the reference pages for people and AI are
rendered from it. Earlier doc sets copied facts into each file; the copies drifted (a sound
cooldown with two values, a sprite cap that never existed, voice started from the wrong hook
in both the reference and a recipe). A copy is correct on the day it is made; a generated
page is correct whenever `--check` passes.

## 3. One pipeline with gates

Every game takes the same ten stages, S0 to S9, and each stage is done only when its gate
passes: a command with an exact output, or a named check. Guides, prompts and the release
checklist refer to stage IDs instead of redefining steps, so a solo creator and a team
follow the same path.

## 4. Labels instead of guesses

A claim that is not proven in the engine source carries a label (🤖 seen on a robot,
🧪 heuristic, ⚠️ open), and every open question has a safe way to code around it in
`skill/open-questions.md`. Firmware behaviour that is surprising or wrong is listed with a
stable ID and a workaround in the known-issues page. Work continues today, readers know
what is firm, and the engine team gets one list to answer.

## 5. Machines check instead of people remembering

| Tool | Catches |
| --- | --- |
| `tools/gen_contract.py --check` | a contract or reference page that no longer matches the firmware |
| `tools/check_docs.py` | an unknown API name, a wrong number, a broken link or anchor, a stale index, a recipe that does not run |
| kit lints (`kit/pika-frame.js`) | a demo doing what the robot cannot, while you play |
| `tools/playtest.js` + `tools/check_spec.py` | a demo handed off with blockers, missing glyphs or oversize files |
| `tools/smoke.py` | a Lua pack with invented calls, undeclared sounds, pool overflows, voice sent too early, rebound hooks or crashing hooks |

The limit is stated openly: none of these draws the real screen or measures the robot.
Pika Studio runs the real engine; only a robot proves performance.

## 6. Lessons become rules

A failure found on a robot is written up once, by symptom, in `skill/pitfalls.md`, and where
possible turned into a lint or a smoke check. Every team then trips over it at most once.

## 7. Templates by game size

A one-screen game and a multi-screen game with levels and a leaderboard need different
starting points. `skill/templates/` holds both; larger games keep their rules in a plain Lua
module, testable without the robot, and wire them to sprites, text and sound in one place.

## 8. Educational games need learning goals

These are learning games for children. The [brief](docs/templates/brief-template.md) asks for
the word set, what the child must say, the UI language versus the learning language, and
what happens on silence or a wrong answer, so the game is not rebuilt after a misread
teaching intent.
