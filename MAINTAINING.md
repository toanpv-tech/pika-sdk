# Maintaining the SDK

How to change the SDK without letting it drift from the engine. Why it is built this way:
[RATIONALE.md](RATIONALE.md).

## Where each fact lives

| Fact | Home | Written by |
| --- | --- | --- |
| an API name, a limit, a firmware constant | `contract/api.json`, `contract/constraints.json` | `tools/gen_contract.py`, from the firmware source |
| what a call or hook does, known issues, PC-vs-robot gaps | `contract/semantics.json` | hand, with a firmware `path:line` per entry |
| manifest and telemetry reference prose | `contract/pages/*.md` with `{{key}}` placeholders | hand |
| how to reach a goal | one guide in `docs/guides/` | hand |
| a rule or pattern for AI assistants | one file in `knowledge/` | hand |

`docs/reference/api.md`, `known-issues.md`, `manifest.md`, `telemetry.md`,
`knowledge/api-contract.md`, `knowledge/constraints.md` and `kit/pika-constraints.js` are
**generated**. Never edit them; edit the source and run:

```bash
python tools/gen_contract.py --firmware <firmware checkout>   # regenerate
python tools/gen_contract.py --check                          # exit 1 if anything is stale
```

A missing limit is added to `gen_contract.py` (read from the code), never typed into a page.

## Rules

1. **One fact, one home.** Everything else links to it. When you find a fact twice, replace
   one copy with a link.
2. **Numbers only from the contract.** In prose outside the generated pages, a number that
   helps the reader is written as (`key` = value); `check_docs.py` verifies each pair.
3. **Label what is not proven in code.** ✅ proven in the engine source · 🤖 seen on a robot ·
   🧪 heuristic, not measured · ⚠️ open question. Every ⚠️ has an entry with a **safe way** in
   `knowledge/open-questions.md`. A guess is never written as a fact.
4. **Machines check, people do not remember.** When a mistake can be caught by a tool, add
   the check to the tool, not a warning to a page.

## AI tool adapters (Claude Code plugins)

The SDK is a Claude Code plugin marketplace, `.claude-plugin/marketplace.json`, with two
plugins. Install: `/plugin marketplace add toanpv-tech/pika-sdk`, then
`/plugin install pika-game@pika-sdk`.

| Plugin | For | Source | Components |
| --- | --- | --- | --- |
| `pika-game` | every game developer | the SDK root, so `knowledge/`, `tools/` and `contract/` ship with it | `agents/`, `skills/` |
| `pika-sdk-maintainer` | the Pika team, in a pika-sdk checkout next to a firmware checkout | `plugins/pika-sdk-maintainer/` | its own `skills/` (agents later) |

`agents/` and `skills/` at the root belong to `pika-game` only (Claude Code reads them by
default from the plugin source; a marketplace `agents` field is ignored, tested on 2.1.296).
Never put a non-agent `.md` file (a README) in `agents/`, nor a `hooks/` folder or a `.mcp.json`
at the root: they would load into `pika-game`. `knowledge/` (AI knowledge) and `skills/` (Claude Code commands) are different folders.

Every adapter is **workflow only**: who asks what, where the pack goes, which gate proves it.
It points at `knowledge/SKILL.md` and never copies a rule, an API name or a limit, so it needs no
change when the contract does. Agents read the SDK at `${CLAUDE_PLUGIN_ROOT}` (the installed
copy, same version as the contract) and write packs in `games/<id>/` of the working directory.
`check_docs.py` check 13 enforces versions, names, no API names and that every quoted SDK path
exists; review by hand when `knowledge/SKILL.md` renames a mode or a golden rule.

### Roles

There is no manager agent: the main session (the user + Claude, through `/pika-game`) is the
only orchestrator. Agents run in their own context, cannot ask questions mid-run, and stop
and return when a task exceeds their rights.

| Agent | Stage ([pipeline](docs/reference/pipeline.md)) | Writes | Proves with | Hands over when |
| --- | --- | --- | --- | --- |
| `pika-game-maker` | S4–S5, Lua from a confirmed plan; bug fixes | `games/<id>/` | `tools/smoke.py` | the plan is missing or contradicts the SDK |
| `pika-game-porter` | S4–S5 from a brief or demo; robot frame drops; engagement ideas | `games/<id>/`, after the intake/fit/budget stop | `tools/smoke.py`, budget worksheet | the engine lacks a call: report it to the Pika team |
| `pika-game-cleaner` | after S4, mode `light` or `full` | behaviour-preserving fixes in the files it was given | `tools/smoke.py` rerun | a fix would change behaviour: deferred to the builder |
| `pika-game-optimizer` | after S6 / S9, from a serial log | `games/<id>/`, each change marked `-- perf:` | `tools/check_robot_log.py` before and after, `tools/smoke.py` | a change the player would notice: proposal for the user; the engine is the limit: report to the Pika team |
| `pika-game-tester` | S5, S6 / S9 from a serial log | only `games/.pika-test/<id>/` | `tools/smoke.py`, `tools/check_robot_log.py` | FAIL goes back to the builder; INCONCLUSIVE is BLOCKED |

