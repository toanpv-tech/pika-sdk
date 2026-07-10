# Pika Engine — Tham chiếu API Lua

> **Đối tượng:** Người viết game pack — tra cứu nhanh từng hàm Lua.
> **Tài liệu kèm:** [Guide](guide.md) (quickstart, manifest, vòng đời, sandbox) · [Module Firmware](module.md) (kiến trúc nội bộ).

Engine expose ~60 hàm Lua qua các bảng global: `Engine`, `State`, `Timer`, `Text`, `Input`, `Sprite`, `Anim`, `Speaker`, `Servo`, `Led`, `Voice`, `print`.

---

## Tham chiếu API Lua

Quy ước cột **Lỗi**: `raise` = ném lỗi (pcall bắt, kết thúc hook) · `false` = trả `false` · `(nil,msg)` = trả `nil` + chuỗi lý do · `—` = không có nhánh lỗi riêng. Bảng **method** (`spr:...`, `anim:...`) là loại bảng riêng, dùng cột `Method | Trả về | Ghi chú`.

### `Engine` — vòng đời

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Engine.exit([reason])` | — | — | Lên lịch dừng game; frame hiện tại chạy nốt. `reason` (string, default `"lua"`) ghi log. |

### `State` — lưu trữ KV / blob (per-game)

KV store sống trong registry 1 phiên; `save/load` ghi xuống `save.sav` trên SD.

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `State.set(key, value)` | — | — | KV scalar (number/string/bool). |
| `State.get(key)` | any\|nil | — | |
| `State.save([blob])` | bool | — | Không arg → serialize bảng KV thành JSON. Có `blob` (string) → ghi verbatim. Vượt 4KB → `false`. |
| `State.load()` | bool\|string\|nil | — | KV save → repopulate + trả `true`; blob save → trả string; không có → `nil`. |
| `State.has_save()` | bool | — | Kiểm tra nhẹ cho nút "Continue". |
| `State.clear()` | bool | — | Xóa save (đã rỗng cũng tính thành công). |

> ⚠️ `State.save` chạm FATFS — chỉ gọi ở checkpoint, **không** trong `on_tick`. Định dạng file: header `PSV1` 12 byte + payload nhị phân (giữ NUL), ghi atomic qua `.tmp` rename ([save_store.c](../../head_esp32/components/game_engine/src/platform/save_store.c)). Trần `CONFIG_GAME_ENGINE_SAVE_MAX_BYTES` = 4096 byte.

### `Timer`

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Timer.millis()` | integer | — | Đồng hồ monotonic (ms). Wrap ~49.7 ngày. |

### `Text` — retained text labels

Nhãn chữ có handle, giữ trạng thái (không phải vẽ-mỗi-frame). Pool tối đa 8 nhãn cùng lúc; `Text.new` thứ 9 trả `(nil,"pool_full")`. Nhãn tự huỷ khi game thoát.

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Text.new(str, x, y)` | handle | (nil,msg) | Tạo + hiện ngay tại `(x,y)` (góc trên-trái). `(nil,"pool_full")` khi hết slot. |
| `t:set(str)` | — | raise (sai arg) | Đổi text (bỏ qua nếu không đổi). |
| `t:move(x, y)` | — | raise | Đặt lại toạ độ tuyệt đối. |
| `t:align(where[, dx, dy])` | — | (nil,msg) | `where` ∈ `center/top/bottom/left/right/top_left/top_right/bottom_left/bottom_right`; `dx,dy` offset (default 0). |
| `t:set_font(path[, size])` | — | (nil,msg) | `path` font sandbox-relative; `size` px (default mặc định engine). |
| `t:set_color(0xRRGGBB)` | — | raise | Màu chữ. |
| `t:show(bool)` | — | — | Ẩn/hiện. |
| `t:destroy()` | — | — | Trả slot về pool (idempotent). |

### `Input`

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Input.is_down(action)` | bool | raise (thiếu arg) | action lạ → `false`. |
| `Input.just_pressed(action)` | bool | raise | PRESS frame này. |
| `Input.just_released(action)` | bool | raise | RELEASE frame này. |
| `Input.hold_ms(action)` | integer | raise | Số ms đang giữ. |
| `Input.actions()` | table | — | Mảng 1-based tên action từ manifest. |
| `Input.stats()` | table | — | `{events_total, events_delta, dropped_total, seq_gaps}`. |

Hằng: `Input.PRESS=0`, `Input.RELEASE=1`, `Input.REPEAT=2`.

### `Sprite` — đồ họa 2D (LVGL)

Factory trả `userdata` (metatable `pika.sprite`) hoặc `(nil, msg)`. Gọi method bằng `spr:method(...)`. Tối đa `CONFIG_GAME_ENGINE_MAX_SPRITES` = 32 sprite; ảnh ≤ 480×320.

