# `libraries/` — Lua stdlib chuẩn (bản gốc)

Thư viện Lua dùng chung. Đây là **bản gốc** trong Pika SDK; công cụ tạo game của
Pika Studio copy các module cần dùng vào `libs/` của từng game (game
self-contained, không dùng chung bundle lúc chạy). Trong game, `require` qua
prefix `libs/`, resolve game-relative dưới `/sd/games/<game_id>/libs/`.

## Layout

```
libs/
├── fsm.lua            # require("libs/fsm")        — finite state machine
├── animator.lua       # require("libs/animator")   — tween/easing cho Sprite
├── ui.lua             # require("libs/ui")         — selector + confirm (1-dòng, qua Text)
├── settings.lua       # require("libs/settings")   — màn cài đặt pre-game (Start + tunables), push qua on_start(cfg)
├── save.lua           # require("libs/save")       — single-slot per-game persistence
├── testkit.lua        # require("libs/testkit")    — test harness game-side
├── math/              # require("libs/math/<mod>") — easing, lerp, vec2
└── util/              # require("libs/util/<mod>") — str, tbl
```

## Conventions

- Mỗi module `return` table `M`.
- KHÔNG global side-effect (chỉ binding chuẩn `Text`/`Sprite.*`/... qua api-map).
- KHÔNG `require("io")`/`require("os")`/`package`/`load` — sandbox cấm; `require`
  chỉ nhận `libs/<...>` game-relative.
- Nested namespace OK: `require("libs/math/vec2")` → `libs/math/vec2.lua`.
- UI dùng `Text` tối thiểu: `Text.new(str,x,y)` + `t:set/move/align/set_font`.
  `ui.lua` giữ 1 `Text` singleton render 1-dòng; game tự lái bằng
  `Input` (gọi `:next/:prev/:toggle` rồi `:render`).

Xem [API Reference](../docs/api.md) cho API chi tiết.
