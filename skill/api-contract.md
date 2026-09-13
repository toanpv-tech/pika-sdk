# API Contract

> **Đây là hợp đồng đóng.** Chỉ những hàm dưới đây tồn tại. Mọi thứ khác **KHÔNG** — đừng gọi.
> Signature đã đối chiếu binding thật của engine. Bản người-đọc chi tiết hơn: [../docs/api.md](../docs/api.md).

Ký hiệu lỗi: `raise` = ném lỗi (kết thúc hook) · `false` = trả false · `(nil,msg)` = trả nil + lý do · `—` = không có nhánh lỗi.

12 global: `Engine` `Timer` `Text` `Input` `Sprite` `Anim` `Speaker` `Servo` `Led` `Voice` `Ranking` `print`.

---

## Engine — vòng đời

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Engine.exit([reason])` | — | Lên lịch dừng game; frame hiện tại chạy nốt. `reason` string default `"lua"`. |
| `Engine.report_result(tbl)` | `true` \| `(nil,msg)` | Chỉ dùng trong luồng A2A. `tbl.event` (string, bắt buộc). Bỏ qua nếu game thường. |
| `Engine.stack_hwm()` | integer | High-water mark C stack (debug). Không dùng trong gameplay. |

> **KHÔNG có `Engine.version()`** và **KHÔNG có API lưu trạng thái** — xem mục "API KHÔNG tồn tại".

## Ranking — leaderboard (qua IPC sang back)

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Ranking.report({score})` | bool | Gửi kết quả round. `duration_ms` do engine tự tính, **không** nhận từ Lua. Gọi được nhiều lần/session. `false` khi bad_score/encode_failed/payload_too_big/send_failed (không raise). |
| `Ranking.get_result()` | table \| nil | `{top={...}, my_rank=...\|nil, my_best_score=number\|nil}`. `nil` = chưa có kết quả mới hoặc đã tiêu thụ (**consume-once**). Poll từ `on_tick()`, không chỉ gọi 1 lần cuối round. |

## Timer

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Timer.millis()` | integer | Đồng hồ monotonic ms. **Đây là cách duy nhất lấy thời gian** (không có `Engine.now_ms`). |

## Text — nhãn chữ retained (pool ≤ 8)

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Text.new(str, x, y)` | handle \| `(nil,"pool_full")` | Tạo + hiện tại (x,y) góc trên-trái. Handle thứ 9 fail. |
| `t:set(str)` | — | đổi nội dung |
| `t:move(x, y)` | — | toạ độ tuyệt đối |
| `t:align(where[, dx, dy])` | — | where ∈ center/top/bottom/left/right/top_left/top_right/bottom_left/bottom_right |
| `t:set_font(path[, size])` | — | path font game-relative; size px |
| `t:set_color(0xRRGGBB)` | — | |
| `t:show(bool)` | — | ẩn/hiện |
| `t:destroy()` | — | trả slot (idempotent) |

## Input — 3 nút phần cứng

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Input.is_down(action)` | bool | poll — dùng cho chuyển động mượt |
| `Input.just_pressed(action)` | bool | true đúng 1 frame |
| `Input.just_released(action)` | bool | true đúng 1 frame |
| `Input.hold_ms(action)` | integer | ms đang giữ |
| `Input.actions()` | table | mảng 1-based tên action từ manifest |
| `Input.stats()` | table | `{events_total,events_delta,dropped_total,seq_gaps}` |

Hằng: `Input.PRESS=0` `Input.RELEASE=1` `Input.REPEAT=2`. `action` = tên bạn đặt trong `manifest.input.actions`.

## Sprite — 2D (LVGL). Method gọi bằng `spr:m(...)`

**Factory:**

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Sprite.image(path)` | userdata \| `(nil,msg)` | PNG, giữ alpha. path xấu → raise. |
| `Sprite.new(path, w, h)` | userdata \| `(nil,msg)` | RGB565 thô. |
| `Sprite.solid(w, h, rgb565)` | userdata \| `(nil,"oom")` | khối màu; w,h ∈ (0,480]×(0,320]. |

**Method:**

| Method | Trả về | Ghi chú |
|---|---|---|
| `spr:set_pos(x,y)` / `spr:get_pos()` | — / x,y | |
| `spr:get_size()` | w,h | |
| `spr:set_visible(b)` | — | |
| `spr:set_opacity(0..255)` | — | |
| `spr:set_z(z)` / `spr:to_front()` / `spr:to_back()` | — | thứ tự lớp |
| `spr:set_flip(fh, fv)` | bool | |
| `spr:set_frame(path, idx)` | bool | frame từ file RGB565 multi-frame |
| `spr:hit_test(qx, qy)` | bool | AABB chứa điểm |
| `spr:intersects(spr2)` | bool | AABB chồng — **dùng cho va chạm** |
| `spr:destroy()` | — | idempotent |

## Anim — GIF/MJPEG (1 anim cùng lúc)

| Hàm/Method | Trả về | Ghi chú |
|---|---|---|
| `Anim.new(path)` | userdata \| `(nil,msg)` | .gif/.mjpeg/.mjpg. anim mới dừng anim cũ. |
| `anim:play([loop])` | bool | `play()` / `play(true)` |
| `anim:pause()` / `:resume()` / `:stop()` | — | |
| `anim:is_playing()` | bool | |
| `anim:set_pos(x,y)` / `:set_visible(b)` | — | |
| `anim:destroy()` | — | idempotent |