**Factory:**

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Sprite.image(path)` | userdata \| (nil,msg) | path xấu → raise; nạp thất bại → (nil,msg) | Decode PNG (cần PNG decoder của firmware), giữ alpha. |
| `Sprite.new(path, w, h)` | userdata \| (nil,msg) | path xấu → raise | Nạp RGB565 thô. |
| `Sprite.solid(w, h, rgb565)` | userdata \| (nil,"oom") | w,h ∈ (0,480]×(0,320] | Khối màu in-memory; `rgb565` clamp 0xFFFF. |

**Method:**

| Method | Trả về | Ghi chú |
|---|---|---|
| `spr:set_pos(x, y)` | — | |
| `spr:get_pos()` | x, y | |
| `spr:get_size()` | w, h | |
| `spr:set_visible(b)` | — | |
| `spr:set_opacity(opa)` | — | clamp 0..255 |
| `spr:set_z(z)` / `spr:to_front()` / `spr:to_back()` | — | thứ tự lớp |
| `spr:set_flip(fh, fv)` | bool | |
| `spr:set_frame(path, idx)` | bool | ghi đè pixel từ frame `idx` trong file RGB565 multi-frame; path xấu → raise |
| `spr:hit_test(qx, qy)` | bool | AABB chứa điểm |
| `spr:intersects(spr2)` | bool | AABB chồng nhau |
| `spr:destroy()` | — | dọn thủ công (idempotent, an toàn với GC) |

### `Anim` — GIF / MJPEG

Factory trả userdata (metatable `pika.anim`). Định dạng theo đuôi file (case-insensitive): `.gif`, `.mjpeg`, `.mjpg`. Anim ≤ 4MB, frame delay ≥ 10ms.

**Factory:**

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Anim.new(path)` | userdata \| (nil,msg) | đuôi lạ / path xấu → raise; nạp thất bại → (nil,msg) | 1 anim hoạt động cùng lúc; anim mới dừng anim cũ. |

**Method:**

| Method | Trả về | Ghi chú |
|---|---|---|
| `anim:play([loop])` | bool | `play()` (loop=false) / `play(true)` / `play({loop=true})` |
| `anim:pause()` / `anim:resume()` / `anim:stop()` | — | |
| `anim:is_playing()` | bool | |
| `anim:set_pos(x,y)` / `anim:set_visible(b)` | — | |
| `anim:destroy()` | — | idempotent |

### `Speaker` — âm thanh

Alias khai báo trong `manifest.audio.sounds`. Có cooldown engine 80ms giữa 2 lần `play` (vượt → `false`, đếm vào `cooldown_reject`).

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Speaker.play(alias)` | bool | → `false` nếu alias lạ/lỗi/cooldown | |
| `Speaker.stop(alias)` | bool | — | |
| `Speaker.stop_all()` | bool | — | idempotent (luôn true) |
| `Speaker.is_playing(alias)` | bool | — | dự đoán cục bộ, không phải ACK HW |
| `Speaker.is_busy()` | bool | — | true nếu pipeline bận (kể cả voice/anim) |
| `Speaker.set_volume(pct)` | — | — | clamp 0..100 (làm tròn, ví dụ 50.7→51) |
| `Speaker.get_volume()` | integer | — | override phiên hoặc NVS |
| `Speaker.stats()` | table | — | `{played_total, finish_dropped, error_count, cooldown_reject, speaker_abandoned_current, speaker_abandoned_peak}` |

Hằng `reason` (dùng trong `on_sound_end`): `Speaker.REASON_COMPLETED=0`, `REASON_STOPPED=1`, `REASON_PREEMPTED=2`, `REASON_ERROR=3`.

```lua
function on_sound_end(alias, reason)
  if reason == Speaker.REASON_COMPLETED then ... end   -- luôn so với hằng, không dùng số literal
end
```

### `Servo` — khớp robot (qua IPC sang back)

Alias trong `manifest.servos`/`poses`. Async fire-and-forget.

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Servo.pose(alias)` | bool | → `false` nếu alias lạ | chạy gesture nhiều khớp |
| `Servo.move(alias, angle, duration_ms[, easing])` | bool | — | `angle` saturate int16; `duration_ms` saturate uint16; `easing` ∈ `linear`(default)/`in_out`/`bounce` |
| `Servo.stop([alias])` | bool | — | không arg → stop cả 4 khớp |
| `Servo.is_busy(alias)` | bool | — | dự đoán cục bộ (`expected_end_us`), có thể sai do IPC latency |
| `Servo.list()` | table | — | `{servos = {alias→hw_name}, poses = {alias→gesture}}` |
| `Servo.stats()` | table | — | bộ đếm push/coalesce/drop/sent + back_reject_* |

