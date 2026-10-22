---
name: pika-test
description: >
  Test a PIKA robot game pack with the pika-game-tester agent: smoke runs over every branch and
  UI language, and a robot or Pika Studio serial log scored against the release telemetry
  gates. Use for "/pika-test games/<id>", "/pika-test games/<id> robot.log".
disable-model-invocation: true
---

# /pika-test

Request: $ARGUMENTS

1. Find the pack: the folder named in the request, else the only folder under `games/` with a
   `manifest.json`; if there are several, ask which one.
2. If a serial log path was given, check that the file exists. If none was given, ask once
   whether the game ran on a robot or in Pika Studio with a log; without one the test stops
   at smoke.
3. Start the `pika-game-tester` agent with the pack folder, the log path, the UI languages
   from the manifest or the user, and what changed since the last test if the user said so.
   It cannot see this conversation, so write all of that out.
4. Relay its verdict, the branch table (also when the verdict is BLOCKED), every finding with
   where it is, and the key presses
   for Pika Studio. On FAIL, offer to send the findings to `pika-game-maker` (or
   `pika-game-porter` for a ported game) and test again.
