# Hard Constraints

> Giới hạn **cứng** của engine. Vi phạm không phải "chậm" — là **crash, fail-close, hoặc bị từ chối**. Sinh code phải nằm trong các trần này.

## Ngân sách tài nguyên

| Hạng mục | Giá trị | Vi phạm |
|---|---|---|
| FPS / dt_ms | 30 / ~33ms | — |
| **Watchdog mỗi hook** | **1.5s** | Vượt → hook bị giết, game có thể reset. Không block. |
| Text pool | **≤ 8 handle** cùng lúc | `Text.new` thứ 9 → `(nil,"pool_full")` |
| Sprite | ≤ 32 (ngân sách thiết kế; thực tế giới hạn bởi PSRAM heap) | hết heap → `(nil,"oom")` |
| Anim | **1 hoạt động cùng lúc** | anim mới **dừng** anim cũ |
| Ảnh | ≤ 480 × 320 px | |
| PNG / Anim file | ≤ 1MB / ≤ 4MB | |
| Font | ≤ 512KB, size 8–96px, ≤ 4 face cache | |
| Lua heap | 512KB (PSRAM), cố định | OOM → hook fail |
| `State.save` | ≤ 4096 byte | > 4KB → `false` |
| Input action | ≤ 16, tên ≤ 24 ký tự | |
| Audio alias | ≤ 64, path ≤ 64 ký tự, cooldown 80ms | play trong cooldown → `false` |
| Servo alias / pose | ≤ 8 / ≤ 16 | |
| Voice keyword | ≤ 64; JSON encode sâu ≤ 4, ≤ 32 key, ≤ 2048B | fail-loud `(nil,reason)` |
| Led blink / pulse | [333,5000]ms / [100,5000]ms | ngoài khoảng → **REJECT** (không clamp) |
| Sandbox path | ≤ 200 byte | path xấu → raise |

## Sandbox (điều KHÔNG có trong VM)

- **Không `io`, `os`.** Không đọc/ghi file trực tiếp, không giờ hệ thống (dùng `Timer.millis`), không `os.execute`.
- **Không mạng.** Không socket, HTTP, MQTT từ Lua.
- **`require` bị khoá vào game.** Chỉ `require("libs/x")` — nạp `<game>/libs/x.lua`. Không nạp module hệ thống/bên ngoài.
- **Truy cập file = qua API engine**, đường dẫn nối vào `GAMES_ROOT/<game_id>`, **relative-only**, không `..`. Áp cho cả `Sprite.image`, `Speaker.play` (alias), `Text:set_font`.
- **Lưu trạng thái = `State.*`** (ghi `save.sav` per-game, ≤ 4KB). Không có cách ghi file khác.

## Mô hình frame (không có game loop của bạn)

- **Cấm `while true` / busy-wait / sleep.** Engine giữ vòng lặp; code bạn chạy trong hook rồi **phải return**.
- Việc trải theo thời gian → đếm bằng `Timer.millis()` trong `on_tick`, không chờ đồng bộ.
- Không thao tác **NVS/SPIFFS/FATFS trong vòng nóng** (`on_tick`). `State.save` chạm SD → chỉ ở checkpoint.

## Đồ hoạ

- **Retained, không immediate.** Tạo `Sprite`/`Text`/`Anim` một lần, giữ handle, đổi trạng thái. Engine render mỗi frame. Không "vẽ lại mỗi frame".
- **Không xoay/scale sprite.** Chỉ `set_flip(fh, fv)`. Cần hiệu ứng xoay → dùng nhiều frame/anim.
- **Màu = RGB565** cho `Sprite.solid` (vd `0x07E0` = xanh lá); **0xRRGGBB** cho `Text:set_color`.
- **Va chạm = AABB.** `spr:intersects(spr2)` / `spr:hit_test(x,y)`. Không có physics engine.

## Âm thanh & ngoại vi async

- `Speaker`, `Servo`, `Led`, `Voice` phần lớn **async / fire-and-forget** (Servo/Led/Voice qua IPC sang MCU back). Giá trị trả về là *dự đoán cục bộ*, không phải ACK phần cứng.
- **Chỉ `Speaker` có completion thật** (`on_sound_end`). Đừng giả định servo/anim "xong" theo thời gian — poll `is_busy` hoặc thiết kế không phụ thuộc timing chính xác.

## SD & CRC (chạy trên board thật)

- Mỗi thư mục game có `s.json` = CRC theo **nội dung** của `.lua/.json/.png/.rgb565` + media. Sửa **bất kỳ** file trong đó → CRC lệch → board **fail-close** (từ chối chạy).
- Sau khi sinh/sửa code, **nhắc người dùng regen**: `python tools/crc32/sjson_genorator.py --sd <đường-dẫn-game>`. AI **không** tự tạo `s.json`.
- Simulator (Pika Studio) không bắt CRC → test được ngay; board thật thì bắt buộc regen.

_Số liệu khớp binding + Kconfig engine tại SDK 1.0.0. Bảng tra nhanh gốc: [../docs/api.md](../docs/api.md#bảng-tra-giá-trị-nhanh)._