Loop (run by `/pika-game`): builder → cleaner `light` → tester; FAIL returns to the builder,
at most three rounds before asking the user. A performance gate WARN / FAIL in a scored log
goes to optimizer → cleaner `light` → tester. PASS → cleaner `full` → tester regression. The
main session decides from each agent's closing JSON block, not from its prose. Agents report
in the user's language; code, identifiers and log lines stay in English.

| Decision | Proposes | Approves | Applies |
| --- | --- | --- | --- |
| Parity table, layout, frame budget of a port | porter | user | porter |
| A gameplay, UX or art change to fit the engine | any agent | user | builder |
| A performance change a player would notice | optimizer | user | optimizer |
| A missing engine call | porter, maker | Pika team | firmware, then `gen_contract.py` |
| Wrong or missing SDK knowledge (each report's last section) | any agent | Pika team | `pika-sdk-maintainer`, through this file's rules |
| A release and its version | `/pika-sdk-release` | Pika team | `/pika-sdk-release` |

### Adding an agent or skill

Put a `pika-game` agent in `agents/<name>.md` (name = file name) and a command in
`skills/<name>/SKILL.md`; a maintainer component under `plugins/pika-sdk-maintainer/`. Add at
least one eval case in `evals/` that shows the component fires and helps, and one negative case
that must not fire it. Run `claude plugin validate --strict .` and `python tools/check_docs.py`.
Plugin versions live only in `marketplace.json` and always equal `sdk_version`: installed
copies refresh only when that string changes.

## Before every release

```bash
python tools/gen_contract.py --check
python tools/check_docs.py
python tools/smoke.py test-packs/<each>
python tools/smoke.py starters/<each> "<steps from its README>"
```

All must exit 0. If the kit or its template changed, also run the S3 gate on
`kit/template/index.html` ([pipeline](docs/reference/pipeline.md#gates)). Open at least one
example in Pika Studio.

## Versioning

`sdk_version` (and the same value in `sdk.index.json` and in every plugin `version` of
`.claude-plugin/marketplace.json`) follows SemVer; the bump rules are at
the top of [CHANGELOG.md](CHANGELOG.md). Every release adds a CHANGELOG entry at the top,
grouped as `Added`, `Changed`, `Removed`, `Fixed`, `Docs`.

## Changing engine behaviour docs

1. Find the proof in the firmware (a `path:line`) or a robot log. Memory is not proof.
2. Edit `contract/semantics.json` (or a `contract/pages/` template), then regenerate.
3. If the tools can check it, teach `tools/smoke_stub.lua` and the kit the same behaviour.

## Adding a pitfall

Only for a failure that can be reproduced. Add a row to `knowledge/pitfalls.md` with symptom,
log signature, cause, fix and evidence. If a tool could have caught it, add the check to
`tools/smoke.py` / `tools/smoke_stub.lua` (Lua packs) or to the kit lints and
`tools/check_spec.py` (demos) in the same change.

## Settling an open question

1. Record the answer and its evidence.
2. If it is a behaviour fact, put it in `contract/semantics.json`.
3. Update the files the question lists and replace every ⚠️ label for it.
4. Mark it closed in `knowledge/open-questions.md` and note it in the CHANGELOG.

## Adding a recipe, an example or a library module

- **Recipe:** one task per `knowledge/recipes/<task>.md`, with a ```` ```json ```` manifest block
  and ```` ```lua ```` blocks that form a runnable pack; `check_docs.py` runs it through smoke.
  List it in `knowledge/skill.index.json`.
- **Example:** a robot test pack `test-packs/test_<global>/` for one public Lua global that
  passes smoke and runs in Pika Studio, listed in `test-packs/examples.index.json` with its
  `covers` and `needs`, with only redistributable assets. It runs on `libs/testkit`
  (`tk.suite`) with a copy of `libraries/testkit.lua` in its `libs/`, and uses Nunito
  (`fonts/nunito-regular.ttf`, `OFL.txt` alongside). A row that ends the game is `manual`.
  After any change to its files, its `s.json` must be regenerated by the Pika team's
  generator.
- **Library module:** `libraries/<name>.lua`, listed in `libraries/libs.index.json` and
  `knowledge/libs-catalog.md` with its exact exported names.

## Adding or changing a doc

Put it in `docs/` (people) or `knowledge/` (AI), never both. Inside `docs/`, pick the folder by
kind, not by topic:

| Folder | Holds | Never holds |
| --- | --- | --- |
| `start/` | a walk-through that ends with working tools | reference tables |
| `guides/` | one reader + one goal: stages, checks, when it is done | signatures, limits, manifest rules (link to `reference/`) |
| `concepts/` | why things work the way they do | step-by-step instructions |
| `reference/` | exact facts: the pipeline and the generated pages | procedures |
| `templates/` | things to fill in or copy | long explanations |

A new guide starts from `docs/templates/_guide-template.md`, keeps its
`> **For:** … · **Needs:** … · **Result:** …` line, is named `guides/<verb>-<object>.md`,
and is added to `docs/docs.index.json` and to the table in `docs/README.md`.
`tools/check_docs.py` fails when a page is missing from its index, a link or anchor is
broken, or a guide lacks its header line.

Lines that deliberately name a call that does not exist carry `<!-- not-an-api -->`; lines
that deliberately quote a number unrelated to a limit carry `<!-- number-ok -->`.
