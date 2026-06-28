# `libs/` — Lua stdlib của SDK

Thư viện Lua dùng chung cho game, nằm phẳng (FLAT) trong `_sdk_<version>/libs/`. Game `require` qua prefix `@sdk/libs/`.

## Layout

```
libs/
├── .complete          # sentinel: engine chỉ nạp SDK khi file này tồn tại
├── fsm.lua            # require("@sdk/libs/fsm")        — finite state machine
├── animator.lua       # require("@sdk/libs/animator")   — tween/easing cho Sprite
├── ui.lua             # require("@sdk/libs/ui")         — selector + confirm (1-dòng, qua HUD.set_label)
├── settings.lua       # require("@sdk/libs/settings")   — màn cài đặt pre-game (Start + tunables), push qua on_start(cfg)
├── testkit.lua        # require("@sdk/libs/testkit")    — test harness game-side
├── math/              # require("@sdk/libs/math/<mod>") — easing, lerp, vec2
└── util/              # require("@sdk/libs/util/<mod>") — str, tbl
```

> Phiên bản nằm ở **tên folder umbrella** `_sdk_<version>/`, KHÔNG ở tên module. Cùng code `require("@sdk/libs/fsm")` chạy trên mọi SDK version game pin qua `manifest.sdk`.

## Atomicity

`libs/` là **cluster-atomic** qua sentinel `.complete`:
1. OTA download toàn bộ file `libs/` (atomic temp path).
2. Khi mọi file OK → touch `libs/.complete` (ghi cuối cùng).
3. `sdk_index` sniff `libs/.complete` lúc boot — thiếu = SDK đó vô hình (loại bundle OTA dở).

Power-loss giữa update không phá version cũ (multi-version coexist).

## Conventions

- Mỗi module `return` table `M`.
- KHÔNG global side-effect (chỉ binding chuẩn `HUD.*`/`Sprite.*`/... qua api-map).
- KHÔNG `require("io")`/`require("os")`/`package`/`load` — sandbox cấm; `require` chỉ nhận `@sdk/libs/<...>`.
- Nested namespace OK: `require("@sdk/libs/math/vec2")` → `_sdk_<ver>/libs/math/vec2.lua`.
- UI bám HUD tối thiểu: `HUD` chỉ có `set_label`/`show_score`/`set_font` (1 dòng). `ui.lua` cung cấp `ui.selector` + `ui.confirm` render 1-dòng; game tự lái bằng `Input` (gọi `:next/:prev/:toggle` rồi `:render`).

Xem [SD-Resources.md §2](../../../../Lua/SD-Resources.md) + [api-map](../../../../docs/sdk/pika-sdk-api-map.md) cho resolver + API chi tiết.
