---
name: pika-sdk-release
description: >
  Release the Pika SDK: run every gate in MAINTAINING.md "Before every release", pick the
  SemVer bump from CHANGELOG.md, and update sdk_version, sdk.index.json and both plugin
  versions in .claude-plugin/marketplace.json together. For the Pika team, inside a pika-sdk
  checkout. Use for "/pika-sdk-release", "release the SDK", "phát hành pika-sdk".
disable-model-invocation: true
---

# /pika-sdk-release

Run inside the pika-sdk checkout you are releasing (not the installed plugin copy). Request:
$ARGUMENTS

1. Read `MAINTAINING.md` sections "Before every release" and "Versioning", and the bump table
   at the top of `CHANGELOG.md`. Do not work from memory.
2. Run every command that section lists, from the checkout root, each in its own call, and
   keep the real exit code. A tool that needs `lupa` and reports it missing is a broken
   environment, not a pass: say so and stop.
3. Stop at the first failure and report it with its full output. Do not edit generated files
   to make a gate pass; fix the source the gate names.
4. When every gate passes, propose the bump (MAJOR / MINOR / PATCH) with the CHANGELOG reason,
   and the new CHANGELOG entry grouped as the file asks. Wait for the user's "ok".
5. After "ok", write the same version in `sdk_version`, `sdk.index.json` and every `version`
   in `.claude-plugin/marketplace.json` (installed plugins only refresh when that string
   changes), then rerun `python tools/check_docs.py`, which checks they agree.
6. Never `git add`, commit, tag or push unless the user asks in this conversation.

Report: each gate with its last output line and exit code, the version change, the files
changed, and what was not run (for example the Pika Studio check, which needs a person).
