---
type: llm
---

The hook watchdog stops a game_start that runs too long; creating 85 sprites (56 identical small dots, each an image load) in one hook is the cause.
PASS only if the answer identifies the per-sprite creation/loading in game_start as the cause and proposes keeping game_start light (compute positions only) and creating the dot sprites lazily or a few per frame from on_tick (spreading the work across frames), optionally with reuse/pooling.
FAIL if it proposes raising or disabling the watchdog or another engine limit, claims the fix is verified without a new robot log, or only suggests shrinking the PNG file.
