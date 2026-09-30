# Pika SDK

Build games for the **PIKA robot** without needing the robot.

PIKA runs a Lua 5.5 game engine on its head board: a 480 × 320 screen, three buttons plus
HOME, a speaker, an RGB LED, four servos and English keyword voice. This SDK is the official
source of truth for everything a game developer, or the AI assistant they vibe-code with,
needs to build for it.

| You want to | Start here |
| --- | --- |
| make your first game | [docs/start/getting-started.md](docs/start/getting-started.md) |
| make a game with an AI assistant | [docs/guides/vibe-coding.md](docs/guides/vibe-coding.md) (the AI reads [skill/SKILL.md](skill/SKILL.md)) |
| let Claude Code build it | open this folder in Claude Code and type `/pika-game <your idea>` |
| sketch a game in the browser first | [docs/guides/design-a-demo.md](docs/guides/design-a-demo.md) · [kit/template/](kit/template/) |
| look up a call or a limit | [docs/reference/api.md](docs/reference/api.md) · [contract/](contract/) |
| see every stage and its gate | [docs/reference/pipeline.md](docs/reference/pipeline.md) |
| find a quick answer | [docs/start/faq.md](docs/start/faq.md) |

## How a game gets made

```text
 S1-S2 brief ─► S3 browser demo (optional) ─► S4-S5 Lua pack + smoke ─► S6 Pika Studio ─► S7 final assets ─► S8 publish ─► S9 robot check
                kit/pika-frame.js              tools/smoke.py             the real engine,
                same API + limits,             real Lua 5.5 against       compiled for a PC
                live lints                     a stub built from the contract
                playtest.js + check_spec.py
```

Each stage has a gate: a command with an exact pass string, or a named human check
([pipeline](docs/reference/pipeline.md)). No tool on a PC measures speed or checks `s.json`;
only a robot proves those ([PC vs robot](docs/reference/known-issues.md#pc-vs-robot)).

## Layout

```text
pika-sdk/
├── contract/      the source of truth
│   ├── api.json          every Lua global, function, method, constant and hook   (generated)
│   ├── constraints.json  every limit, derived value and behaviour fact           (generated)
│   ├── semantics.json    the behaviour of every call and hook, known issues      (hand-written)
│   └── pages/            reference pages written around {{key}} placeholders     (hand-written)
├── docs/          for people: start/, guides/, concepts/, reference/, templates/ (docs/README.md)
├── skill/         for AI assistants: routing, rules, recipes, templates (skill/SKILL.md)
├── kit/           browser robot frame: pika-frame.js, pika-constraints.js, template/
├── libraries/     Lua modules to copy into <game>/libs/
├── examples/      runnable packs (pick_word = the kit template, ported)
├── tools/         gen_contract.py · check_docs.py · smoke.py · playtest.js · check_spec.py · png2rgb565.py
├── lua-5.5.0/     the Lua source the engine embeds, with the robot's build flags
├── sdk_version    the SDK version (shown by Pika Studio)
└── sdk.index.json section manifest read by Pika Studio
```

Every section has a machine-readable index, so tools and AI assistants never need to scan
the tree.

## Keeping it true

API names and numbers are never typed by hand. `tools/gen_contract.py` reads them from the
firmware source and renders the reference pages; `tools/check_docs.py` checks everything
else against the result.

```bash
python tools/gen_contract.py --firmware <pika-firmware checkout>   # regenerate contract/, kit/pika-constraints.js, reference pages
python tools/gen_contract.py --check                               # exit 1 if anything generated is stale
python tools/check_docs.py                                         # exit 1 on a wrong API name, number, link, anchor or index
```

How to change the SDK: [MAINTAINING.md](MAINTAINING.md). Why it is built this way:
[RATIONALE.md](RATIONALE.md).

## Versioning

`sdk_version` follows SemVer ([CHANGELOG.md](CHANGELOG.md)). The firmware does not report
an API version, so the proof that this SDK matches a firmware build is
`python tools/gen_contract.py --firmware <checkout> --check`.

## Using it from Pika Studio

Run **Pika: Configure SDK Source** and give this folder or its git URL. Studio reads
`sdk.index.json` and shows the docs, examples and libraries.
