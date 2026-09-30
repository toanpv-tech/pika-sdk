# Team workflow

> **For:** a team (game designer, artist, audio, developer or AI assistant, QA) · **Needs:** [Getting started](../start/getting-started.md) for everyone · **Result:** a game on the robot, with one owner per stage and clean hand-offs

The stages, inputs, outputs and gates are defined once in the [pipeline](../reference/pipeline.md).
This guide adds what a team needs on top: who owns each stage, what is handed over, and
where work usually goes wrong between people. No stage needs a robot until S8.

## Owners and hand-offs

| Stage | Owner | Hands over | To |
| --- | --- | --- | --- |
| S1 Brief | game designer | the filled [brief](../templates/brief-template.md) | developer or AI |
| S2 Challenge | developer or AI | answers to prompt A, the chosen mode | game designer (approves) |
| S3 Demo | designer + AI | demo folder, `pika-spec.json`, `shot.png`, the **To record** list | developer; artist and audio (the list) |
| S4–S5 Pack, smoke | developer or AI | the pack and the pasted smoke output | whole team |
| S6 Pika Studio | whole team | bug reports as observations ([prompt B](../templates/prompts.md#b-report-a-bug)) | developer |
| S7 Assets | artist, audio | final files under the placeholder names | developer (reruns S5) |
| S8 Publish | pack owner | the published pack | QA |
| S9 Robot check | QA | the ticked [release checklist](release-checklist.md), robot logs | whole team |

## Rules that keep hand-offs clean

- **Give the [asset guide](prepare-assets.md) to artists and audio before they start.** Images
  are shown at the size they are drawn and runtime effects do not exist; a wrong size or a
  baked-in-later effect means redrawing.
- **Names are the contract.** Placeholder files ship under their final names from S3 or S4 on,
  so final art and recordings drop in without code changes.
- **Report what you see, not a guessed cause** ("the score label is cut off", "saying *jump*
  does nothing"). The developer or AI finds the cause.
- **A gate is its pasted output.** "Smoke passed" means the output was pasted into the
  hand-off, not summarised.
- **Demos never live inside a pack folder**: everything in a pack folder ships.
- **After any change in S6, S7 or S9, rerun S5** before anyone plays again.

## When something new goes wrong

If a failure is not in `skill/pitfalls.md`, or a document is wrong, report it to the SDK
maintainers so it can be added ([MAINTAINING.md](../../MAINTAINING.md)).

## See also

- [Vibe-code a game](vibe-coding.md): the same stages for one person with an AI assistant
- [Pipeline](../reference/pipeline.md): gate commands and pass strings
