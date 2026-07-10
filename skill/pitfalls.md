# Pitfalls — lỗi thật → cách sửa

> Mỗi mục là một fail-mode **đã gặp thật**. Đọc trước khi debug; nhiều lỗi im lặng (game không chạy, không log rõ).

## 1. `unsafe path` khi tạo sprite trong `game_start`

**Triệu chứng:** `Sprite.image("images/x.png")` hoặc `Sprite.new(...)` với path game-relative raise `unsafe path` — nhưng **chỉ** trong `game_start`.

**Nguyên nhân:** `current_game_id` chưa set kịp lúc `game_start` chạy → path join thất bại.

**Fix:** Tạo sprite/anim ở **frame `on_tick` đầu tiên**, không trong `game_start`:

```lua
local player
function on_tick()
  if not player then
    player = Sprite.image("images/player.png")
    if player then player:set_pos(100, 100) end
    return
  end
  -- logic bình thường
end
```

`Text.new` **không** dính lỗi này — tạo trong `game_start` OK. `Sprite.solid` (không path) cũng an toàn hơn nhưng vẫn nên tạo trễ để nhất quán.

## 2. Sprite nháy ở góc trái-trên (0,0) khi load

**Triệu chứng:** Sprite lóe 1 frame ở `(0,0)` rồi mới về đúng chỗ.

**Nguyên nhân:** Sprite hiện ngay khi tạo, trước khi bạn `set_pos`.

**Fix:** Engine đã tạo sprite **ẩn**, chỉ lộ ở lần `set_pos`/`set_visible` đầu. Nên **luôn `set_pos` ngay sau khi tạo**, cùng frame:

```lua
player = Sprite.solid(24, 24, 0x07E0)
if player then player:set_pos(x, y) end   -- set_pos ngay, đừng để tới frame sau
```

## 3. Gọi API không tồn tại (im lặng hoặc raise)

**Triệu chứng:** `attempt to call a nil value (field 'now_ms')`, hoặc game chết trong hook.

**Nguyên nhân:** Bịa API từ engine khác. Hay gặp: `Engine.now_ms`, `os.time`, `spr:rotate`, `require("json")`, `Voice.listen`.

**Fix:** Đối chiếu [api-contract.md](api-contract.md), mục "API KHÔNG tồn tại". Thời gian = `Timer.millis()`. Va chạm = `spr:intersects`. Lưu = `State.*`.

## 4. Vượt Text pool → nil

**Triệu chứng:** `Text.new` trả `nil` (kèm `"pool_full"`), rồi `t:set(...)` raise vì `t` là nil.

**Nguyên nhân:** > 8 Text handle sống cùng lúc.

**Fix:** Tái dùng handle (giữ label, đổi bằng `:set`), `:destroy()` label không cần nữa. **Luôn check nil** sau `Text.new`:

```lua
local hud = Text.new("", 4, 4)
if not hud then return end   -- pool_full
```

## 5. Hook block > 1.5s → watchdog giết game

**Triệu chứng:** Game đứng hình, có thể reset; log watchdog.

**Nguyên nhân:** `while` chờ điều kiện, tính toán nặng mỗi frame, hoặc `State.save` trong `on_tick`.

**Fix:** Không vòng chờ. Trải việc qua nhiều `on_tick` đo bằng `Timer.millis()`. `State.save` chỉ ở checkpoint (game over, qua màn), không mỗi frame.

## 6. Âm thanh "File not found" dù file có thật

**Triệu chứng:** `Speaker.play` false, log không tìm thấy file.

**Nguyên nhân:** Không truyền **đường dẫn file** cho Speaker — phải dùng **alias** khai trong `manifest.audio.sounds`. (Lỗi double-prefix `/sd/sd` từng xảy ra ở firmware, nay đã fix.)

**Fix:** Khai alias trong manifest, gọi `Speaker.play("<alias>")`, không `Speaker.play("audio/hit.wav")`.

## 7. Va chạm không nhận

**Triệu chứng:** Nhân vật chạm nhau nhưng `intersects` false.

**Nguyên nhân:** Chỉ có **AABB** (hộp chữ nhật thẳng trục), không phải pixel-perfect. Sprite trong suốt vẫn tính cả khung. Hoặc quên rằng sprite ẩn (chưa set_pos) có vị trí không xác định.

**Fix:** Chấp nhận AABB; canh kích thước sprite sát nhân vật. Đảm bảo cả 2 sprite đã `set_pos`.

## 8. Voice không phản hồi

**Triệu chứng:** Nói keyword nhưng `on_voice_event` không kích hoạt.

**Nguyên nhân thường gặp:**
- Chưa gọi `Voice.start()` sau `Voice.set_keywords`.
- `set_keywords` trả `(nil, reason)` (vd `too_many_keywords`, `payload_too_big`) mà không check.
- Keyword không phải tiếng Anh (backend keyword-spotting tiếng Anh).
- Vào nhánh sai trong `on_voice_event`: phải check `e.type == "VOICE_COMMAND"` rồi `e.data.keyword`.

**Fix:** Xem mẫu đầy đủ [recipes/voice-keyword-trigger.md](recipes/voice-keyword-trigger.md). Luôn check giá trị trả về của `set_keywords`.

## 9. Game chạy simulator nhưng board thật từ chối

**Triệu chứng:** OK trong Pika Studio, board thật fail-close không chạy.

**Nguyên nhân:** `s.json` (CRC nội dung) lệch vì bạn sửa `.lua/.png/.json` mà chưa regen.

**Fix:** Sau khi sửa bất kỳ file game, regen: `python tools/crc32/sjson_genorator.py --sd <đường-dẫn-game>`. Simulator không bắt CRC nên không lộ lỗi này.

## 10. `require` module ngoài fail

**Triệu chứng:** `require("json")` / `require("mylib")` → module not found.

**Nguyên nhân:** Sandbox chỉ nạp `require("libs/x")` = `<game>/libs/x.lua`.

**Fix:** Copy lib cần dùng vào `<game>/libs/` (từ SDK `libraries/`, hoặc extension nút "Add to a game…" tự kéo cả dependency). JSON: dùng `State.*` để lưu, không cần thư viện JSON.

---

_Nếu gặp fail-mode chưa có ở đây và tái hiện được, đó là ứng viên thêm vào file này._
