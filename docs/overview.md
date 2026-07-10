# Pika Game Engine — Tổng quan cho đội phát triển game

> **Đối tượng:** Đội phát triển game pack (chưa cần biết nội bộ firmware).
> **Phạm vi:** Ngoại vi điều khiển được, luồng khởi động/kết thúc game, ràng buộc tài nguyên — không đi sâu mã nguồn core.
> **Tài liệu kèm:** [Guide](guide.md) · [Module Firmware](module.md).

Pika Game Engine là runtime **Lua 5.5** chạy game loop ~30 FPS trên robot PIKA. Game đóng gói thành **game pack** (script Lua + asset) trên **thẻ SD**; game gọi API engine để vẽ màn hình và điều khiển ngoại vi — **không chạm phần cứng trực tiếp**. Robot có 2 MCU: `head` (màn hình, loa, chạy engine) và `back` (servo, LED, micro, nút bấm, mạng); ngoại vi `back` đi qua kênh nội bộ **IPC** — trong suốt với game.

---

## 1. Cấu trúc ngoại vi (game điều khiển được gì)

```
  ┌────────────────────────────┐
  │ Thẻ SD — Game pack (Lua)   │ ── nạp lúc start ──┐
  └────────────────────────────┘                    ▼
┌─────────────  HEAD  ─────────────┐
│ ┌────────────────────────────┐ │
│ │ Game Engine — Lua, ~30 FPS │ │
│ └────────────────────────────┘ │
│ ┌────────────────────────────┐ │   OUT = game ra lệnh tới ngoại vi
│ │ Màn hình 480×320  (OUT)    │ │   IN  = sự kiện ngoại vi vào game
│ │ Sprite · Anim · Text       │ │
│ └────────────────────────────┘ │   Chỉ Speaker báo khi phát xong
│ ┌────────────────────────────┐ │   (on_sound_end); servo/LED/anim
│ │ Loa · Speaker  (OUT)       │ │   là async (gửi rồi quên).
│ └────────────────────────────┘ │
└────────────────┬───────────────┘
                 │ IPC nội bộ (trong suốt với game)
                 ▼
┌─────────────  BACK  ─────────────┐
│ ┌──────────────┐ ┌─────────────┐ │
│ │ Servo 4 khớp │ │ LED RGB     │ │  (OUT)
│ │   (OUT)      │ │   (OUT)     │ │
│ └──────────────┘ └─────────────┘ │
│ ┌──────────────┐ ┌─────────────┐ │
│ │ Nút bấm (IN) │ │ Micro·Voice │ │  Voice cần mạng → Server
│ │ ENTER/L/R    │ │  (IN/OUT)   │ │
│ └──────────────┘ └─────────────┘ │
└──────────────────────────────────┘
```

