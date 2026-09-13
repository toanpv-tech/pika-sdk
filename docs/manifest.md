# `manifest.json` — Schema v2

> **IMPLEMENTED.** `name`/`main`/`peripherals` được parser đọc thật (`game_pack.c`), cả 13 pack trên `SD/games/` đã cập nhật. Tên field v1 (`display_name`/`entry_script`) không còn fallback nào — parser + màn menu (`ui_menu.cpp`) chỉ đọc `name`/`main` (xem §7). `peripherals` hiện chỉ dùng giá trị `"voice"` để lái lifecycle của WS voice phía BACK (`game_voice.cpp`): pack khai báo `"voice"` thì BACK vừa dựng WS session vừa coi voice là bắt buộc — mất transport thì kết thúc game (không có field policy riêng). Các giá trị `peripherals` khác (`servo`/`led`/`audio`/`button`/`display`) được ghi trong manifest cho đủ nhưng KHÔNG có consumer nào đọc chúng, chỉ là chuẩn bị chỗ cho sau này (least-privilege gate binding — xem §8 câu hỏi mở). Chi tiết đầy đủ + hành vi hiện hành xem [guide.md §3](guide.md#3-manifestjson--schema-đầy-đủ).
> Mục tiêu: đủ thông tin cho một game pack, dùng tên field theo quy ước phổ biến (`package.json`, Chrome MV3, Cargo.toml, PWA), unknown-key-safe để các lần đổi sau không phá pack cũ.

---

## 1. Nguyên tắc thiết kế

1. **Vay mượn tên đã phổ biến**, không tự đặt từ mới.
2. **Field lạ → bỏ qua + log**, không reject cả pack.
3. **Phẳng khi có thể, lồng khi có nhóm ngữ nghĩa thật** (`input`/`audio`/`servos`).

---

## 2. Schema đầy đủ (ví dụ chạm mọi ngoại vi)

```json
{
  "name": "Pika Adventure",
  "version": "1.0.0",
  "author": "Pika Studio",

  "main": "scripts/main.lua",

  "peripherals": ["voice", "servo", "led", "audio", "button", "display"],

  "input": {
    "actions": {
      "confirm": ["button:enter"],
      "left":    ["button:left"],
      "right":   ["button:right"],
      "move":    ["button:left", "button:right"]
    }
  },

  "audio": {
    "sounds": {
      "shoot": { "path": "audio/shoot.wav", "loop": false },
      "coin":  { "path": "audio/coin.wav",  "loop": false },
      "bgm":   { "path": "audio/loop.wav",  "loop": true  }
    }
  },

  "servos": {
    "neck":  "head",
    "torso": "base",
    "left":  "left",
    "right": "right"
  },
  "poses": {
    "hello": "say_hi",
    "win":   "cheer_jump",
    "sad":   "system_error",
    "wave":  "left_wave"
  }
}
```

- **`peripherals`** — liệt kê mọi global Lua ngoại vi pack chạm tới, đối chiếu 1:1 `lua_vm.c:265-276`: `voice`→`Voice`, `servo`→`Servo`, `led`→`Led`, `audio`→`Speaker`, `button`→`Input`, `display`→`Sprite`/`Text`/`Anim` (gộp chung, cùng thao tác LCD). Không liệt kê `State`/`Timer`/`Engine` — API software thuần. Field top-level `input`/`input.actions` (v1) không đổi tên, chỉ *giá trị* permission gọi là `button`.
- **`input.actions`** — nguồn hợp lệ chỉ 3: `button:enter`/`left`/`right`; 1 action nhận nhiều nguồn (`"move"`). Bỏ hẳn block `input` → engine tự seed default `confirm→enter, left→left, right→right`.
- **`audio.sounds`** — `path` bị `stat()` ngay lúc nạp; sai đường dẫn reject cả pack.
- **`servos`** — target chỉ 4 giá trị cố định: `head`, `base`/`body` (đồng nghĩa), `left`, `right`.
- **`poses`** — tên gesture phải khớp danh sách wire-stable cố định (16 tên, `guide.md` §3.4).

---

## 3. Field so với thế hệ manifest trước

| Trước | Hiện tại | Vay mượn từ | Lý do ngắn gọn |
| --- | --- | --- | --- |
| `display_name` | `name` | package.json, Cargo, PWA | Quy ước phổ biến nhất; id thật vẫn là tên thư mục (`game_pack.c:187-198`), nên `name` chỉ còn là nhãn hiển thị. |
| `entry_script` | `main` | package.json | Ngắn, phổ biến hơn. |
| `requires_voice` (bool, kill-on-loss riêng) | `peripherals` (mảng, chỉ khai báo sự thật) | Chrome MV3, AndroidManifest | Xem §4 — field kill-on-loss riêng đã bị loại bỏ: khai báo `"voice"` là đủ, mất voice luôn kết thúc game. |
| *(dead field)* | `version` (kích hoạt thật) | semver | Xem §5. |
| *(vắng)* | `author` | package.json, PWA | Metadata rẻ. Không thêm `description` — màn chọn game (`ui_menu.cpp:1054-1064`) không có chỗ hiển thị, thêm field không consumer là đầu cơ. |
| `input`/`audio`/`servos`/`poses` | giữ nguyên | — | Đã đúng chuẩn từ trước. |

`display_name`/`entry_script` không còn được parser đọc dưới bất kỳ hình thức nào (đã xoá fallback) — một manifest chỉ dùng tên cũ sẽ có `name`/`main` rỗng.

---

## 4. `peripherals` — thay cho `requires_voice`

**Vấn đề cũ:** `requires_voice` gộp "pack có dùng voice" với "mất voice thì kill game hay không" làm một field, mà không đáng tin ngay cả cho câu hỏi đơn giản "pack có dùng `Voice.*` không".

**v2:** manifest chỉ khai báo sự thật (`peripherals: ["voice","servo"]`). Không còn field policy riêng: khai báo `"voice"` vừa là điều kiện để BACK dựng WS/task/mic (lazy-init) vừa là cam kết "voice phải hoạt động" — mất transport thì BACK kết thúc game, không có mức "voice tuỳ chọn, mất thì báo lỗi Lua rồi chơi tiếp".

- Vắng `peripherals` hoàn toàn → `has_voice=false`, không activate WS voice (an toàn, không tối ưu).
- **Đã implement (lifecycle voice WS):** `game_pack.c` parse `peripherals`, đặt `game_engine_has_voice()`; head gửi field `has_voice` trong `GameStartedMsg_st` (append sau `game_id`, length-check/default-0); BACK (`application.cpp` handler `IPC_CMD_GAME_STARTED`) chỉ gọi `game_voice_activate()` khi `has_voice != 0`, và `game_voice_deactivate()` tại điểm hội tụ đóng game hiện có (`GESTURE_SetGameSessionActive(false)`). Task 8KB + `WebSocketProtocol` + `esp_timer` giờ chỉ tồn tại trong lúc game có voice đang chạy, không còn sống suốt đời robot từ boot. Một khi đã activate, lỗi hạ tầng voice (WS connect/drop, thiếu session key) luôn kết thúc session (`GAME_STOP_REASON_VOICE_WS_FAILED`, xem `game_voice.cpp` `end_game_for_voice_loss`).
- Least-privilege binding-gate (chỉ đăng ký `Voice.*`/`Servo.*`/... vào VM khi có trong `peripherals`) **chưa implement** — hiện `peripherals` mới lái đúng nhánh `voice`, các giá trị khác chưa có consumer.
- Không phải ngoại vi nào cũng lazy-init được: `servo`/`led` dùng chung tài nguyên boot-time (`GESTURE_Init()`, LED chỉ snapshot/restore), không có gì để lazy-init. Chỉ `voice` tốn RAM thường trực (task 8KB + WS + buffer) đáng dựng theo lifecycle game.

---

## 5. `version` — kích hoạt thật

Field `version` đã xuất hiện trong manifest thật (vd. `word_racer_02`) nhưng firmware hiện không parse (dead field). v2 dùng để: log lúc `pack_load` (chẩn đoán), và so sánh khi đồng bộ/OTA (phát hiện bản cũ ghi đè nhầm bản mới). Không dùng để gate tính năng.

---

## 6. Tầm quan trọng từng field

| Field | Bắt buộc? | Rủi ro nếu thiếu/sai |
| --- | --- | --- |
| `main` | Bắt buộc | Vắng → fallback `scripts/main.lua` (im lặng) |
| `peripherals` | Bắt buộc (v2) | Vắng → `has_voice=false`, không lifecycle-activate voice (an toàn, không tối ưu) |
| `input.actions` | Nếu game cần input | Thiếu action → nút vô tri |
| `name` | Nên có | Vắng → tên rỗng trên UI |
| `audio.sounds.*.path` | Nếu phát âm | Sai path → reject cả pack (strict, v1) |
| `version` | Nên có | Vắng → khó chẩn đoán đồng bộ/OTA |
| `servos`/`poses` | Tuỳ chọn | Vượt giới hạn (8/16) → reject cả pack |
| `author` | Tuỳ chọn | Không ảnh hưởng |

---

## 7. Migration v1 → v2 (đã hoàn tất, fallback đã gỡ)

Parser không còn đọc `display_name`/`entry_script` dưới bất kỳ hình thức nào — chỉ `name`/`main`. Cùng thay đổi ở `ui_menu.cpp:1372` (`game_load_name`, hiển thị tên trong menu): trước đó đọc riêng `display_name`, giờ đọc `name` để đồng bộ với parser chính.

- Vắng `peripherals` → `has_voice=false` **luôn**. Một pack thật sự dùng voice phải tự thêm `peripherals: ["voice"]` để được lifecycle-activate; nếu không, `Voice.*` sẽ báo `"busy"` cho Lua (task/WS chưa được dựng).
- Một manifest chỉ còn `display_name`/`entry_script` (không có `name`/`main`) sẽ có tên rỗng (menu hiển thị tên thư mục thay thế, xem `game_load_name`) và `entry_script` không được nạp → `game_pack_load` fail (`GAME_ENGINE_ERR_PACK_MANIFEST` nếu rỗng dẫn tới lỗi nạp Lua sau đó).

Cả 13 pack thật trên `SD/games/` đã cập nhật thẳng field mới (`name`/`main`/`peripherals`) — mỗi pack tự khai đúng `peripherals` của mình sau khi rà soát script Lua thật. `zip_10mb`/`zip_5mb` (thư mục gốc SD) là fixture test cho tính năng auto-unzip, cố tình **không** cập nhật và **không** còn nạp được (vẫn dùng tên field v1 thuần) — chấp nhận được vì chúng chỉ tồn tại để test hành vi giải nén, không phải game pack đang khai thác.

---

## 8. Câu hỏi còn mở

1. **`voice.keywords` trên manifest** có tạo hai nguồn sự thật với `Voice.set_keywords` runtime không — cần định nghĩa manifest là *danh sách khả dĩ* (validate/gate) vs runtime là *tập đang active*.
2. **Cơ chế lazy-init + chính sách lỗi BACK-side cụ thể** (per-peripheral hay chung) — chưa thiết kế, bàn khi implement.

---

## 9. Corner case đã biết, chưa xử lý

Ghi nhận, chưa thiết kế giải pháp:

1. **Đồng bộ pack dở dang (CDN/OTA)** — không có cách biết pack "đồng bộ dở, đừng load"; `version` chỉ chẩn đoán cũ/mới, không xác nhận toàn vẹn.
2. **`peripherals` trộn "khai báo dùng" với "phần cứng có tồn tại"** — giả định binding tồn tại = phần cứng tồn tại (đúng với 1 SKU hiện tại). SKU thiếu servo/mic trong tương lai cần tách "declared" khỏi "available".
3. **Lỗi không cùng một pha** — load-time, first-tick, hay giữa game; bảng §6 hiện chỉ có 1 trục rủi ro, chưa có trục "pha lỗi xảy ra".
4. **Unknown *value* trong mảng khác unknown *key*** — nguyên tắc §1.3 cho unknown key (field trang trí, vô hại). Binding mới (`Camera`,...) mà pack khai báo `peripherals` chạy trên firmware cũ chưa có binding đó thì không vô hại như bỏ qua field — sẽ lỗi thật khi gọi API không tồn tại.
5. **Reject-cả-pack khi vượt giới hạn `servos`/`poses`** không phải luôn đúng — nếu một gesture phải deprecate, pack cũ tham chiếu gesture đó bị reject toàn bộ, chưa có đường graceful-degrade.
