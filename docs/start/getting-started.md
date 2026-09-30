# Getting started

Install the tools, prove they work, and see one game in both forms it takes: a browser demo
and a Lua pack. This is stage S0 of the [pipeline](../reference/pipeline.md). No C and no
firmware knowledge needed.

## 1. Install

| Tool | For | Install |
| --- | --- | --- |
| Pika Studio | running packs on the real engine, compiled for a PC | the VS Code extension from the Pika team: `code --install-extension pika-studio-<version>.vsix --force` |
| This SDK in Studio | examples, libraries, docs inside Studio | **Pika: Configure SDK Source** (setting `pika.sdk.source`): the SDK folder or its git URL; **Pika: Refresh SDK (git pull)** updates it |
| Python 3 | `tools/smoke.py`, `tools/check_spec.py`, `tools/png2rgb565.py` | then `pip install -r tools/requirements.txt` |
| Node.js *(demo first only)* | `tools/playtest.js` | then `cd tools && npm install && npx playwright install chromium` |

## 2. Prove the tools work

From the SDK root:

```bash
python tools/smoke.py examples/pick_word
```

Pass: the last line is `0 error(s), 0 warning(s)` and the exit code is 0. If it fails, fix
the install before going further: every later stage relies on this tool.

## 3. The same game, twice

`kit/template/index.html` is a browser demo; `examples/pick_word/` is the same game as a Lua
pack. Reading them side by side once shows what "porting is transliteration" means.

- **Browser.** Open `kit/template/index.html` directly (`file://` works). Keys: `←`/`A`,
  `Enter`/`Space`, `→`/`D`, HOME `H`. The side panel shows the resource budget and live lints.
- **Pika Studio.** Run **Pika: New Game from Example…**, pick `pick_word`, then **Pika: Run**.
  Keys: ENTER `Enter`/`Space`, LEFT `←`/`A`, RIGHT `→`/`D`. **Pika: Open Documentation**
  shows these pages inside Studio.

To start your own demo, copy `kit/template/` to a folder **next to it** (a sibling inside
`kit/`), or copy `kit/pika-constraints.js` and `kit/pika-frame.js` along and fix the two
`<script>` paths. Keep demos outside every pack folder: everything in a pack folder ships.

## 4. What the PC cannot show

Pika Studio runs the real engine, but not the robot: speed, HOME, LED, servos and real voice
are only proven on a robot, and nothing on a PC checks `s.json`. The full list is in
[Known issues → PC vs robot](../reference/known-issues.md#pc-vs-robot). A pack runs on a
robot only after it is published (stage S8).

## Next

| You want to | Read |
| --- | --- |
| get a first playable game from an AI in minutes | [Prompt E: Quick first game](../templates/prompts.md#e-quick-first-game) |
| make a whole game alone with an AI assistant | [Vibe-code a game](../guides/vibe-coding.md) |
| split the work in a team | [Team workflow](../guides/team-workflow.md) |
| see every stage and its gate | [Pipeline](../reference/pipeline.md) |
| understand the robot and the engine | [Overview](../concepts/overview.md) |