### `Led` — đèn RGB (qua IPC sang back)

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Led.set(r, g, b)` | bool | — | mỗi kênh clamp 0..255 |
| `Led.off()` | bool | — | |
| `Led.preset(name)` | bool | → `false` nếu name lạ | Whitelist: `user_talk`, `conv_processing`, `robot_talking`, `warm_white`, `light_blue`, `dark_blue` |
| `Led.blink(r, g, b, period_ms)` | bool | → `false` nếu `period_ms` ∉ [333, 5000] | **REJECT** (không clamp) — chặn nhấp nháy <3Hz (WCAG 2.3.1) |
| `Led.pulse(r, g, b, duration_ms)` | bool | → `false` nếu `duration_ms` ∉ [100, 5000] | one-shot rồi auto-off |
| `Led.set_brightness(pct)` | bool | — | clamp 0..100 |
| `Led.get_brightness()` | integer | — | mirror lần push thành công gần nhất (default 100), **không** query live |
| `Led.is_available()` | bool | — | gate trước khi tin `get_brightness` |
| `Led.stats()` | table | — | bộ đếm push/coalesce/drop/sent + brightness_pct |

### `Voice` — nhận lệnh giọng nói / keyword-spotting (qua IPC)

Mô hình: game khai **danh sách keyword tiếng Anh**, backend keyword-spotting match và trả `VOICE_COMMAND{keyword}` — **không phải** hội thoại/STT tự do. Gọi `set_keywords` trước, rồi `start` để bắt đầu nghe.

| Hàm | Trả về | Lỗi | Ghi chú |
|---|---|---|---|
| `Voice.set_keywords(list[, sensitivity])` | true \| (nil, reason) | sai kiểu arg → raise | `list` = mảng thuần string (1..64 keyword); `sensitivity` int 1..10 (backend default 5). Gọi lại được để hot-swap vocabulary |
| `Voice.start()` | true \| (nil, "send_failed") | — | bắt đầu stream audio |
| `Voice.stop()` | bool | — | idempotent |
| `Voice.is_available()` | bool | — | |
| `Voice.mode()` | string | — | `"a2a"` khi game chạy trong talk flow, ngược lại `"offline"` |

`Voice.set_keywords` **fail-loud** (không cắt cụt). Giới hạn encoder: độ sâu ≤ **4**, số key object ≤ **32**, JSON ≤ **2048 byte** (tính cả NUL). `reason` có thể là: `"keywords_not_array"` (table không phải mảng thuần), `"too_many_keywords"` (>64), `"too_deep"`, `"too_many_keys"`, `"encode_failed"` (gặp function/userdata/thread), `"payload_too_big"`, `"send_failed"`.

Nhận event qua hook `on_voice_event(event)`: engine forward **nguyên frame JSON** của backend → **Lua table** (1-indexed cho array, key string cho object); nếu vượt giới hạn decoder (độ sâu ≤ **8**, tổng node ≤ **256**) thì truyền **raw JSON string** thay vì table. Frame giữ nguyên shape của server (lồng `data`), rẽ nhánh theo `event.type`:

- `event.type == "VOICE_COMMAND"` → `event.data.keyword` là lệnh đã match; `event.data.status == "unavailable"` = keyword-spotting hỏng, ẩn UI voice nhưng **game vẫn chạy** (backend không đóng session).
- `event.type == "error"` → `event.code` / `event.message` (mở/stream lỗi async).

```lua
function game_start()
  Voice.set_keywords({ "jump", "fire", "stop" })
  Voice.start()
end

function on_voice_event(e)
  if type(e) ~= "table" then return end        -- raw JSON string (vượt decoder cap)
  if e.type == "error" then
    -- e.code / e.message: voice không dùng được, ẩn UI, game tiếp tục
  elseif e.type == "VOICE_COMMAND" then
    local data = e.data
    if type(data) == "table" and data.keyword then
      -- xử lý lệnh: data.keyword
    elseif type(data) == "table" and data.status == "unavailable" then
      -- ẩn UI voice, game vẫn chơi bằng nút
    end
  end
end
```

### `print`

`print(...)` được override → đẩy vào ESP_LOG (tag `[lua]`), nối các arg bằng tab. Không có stdout.

---

## Bảng tra giá trị nhanh

| Hạng mục | Giá trị |
|---|---|
| FPS / dt_ms mặc định | 30 / ~33ms |
| Max sprite | 32 |
| Ảnh tối đa | 480 × 320 px |
| PNG / Anim file | ≤ 1MB / ≤ 4MB |
| Font | ≤ 512KB, size 8–96px, ≤4 face cache |
| Lua heap | 512KB (PSRAM) |
| Watchdog | 1.5s / hook |
| State.save | ≤ 4096 byte |
| Input action | ≤16, tên ≤24 ký tự |
| Audio alias | ≤64, path ≤64 ký tự, cooldown 80ms |
| Servo alias / pose | ≤8 / ≤16 |
| Voice.set_keywords | ≤64 keyword; encode sâu ≤4, ≤32 key, ≤2048B |
| Led blink / pulse | [333,5000]ms / [100,5000]ms |
| Sandbox path | ≤200 byte |

---

_Khớp code tại nhánh `feat/game_engine`. Chính sách version & quy tắc bump: xem [README](README.md). Hướng dẫn viết game: [Guide](guide.md)._
