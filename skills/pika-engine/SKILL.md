---
name: pika-engine
description: >
  The checked facts about the PIKA robot's Pika Engine for Lua games: every API, hook, limit,
  manifest key, telemetry line, known issue and pitfall, generated from the firmware. Use for
  ANY question about writing, porting, reviewing or debugging a Pika game pack (sprites, Text,
  sound, voice, servo, LED, input, manifest, performance, robot log lines) before answering
  from general Lua or game knowledge.
---

# Pika Engine facts → Pika SDK

The SDK is the installed plugin at `${CLAUDE_PLUGIN_ROOT}`. Answer from it, never from memory:
the engine differs from desktop Lua and from other game engines in ways that look plausible
and are wrong.

1. Read `${CLAUDE_PLUGIN_ROOT}/knowledge/SKILL.md` first: golden rules and the load table that
   says which file answers which kind of question.
2. API names and behaviour: `knowledge/api-contract.md`. Limits and known issues:
   `knowledge/constraints.md`. Both are generated from the firmware; the raw values are in
   `contract/api.json` and `contract/constraints.json`.
3. A failure, an odd behaviour or a robot log line: `knowledge/pitfalls.md` and
   `docs/reference/telemetry.md`.
4. Quote the file you answered from. When the SDK does not settle a question, say so and give
   the safe way from `knowledge/open-questions.md`; never fill the gap with a guess.

For building or changing a pack, use `/pika-game`; for testing one, `/pika-test`.
