# AGENTS.md

Start here if you are an AI coding assistant working in this repository. This file only
points; every rule lives in the file it links to.

## What you are asked to do

| Task | Read first | Write to | Prove with |
| --- | --- | --- | --- |
| make, port or fix a game | [knowledge/SKILL.md](knowledge/SKILL.md) (§1 golden rules, §2 route) | `games/<id>/` (git-ignored) | `python tools/smoke.py games/<id>` |
| sketch a game in the browser | [knowledge/demo-kit.md](knowledge/demo-kit.md) | a copy of `kit/template/` | `tools/playtest.js`, `tools/check_spec.py` |
| look up a call or a limit | [contract/api.json](contract/api.json), [knowledge/constraints.md](knowledge/constraints.md) | nothing | never answer from memory |
| change the SDK itself | [MAINTAINING.md](MAINTAINING.md) | the source of the fact, never a generated file | the checks below |

## Layout

- `contract/`: the engine contract, the source of truth (`api.json` and `constraints.json`
  generated from the firmware, `semantics.json` and `pages/` hand-written).
- `knowledge/`: knowledge for AI assistants: rules, recipes.
- `starters/`: game skeletons to copy into `games/<id>/` (`minimal-game`, `structured-game`).
- `skills/`, `agents/`: Claude Code commands and agents of the `pika-game` plugin. Different
  from `knowledge/`.
- `docs/`: for people. `kit/`: browser robot frame. `libraries/`: Lua modules to copy into
  `<game>/libs/`. `test-packs/`: robot test packs. `tools/`: generators and gates.

## Generated files: never edit by hand

`docs/reference/api.md`, `docs/reference/known-issues.md`, `docs/reference/manifest.md`,
`docs/reference/telemetry.md`, `knowledge/api-contract.md`, `knowledge/constraints.md`,
`kit/pika-constraints.js`.
Edit the source named in [MAINTAINING.md](MAINTAINING.md#where-each-fact-lives), then regenerate.

## Checks

```bash
pip install -r tools/requirements.txt                          # once
python tools/smoke.py <pack dir>                                # a game pack
python tools/gen_contract.py --firmware <firmware checkout>     # regenerate the contract
python tools/gen_contract.py --check                            # exit 1 if anything generated is stale
python tools/check_docs.py                                      # exit 1 on a wrong API name, number, link or index
```

Never edit or create `s.json`. A PC run never proves robot speed.
