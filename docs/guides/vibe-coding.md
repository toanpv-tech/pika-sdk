# Vibe-code a game

> **For:** one person building a game with an AI assistant, no programming needed · **Needs:** [Getting started](../start/getting-started.md) · **Result:** a finished game that plays well in Pika Studio and is ready to publish

You bring the idea, play the game and judge it; the AI writes everything else. This guide
walks the [pipeline](../reference/pipeline.md) stage by stage and says, for each one, what to
ask the AI, what to check yourself, and when to move on. The rules the AI follows are in
`skill/`; the prompts that make it read them are in [prompts](../templates/prompts.md).

The habit that saves the most time: **ask for proof, not for a summary.** "It works" means
nothing; the pasted output of a tool does.

## Stages

### S0. Set up

- **Do:** follow [Getting started](../start/getting-started.md). Open the SDK folder, or your
  game folder next to it, in the editor where your AI assistant runs, so it can read `skill/`
  and `contract/`.
- **Done when:** the S0 gate passes and `pick_word` plays in Pika Studio.

### S1. Write the brief

- **Do:** copy the [brief template](../templates/brief-template.md) and fill it in. Spend most
  of the time on **learning goals** (what the child practises and says, what happens on
  silence or a wrong answer) and **controls** (three buttons; voice only as an extra).
- **Done when:** every section has an answer, including "what if voice does not work", and
  someone else could describe the game back to you.

### S2. Let the AI challenge the brief

- **Do:** paste [prompt A](../templates/prompts.md#a-start-a-game-from-a-brief). The AI reads
  `skill/` and answers seven questions **before** coding.
- **Check:** points 5 (the budget) and 6 (what the robot cannot do). Correct anything wrong
  about the learning design; the AI must not change it on its own.
- **Done when:** you have answered its questions and agreed on *demo first* (several screens,
  custom art or recorded voice lines) or *Lua directly*.

### S3. Play the browser demo *(demo first)*

- **Do:** let the AI build the demo. Open its `index.html`, play with the arrow keys and
  Enter, and ask for changes in words ("the cards are too small", "wait longer before the
  hint").
- **Check:** the lint panel shows no red lines. Ask the AI to run the S3 gate and paste both
  outputs.
- **Done when:** the pasted output ends with `Verdict: READY TO PORT` and you like how it
  plays. Keep the **To record** list it prints.

### S4. Get the Lua pack

- **Do:** ask the AI to port the demo ([prompt C](../templates/prompts.md#c-port-a-kit-demo)),
  or, without a demo, to write the pack (it continues from prompt A).
- **Check:** the AI names the template or example it started from and reuses `libraries/`
  instead of writing its own copies.
- **Done when:** a pack folder exists **outside** the demo folder.

### S5. Smoke check

- **Do:** ask the AI to run the S5 gate with a step list that visits every branch, and paste
  the **full** output.
- **Check:** read the last line yourself: it must say `0 error(s)`. Ask the AI to explain every
  warning and fix the ones that matter.
- **Done when:** `0 error(s)`. Do not spend time in Pika Studio before this.

### S6. Play in Pika Studio

- **Do:** open the pack and press **Run**. Play every path at least twice: win, lose, every
  wrong answer, restart. Report what you **see** with [prompt B](../templates/prompts.md#b-report-a-bug).
- **Check:** after each fix the AI pastes a fresh smoke output before you play again.
- **Done when:** two full rounds of every path with nothing to report.

### S7. Final art and sound

- **Do:** give the artist or audio person the [asset guide](prepare-assets.md) and the
  **To record** list from S3. Replace each placeholder with the final file under **the same
  name**.
- **Check:** replacing files needs no code change; ask the AI to run smoke again.
- **Done when:** no placeholder is left and smoke still says `0 error(s)`.

### S8. Publish to a robot

- **Do:** have the pack published through the Pika platform ([S8](../reference/pipeline.md#gates)).
  Copying the folder to an SD card is not enough.
- **Done when:** the robot opens your game.

### S9. Check it on a robot

- **Do:** play it on the robot and work through the [release checklist](release-checklist.md).
  If it stutters or stops, copy the robot's `game.*` log lines and give them to the AI with
  [prompt D](../templates/prompts.md#d-review-a-robot-run).
- **Done when:** every checklist item is ticked. A game not checked on a robot is not
  finished.

## When the AI drifts

| You notice | It usually means | Say |
| --- | --- | --- |
| "Done, it works" with no pasted output | it has not run the tools | "Run `tools/smoke.py` and paste the full output." |
| A function you never saw in the docs, or `os`, `io`, `setTimeout`, `async` | it writes from habit, not from the contract | "Check every call against `contract/api.json`; re-read `skill/SKILL.md`." |
| It changes the rules or adds a button shortcut to a speaking task | it overrides your learning design | "Keep the brief's learning goals; ask me before changing gameplay." |
| It quotes a limit from memory ("32 sprites", "80 ms") | numbers from memory are often wrong | "Take limits only from `contract/constraints.json`." <!-- number-ok --> |
| It creates or edits `s.json`, or says copying to SD makes the game run | it misunderstands publishing | "Never touch `s.json`; publishing is stage S8." |
| "It will be smooth on the robot" | a guess; nothing on a PC measures speed | "Only a robot run shows that; list what to check in S9." |
| The same bug comes back after a fix | it fixed a symptom | "Explain the cause from the code before changing anything." |

Symptoms of the game itself (a sprite that never shows, silence, the game stopping) are
indexed in `skill/pitfalls.md`; prompt B makes the AI look there first.

## See also

- [Team workflow](team-workflow.md): who does what when several people share the stages
- [Pipeline](../reference/pipeline.md): every gate command and its exact pass string