| Ngoại vi | API Lua | MCU | Cần nhớ |
|---|---|---|---|
| Màn hình 480×320 | `Sprite` (PNG), `Anim` (GIF/MJPEG), `Text` (chữ) | head | RGB565 · **1 `Anim`** cùng lúc · nhiều **sprite**/**Text** (có trần) |
| Loa | `Speaker` | head | Ngoại vi **duy nhất có completion** (`on_sound_end`) · có cooldown ngắn giữa 2 lần phát |
| Servo | `Servo` | back | **4 khớp** (head/base/trái/phải), easing linear/in_out/bounce · **async**, `is_busy()` chỉ ước lượng |
| Đèn RGB | `Led` | back | **Fire-and-forget**, không phản hồi |
| Micro/giọng | `Voice` | back+mạng | Phiên nhận giọng tới server · **cần mạng** (offline không có) |
| Nút bấm | `Input` | back | **3 nút** ENTER/LEFT/RIGHT × PRESS/RELEASE/REPEAT · có thể **mất event** khi dồn (`on_input_lost`) |
| Lưu trữ | `State` | head (SD) | Blob per-game (có trần dung lượng) |
| Tiện ích | `Timer` · `print` | head | Phụ trợ |

> **Bất biến:** servo/led/anim không đồng bộ — không giả định chúng đã hoàn tất ngay khi gọi API; chỉ `Speaker` báo lại. Thiết kế gameplay quanh nguyên tắc này ([Guide §4](guide.md#4-vòng-đời--hook)).

---

## 2. Hai luồng tương tác

Cả hai dùng **cùng API game**; khác nhau chỉ ở phía host/server, không ở cách viết game pack.

**2.1. Offline (độc lập)** — người dùng chọn game từ menu, chạy cục bộ, **không cần mạng**.

```
Menu ─► game_start ─► [ mỗi frame: on_input → on_tick ] ─► game_end ─► Menu
                              │
                     HOME ─► on_home()  →  true: ở lại loop · false: game_end
```
Điều khiển bằng 3 nút; lưu điểm bằng `State`; dùng mọi ngoại vi **trừ `Voice`**.

**2.2. Tích hợp hội thoại A2A (server điều khiển)** — server chèn game giữa cuộc trò chuyện rồi nói tiếp.

```
A2A đang chạy
   │  Server ─► PLAY_GAME{game_id}
   ▼
vào game (mic TẮT, WS giữ sống) ─► chơi như Offline (+ Voice.start tuỳ chọn) ─► game_end
   │  Robot ─► GAME_RESULT{ended, score}
   ▼
A2A tiếp tục
```
- **Server** quyết định vào game (`game_id` = tên folder pack trên SD) và nhận kết quả (`ended` = completed/user_home/error).
- Kết nối **giữ sống** suốt lúc chơi → game nên có thời lượng hợp lý.
- Ở luồng này **dùng được `Voice`** (đang online), ví dụ game luyện phát âm.
- Luồng học **Learn** có cơ chế tương tự ([Flow/Learn_Game.md](Flow/Learn_Game.md)).

> ⚠️ Hợp đồng message A2A (`PLAY_GAME`/`GAME_RESULT`, timeout, reward) **đang chốt với backend** — [Flow/A2A_Game.md](Flow/A2A_Game.md).

---

## 3. Ràng buộc bộ nhớ & tài nguyên

Mọi giới hạn là **trần cứng** do firmware đặt — vượt là bị từ chối hoặc kết thúc game, không phải gợi ý.

| Hạng mục | Giới hạn | Vượt thì |
|---|---|---|
| Bộ nhớ Lua | có trần, dùng vùng PSRAM riêng cho game | lỗi cấp phát → kết thúc game |
| Thời gian mỗi hook | bị watchdog giới hạn thời gian chạy | watchdog cắt → kết thúc game |
| Nhịp frame | game loop chạy nhịp cố định | `on_tick` nặng → khựng hình |
| Sprite | số lượng đồng thời có hạn | tạo thêm trả `nil` (tự kiểm tra) |
| Ảnh PNG | giới hạn kích thước (≤ panel) & dung lượng | tải ảnh thất bại |
| Anim GIF/MJPEG | **chỉ 1 ảnh cùng lúc**, có trần dung lượng | anim mới dừng anim cũ |
| Font TTF | giới hạn dung lượng & số face đồng thời | dùng subset theo ngôn ngữ |
| `State.save` | có trần kích thước blob | trả `false` |
| Âm thanh | có cooldown giữa 2 lần `Speaker.play` | bị bỏ (trả `false`) |
| File | chỉ thư mục game; không đọc/ghi ngoài, không ghi cấu hình hệ thống | đường dẫn ngoài bị chặn |
| Mạng / Lua | không tự mở kết nối; sandbox không `io`/`os`/`require` tuỳ ý (chỉ `libs/...`) | API cấm → lỗi nạp |

> Con số cụ thể (KB heap, ms watchdog, FPS, px, số sprite/face…): xem [Module §11 — Kconfig & resource budget](module.md#11-kconfig--resource-budget) và [Guide §6](guide.md#6-sandbox--giới-hạn).

**Nguyên tắc:** tải asset lớn ở `game_start` (không trong `on_tick`) · tái dùng sprite thay vì tạo/hủy mỗi frame · coi servo/led/anim là *đặt lệnh rồi quên* · sửa file SD phải tạo lại `s.json` của folder (CRC), nếu không engine từ chối nạp.

---

## 4. Đọc thêm

| Mục tiêu | Tài liệu |
|---|---|
| Viết game (manifest, hook, ví dụ) | [Guide · Quickstart](guide.md#1-quickstart--game-pack-đầu-tiên) |
| Toàn bộ API Lua | [API Reference](api.md#tham-chiếu-api-lua) |
| Sandbox & giới hạn chi tiết | [Guide · §6](guide.md#6-sandbox--giới-hạn) |
| Luồng A2A / Learn × game | [A2A_Game](Flow/A2A_Game.md) · [Learn_Game](Flow/Learn_Game.md) |
| Bên trong engine (firmware) | [Module Firmware](module.md) |
