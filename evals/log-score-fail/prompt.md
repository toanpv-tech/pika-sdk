---
description: "A robot log with api_fail and drop is scored FAIL on the release telemetry gates, not called fine."
tags: [knowledge, tester]
max_turns: 12
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Game Pika của mình chạy trên robot, log serial như sau. Game này đã sẵn sàng phát hành chưa?

```
I (812345) game.engine: game.start game=bubble trigger=menu ready=1210 queue=3 init=40 load=900 anim=10 render=50 arena=150000 psram=3000000 heap=70000 fps_target=33
I (842400) game.engine: game.running t=30 tick_hz=33 tick_us=9000 gap_us=30000 p95=12000 slow_n=3 heap=70000 arena=151000 hwm_engine=1000 ccalls=3
I (899000) game.engine: game.stop game=bubble end=norm dur=127 frames=4180 tick_hz=33 draw_pm=968 p95=16000 slow_pm=11 arena_pk=207872 heap_min=62464 psram=2983936 drop=0/3/0/0/0 api_fail=4 tel=0/0 tel_us_max=0
```
