# Pika SDK documentation

Everything for making educational games for the PIKA robot. New here? Start with
[Getting started](start/getting-started.md). An AI assistant starts at
[skill/SKILL.md](../skill/SKILL.md) instead.

## Find your page

| You are | You want to | Read |
| --- | --- | --- |
| alone, with an AI assistant | make a whole game | [Vibe-code a game](guides/vibe-coding.md) |
| a team | split the work and hand it over cleanly | [Team workflow](guides/team-workflow.md) |
| anyone | see every stage and how it is proven done | [Pipeline](reference/pipeline.md) |
| a designer or developer | try a game in the browser first | [Design a demo](guides/design-a-demo.md) |
| a developer | write a Lua game pack | [Write a game pack](guides/write-a-game-pack.md) |
| a developer | turn a browser demo into Lua | [Port a demo](guides/port-a-demo.md) |
| an artist or audio person | deliver files the robot uses as they are | [Prepare assets](guides/prepare-assets.md) |
| QA | publish and check a game on a robot | [Release checklist](guides/release-checklist.md) |
| anyone | get a quick answer to a common question | [FAQ](start/faq.md) |

## By kind

| Kind | For | Pages |
| --- | --- | --- |
| **Start** | follow once, end with working tools; quick answers | [Getting started](start/getting-started.md) · [FAQ](start/faq.md) |
| **Guides** | reach one goal, step by step | the table above |
| **Concepts** | why the robot and engine work this way | [Overview](concepts/overview.md) |
| **Reference** | exact facts, generated from or checked against the firmware | [Pipeline](reference/pipeline.md) · [API](reference/api.md) · [manifest.json](reference/manifest.md) · [Telemetry](reference/telemetry.md) · [Known issues](reference/known-issues.md) |
| **Templates** | fill in or copy | [Brief](templates/brief-template.md) · [Prompts](templates/prompts.md) · [Guide template](templates/_guide-template.md) |

## How these pages stay true

- The API, manifest, telemetry and known-issues pages are **generated** by
  `tools/gen_contract.py` from the firmware source and `contract/semantics.json`; never edit
  them by hand. A name that is not in `contract/api.json` does not exist on the robot.
- Guides say what to do and link to the reference for facts. They do not repeat signatures
  or limits; a number that helps the reader is written as (`key` = value) and checked.
- `tools/check_docs.py` fails on a broken link or anchor, an unknown API name, a number that
  disagrees with the contract, or an index that is out of date.

Writing a new page: copy the [guide template](templates/_guide-template.md) and follow
[MAINTAINING.md](../MAINTAINING.md). Why the SDK is organised this way:
[RATIONALE.md](../RATIONALE.md).
