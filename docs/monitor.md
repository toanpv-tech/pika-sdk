# Game Engine Monitor — Keyword

Chỉ luồng `game_engine` (head_esp32). Không lặp SYSMON/system. Keyword ngắn, giàu ý nghĩa chẩn đoán.

## 1. Session summary — tag `game.stat`

Phát **1 dòng/phiên** lúc teardown. Góc nhìn vòng đời start→end (hiện chưa có).

```text
game.stat end=<reason> dur=<s> fps=<n> p95=<us> over=<n> arena_pk=<kb> drop=<n>
```

| Key | Đơn vị | Ý nghĩa chẩn đoán |
|-----|--------|-------------------|
| `end` | enum | Lý do kết thúc: `norm` / `home` / `err` / `stall` |
| `dur` | s | Độ dài phiên chơi |
| `fps` | fps | FPS thực trung bình phiên (so target 30) |
| `p95` | µs | Tick p95 — giật đều (khác `max` một-spike) |
| `over` | count | Số frame vượt budget 33 ms (rớt frame) |
| `arena_pk` | KB | Đỉnh Lua arena trong phiên (bỏ lỡ nếu chỉ đo start/teardown) |
| `drop` | count | Tổng drop I/O cả phiên (input+sound+servo+led) |

## 2. Sự kiện hiếm — tag `game.warn`

Phát **on-event** (không định kỳ, tránh spam). Gộp 5 loại vào 1 key `kind`.

```text
game.warn kind=<type> n=<count>
```

| `kind` | Ý nghĩa |
|--------|---------|
| `overrun` | Frame vượt budget (đếm dồn) |
| `wdog` | Lua watchdog cắt pcall (script treo) |
| `memfb` | Lua alloc vượt 90% budget (nay chỉ 1 bool one-shot) |
| `voicedrop` | Voice event rớt do VM chưa sẵn sàng |
| `animerr` | GIF/MJPEG decode lỗi (âm thầm dừng anim) |

## 3. Vá SYSMON (không tạo mới — tái dùng đường MQTT sẵn có)

`HEAD_TASK_NAMES` (systemmonitor.cpp:742) **thiếu `game_engine`** và tên sai:
- Thêm `"game_engine"` (nay không được đo stack HWM).
- `"AnimationPlayerTask"` (19 ký tự → bị skip vì ≥16) → tên thật `"AnimationPlayerTask"` cần rút gọn / dùng đúng handle.
- `"lv_timer_task"` → tên thật là `"lvgl_timer"` (ui_menu.cpp:314).

→ Stack HWM + heap internal đã do SYSMON đo & đẩy MQTT; chỉ cần thêm đúng tên task.

## Đã có sẵn (KHÔNG lặp)

| Đã đo | Ở đâu |
|-------|-------|
| tick `frames`/`max_us`/`budget_us` | `engine_core.c` tick stat (log 1s\|100f) |
| `heap_psram_*`, `arena_*` | `engine_log_psram` (start + teardown) |
| stall: `last_tick`, `binding`, `heap_int_*` | `stall_detector_cb` (on-trip) |
| input/sound/servo/led counters | stats struct + Lua `*.stats()` |
| stack HWM, heap internal min, CPU, WDT | SYSMON → MQTT (system-level) |
