# [Goal, as a verb phrase: "Localize a game"]

> **For:** [who reads this] · **Needs:** [link to what must be done first] · **Result:** [what exists when you finish, and the stage IDs it covers]

<!--
How to use this template (delete this comment in the real guide):

- A guide is one reader + one goal. Two audiences or two goals = two guides.
- File name: docs/guides/<verb>-<object>.md, e.g. localize-a-game.md.
- Keep the line above exactly in this form; tools/check_docs.py checks it.
- Refer to pipeline stages by ID (S0-S9, docs/reference/pipeline.md); do not redefine a gate.
- Never copy an API signature, a limit or a manifest rule into a guide. Link to
  docs/reference/ instead. Where a number truly helps the reader, write it as
  (`key` = value) with a key from contract/constraints.json; check_docs verifies it.
- Behaviour that is not proven in the firmware is labelled 🧪 (heuristic).
- Link to prompts in docs/templates/prompts.md instead of pasting them here.
- Add the guide to docs/docs.index.json and to the table in docs/README.md, then run
  python tools/check_docs.py.
-->

One or two sentences: why someone would follow this guide and what it does not cover.

## Steps

### 1. [Step name]

- **Do:** [what the reader does, in the imperative]
- **Check:** [what the reader verifies, and how]
- **Done when:** [an observable result: a tool's exact output, or a named check]

### 2. [Step name]

- **Do:**
- **Check:**
- **Done when:**

## When something goes wrong

Symptom first; each item links to the entry that explains it (skill/pitfalls.md, a
reference page, or a known issue).

- **[What the reader sees]** — [one line] ([details](../../skill/pitfalls.md))

## See also

- [Related guide](../guides/vibe-coding.md) — [why to read it next]
