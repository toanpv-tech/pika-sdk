---
type: llm
---

The Pika Engine has no fixed sprite count cap; live sprites are bounded by free PSRAM (and the frame budget). Text labels, by contrast, have a small fixed pool.
PASS only if the answer says there is no fixed sprite count limit and that memory (PSRAM) / performance is the bound.
FAIL if it states a fixed maximum number of sprites (such as 32, 64, 128 or 256) as the engine's limit.
