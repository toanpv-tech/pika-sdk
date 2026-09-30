# Game brief template

Stage S1 of the [pipeline](../reference/pipeline.md). Copy this file, fill in the `[...]`
parts and give it to the AI with [prompt A](prompts.md#a-start-a-game-from-a-brief). A
complete brief is the cheapest way to get the right game on the first try.

## 1. One-sentence pitch

[e.g. A mouse walks through a maze by reading aloud the English word on each signpost.]

## 2. Players

- Age: [e.g. 6–10]
- Alone or with an adult: [...]
- Length of one play: [e.g. 2–3 minutes]

## 3. Learning goals (do not leave empty)

This is an educational game; these answers shape everything else.

- Topic and word set: [e.g. food: apple, bread, milk, ...]
- What the child must **say** (if anything): [single words / short phrases]. Voice is
  English keyword spotting: the robot matches against a list you give, it does not
  understand free speech.
- What the child must **read** or **recognise**: [...]
- UI language (instructions, score) vs learning language (the words practised):
  [e.g. UI follows the robot's language setting; words are always English]
- On a **wrong answer**: [e.g. play the word again, no penalty]
- On **silence** (no answer within N seconds): [e.g. hint, then move on]
- Must the child speak to progress, or are buttons an equal alternative: [...]

## 4. Controls

The robot has three buttons (LEFT, ENTER, RIGHT) plus HOME, which leaves the game.

| Action | Button | Voice keyword (optional) |
| --- | --- | --- |
| [e.g. start] | ENTER | ["start"] |
| [e.g. move left] | LEFT | ["left"] |

- Voice can fail (no network, noisy room). How does the game continue with buttons only:
  [...] (buttons must always be enough to finish a play)
- What should a short HOME press do during play: [exit / ask first] (holding HOME always exits)

## 5. Rules

- Goal: [...]
- Win when: [...]
- Lose when: [...]
- Scoring: [...]
- Difficulty progression: [...]

## 6. Screens

[e.g. Title → level intro → play → result (score + leaderboard)]

## 7. Robot features

- Sounds and spoken lines, and when: [...] (every spoken line is a recording; list them)
- Servo gestures, and when: [e.g. a happy nod on a win]
- LED: [e.g. green while listening]
- Leaderboard: [yes / no]

## 8. Look

- Style: [placeholder blocks / final art by an artist]
- Characters, items, backgrounds: [...]
- Has the artist read the [asset guide](../guides/prepare-assets.md): [yes / no]

## 9. Limits to design within

Exact numbers are in the [API reference](../reference/api.md#limits); the AI checks the
brief against them in S2.

- Screen 480 × 320, landscape.
- A small, fixed pool of text labels and of (font, size) faces; no word wrap and no text
  width query: plan line breaks and leave room for the longest translation.
- No sprite count cap, but every image costs memory while it is loaded
  ([asset guide](../guides/prepare-assets.md#3-memory)).
- Rotation and scaling only for small sprites; larger images are pre-drawn at each size or
  angle.
- One animation (GIF/MJPEG) and one sound play at a time; a new sound cuts the previous one.
- No text-to-speech: every spoken line is a recorded file.
- Nothing is saved between plays except scores sent to the leaderboard.
- Voice recognises only the English keywords you list, and needs the network.