## Speaker — âm thanh (cooldown 150ms giữa 2 play)

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Speaker.play(alias)` | bool | false nếu alias lạ/lỗi/cooldown |
| `Speaker.stop(alias)` | bool | |
| `Speaker.stop_all()` | bool | |
| `Speaker.is_playing(alias)` | bool | dự đoán cục bộ |
| `Speaker.is_busy()` | bool | true nếu pipeline bận |
| `Speaker.set_volume(0..100)` | — | |
| `Speaker.get_volume()` | integer | |
| `Speaker.stats()` | table | |

Hằng `reason` (trong `on_sound_end`): `Speaker.REASON_COMPLETED=0` `REASON_STOPPED=1` `REASON_PREEMPTED=2` `REASON_ERROR=3`. **So với hằng, không số literal.**

## Servo — khớp robot (async, qua IPC)

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Servo.pose(alias)` | bool | gesture nhiều khớp |
| `Servo.move(alias, angle, duration_ms[, easing])` | bool | easing ∈ linear(default)/in_out/bounce |
| `Servo.stop([alias])` | bool | không arg → stop cả 4 khớp |
| `Servo.is_busy(alias)` | bool | dự đoán cục bộ |
| `Servo.list()` | table | `{servos={alias→hw}, poses={alias→gesture}}` |
| `Servo.stats()` | table | |

## Led — đèn RGB (qua IPC)

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Led.set(r,g,b)` | bool | mỗi kênh 0..255 |
| `Led.off()` | bool | |
| `Led.preset(name)` | bool | name ∈ user_talk/conv_processing/robot_talking/warm_white/light_blue/dark_blue |
| `Led.blink(r,g,b,period_ms)` | bool | period_ms ∈ [333,5000] (REJECT ngoài khoảng — chống <3Hz) |
| `Led.pulse(r,g,b,duration_ms)` | bool | duration_ms ∈ [100,5000], one-shot rồi auto-off |
| `Led.set_brightness(0..100)` | bool | |
| `Led.get_brightness()` | integer | mirror lần push gần nhất, không query live |
| `Led.is_available()` | bool | |
| `Led.stats()` | table | |

## Voice — keyword-spotting (KHÔNG phải hội thoại tự do)

| Hàm | Trả về | Ghi chú |
|---|---|---|
| `Voice.set_keywords(list[, sensitivity])` | `true` \| `(nil,reason)` | list = mảng string thuần (1..64); sensitivity 1..10 (default 5). Gọi trước start. |
| `Voice.start()` | `true` \| `(nil,"send_failed")` | |
| `Voice.stop()` | bool | idempotent |
| `Voice.is_available()` | bool | |

> **`Voice.mode()` đã bị gỡ.** Muốn biết game có chạy trong talk flow A2A không: đọc `params.is_a2a` trong `game_start(params)` — **nguồn duy nhất**.

Nhận lệnh qua `on_voice_event(e)`: `e.type == "VOICE_COMMAND"` → `e.data.keyword`. Chi tiết + mẫu: [recipes/voice-keyword-trigger.md](recipes/voice-keyword-trigger.md).

## print

`print(...)` → ESP_LOG tag `[lua]`. Không stdout. Dùng để debug.

---

## API **KHÔNG** tồn tại (đừng gọi)

Đây là những thứ AI hay bịa vì có ở engine khác. **Không có** trong Pika:

| Bịa | Thay bằng |
|---|---|
| `Engine.now_ms()`, `os.time()`, `os.clock()` | `Timer.millis()` |
| `love.*`, `update()`, `on_draw()`, `draw()` | hook `on_tick` + Sprite/Text retained |
| `require("json")`, `require("socket")`, module ngoài | chỉ `require("libs/…")` trong game |
| `io.*`, `os.*`, `os.execute` | sandbox chặn hết — không có cách ghi file nào từ Lua |
| `State.*` (`State.save/load/get/set/has_save/clear`) | **Đã bị gỡ khỏi engine.** Hiện **không có API lưu trạng thái** qua phiên chơi. Điểm số chỉ sống trong 1 phiên (hoặc đẩy lên server bằng `Ranking.report`). |
| `Voice.mode()` | `params.is_a2a` trong `game_start(params)` |
| `Engine.version()` | không có; đừng in version từ Lua |
| `Sprite.rotate`, `spr:rotate()`, `spr:scale()` | không có xoay/scale; chỉ flip (`set_flip`) |
| `Sprite.text(...)`, vẽ chữ lên sprite | dùng `Text.*` (label riêng) |
| `Speaker.play_file("path.wav")` | `Speaker.play("<alias>")` (khai alias trong manifest) |
| `Voice.listen()`, STT tự do, `Voice.transcribe` | `Voice.set_keywords` + `on_voice_event` (chỉ match keyword) |
| `Input.on(...)`, đăng ký callback nút | định nghĩa hook global `on_input(action, phase, hold_ms)` |
| `math.random` seed từ `os.time` | `math.random` OK nhưng seed bằng `Timer.millis()` nếu cần |
| `collectgarbage("count")` để "tối ưu" | để engine quản lý; heap Lua = 512KB PSRAM cố định |

> Quy tắc: **không thấy trong bảng trên phần "TỒN TẠI" = không gọi.** Nếu cần một khả năng không có, hỏi người dùng thay vì bịa.
