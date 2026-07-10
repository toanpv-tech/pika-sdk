# Workflow — Từ ý tưởng đến game chạy được

> **Đối tượng: BẠN** (người có ý tưởng, dùng AI để vibe-code) — không phải AI.
> Các file khác trong `skill/` viết cho AI đọc; file này viết cho bạn.
> Mục tiêu: làm game **nhanh** và **đúng ý** nhất.

Đúng = brief đủ (Bước 1) + đưa `skill/` cho AI (Bước 2).
Nhanh = copy example thay vì làm từ zero (Bước 3) + Run hot-reload sửa bằng lời (Bước 4).

> **Đã có sẵn file PRD?** Bỏ qua Bước 1, dùng thẳng prompt copy-dán trong [start-prompt.md](start-prompt.md) (xử lý cả trường hợp làm trong project mới, chưa thấy `skill/`).

---

## Bước 0 — Chuẩn bị (1 lần duy nhất)

- Cài Pika Studio (extension VS Code, kèm simulator chạy trên PC — không cần robot).
- Trỏ setting `pika.sdk.source` tới SDK này (đường dẫn thư mục hoặc git URL).

Xong là quên luôn. Chi tiết: [../docs/getting-started.md](../docs/getting-started.md).

---

## Bước 1 — Viết mô tả game thành "brief"

Đây là bước quyết định **"đúng ý"**. Đừng nói mơ hồ ("làm game bắn"). Nêu đủ 5 mục:

| Cần nói | Ví dụ |
|---|---|
| **Mục tiêu người chơi** | né chướng ngại, sống lâu nhất |
| **Điều khiển** (chỉ 3 nút!) | LEFT/RIGHT lái, ENTER nhảy |
| **Thắng / thua** | chạm gai = thua; qua 30s = thắng |
| **Yếu tố Pika** (nếu có) | nói "jump" để nhảy; robot lắc đầu khi thua |
| **Hình ảnh** | khối màu là được / dùng sprite phi thuyền |

**Ràng buộc cứng phải biết trước khi mô tả** (nói trong khung này thì AI làm đúng):
- Chỉ **3 nút**: `enter`, `left`, `right`.
- Màn hình **480 × 320 px**.
- Tối đa **8 nhãn chữ** cùng lúc.
- **Không xoay/scale** sprite (chỉ lật ngang/dọc).
- Giọng nói = **keyword tiếng Anh** (không hội thoại tự do).

Đầy đủ giới hạn: [constraints.md](constraints.md).

---

## Bước 2 — Đưa "hợp đồng" cho AI (chống bịa API)

**Chìa khoá để nhanh + đúng.** Trước khi bảo AI viết code, yêu cầu nó đọc `skill/` — nơi có API thật, luật, và cạm bẫy. Nếu không, AI hay gọi hàm **không tồn tại** (`Engine.now_ms`, `os.time`, `spr:rotate`…) → game không chạy, tốn thời gian sửa.

Dùng mẫu prompt ở [cuối tài liệu](#mẫu-prompt-điền-vào-chỗ-trống).

---

## Bước 3 — Khởi tạo từ ví dụ gần nhất (đừng bắt đầu từ zero)

Trong Pika Studio → mục **Examples** → chọn cái gần ý tưởng nhất → **Use this example**. Tool copy thành game của bạn và mở sẵn `main.lua`.

| Ý tưởng | Ví dụ khởi đầu |
|---|---|
| Nút + chữ (điểm số, menu) | `test_button` |
| Có giọng nói | `test_voice` |
| Có âm thanh | `test_audio` |
| Chữ nhiều cỡ / font | `test_font` |
| Trống hoàn toàn | [templates/minimal-game/](templates/minimal-game/) |

---

## Bước 4 — Vòng lặp chính: AI viết → Run → sửa bằng lời

1. AI sửa `scripts/main.lua`.
2. Bấm **Run** → simulator 480×320 mở. Bàn phím thay 3 nút: `ENTER/SPACE`, `LEFT/A`, `RIGHT/D`.
3. **Lưu file = tự nạp lại** (hot-reload) — không build lại.
4. Sai gì → **mô tả cho AI cái bạn thấy** ("nhân vật nháy ở góc trái", "va chạm không ăn", "nói jump không phản hồi"). AI tra [pitfalls.md](pitfalls.md) và sửa.

Lặp tới khi ưng. Đây là chỗ "nhanh": mỗi vòng vài giây, không compile.

---

## Bước 5 — Thêm asset & thư viện (nếu cần)

- **Ảnh / âm thanh:** mục **Asset Library** trong tool (hàng trăm pack Kenney sẵn, CC0).
- **Menu Start / độ khó, tween, state machine, save:** mục **Libraries** → **Add to a game…** (tự kéo cả dependency). **Đừng để AI viết lại** — bảo nó *"dùng `libs/settings`"*, *"dùng `libs/animator`"*. Danh sách: [../libraries/libs.index.json](../libraries/libs.index.json).

---

## Bước 6 — Đóng gói ra robot

Chuột phải game → **Package / Export to SD…**. Tool validate (manifest, kích thước ảnh, tên file) và regen `s.json` (CRC nội dung), rồi chép thành folder chạy được trên robot.

> Chạy simulator thì không cần bước này. Chỉ khi lên **board thật** mới cần export/regen `s.json` — nếu không, board fail-close (từ chối chạy vì CRC lệch).

---

## Mẫu prompt (điền vào chỗ trống)

Dán nguyên khối này cho AI, thay phần `[...]`:

```
Đọc skill/SKILL.md và skill/api-contract.md trong pika-sdk trước.
Chỉ dùng API có trong api-contract.md — không bịa hàm.

Viết cho tôi một game Pika:

- Mục tiêu người chơi: [vd: né chướng ngại, sống lâu nhất]
- Điều khiển (chỉ 3 nút enter/left/right): [vd: LEFT/RIGHT lái, ENTER nhảy]
- Thắng / thua: [vd: chạm gai = thua; qua 30 giây = thắng]
- Yếu tố Pika (nếu có): [vd: nói "jump" để nhảy; robot lắc đầu khi thua — bỏ trống nếu không]
- Hình ảnh: [vd: khối màu là đủ / dùng sprite phi thuyền]

Ràng buộc: màn 480x320, tối đa 8 nhãn chữ, không xoay sprite.
Tạo sprite ở on_tick đầu (không trong game_start). Nếu dùng menu/tween,
dùng thư viện có sẵn trong libs/ thay vì tự viết.
Xong thì tóm tắt game làm gì và tôi cần bấm nút nào để test.
```

Sau khi có code: **Run** trong Pika Studio, thử, rồi mô tả cái sai cho AI để nó sửa (Bước 4).

---

_Cần tra cứu khi làm: API → [api-contract.md](api-contract.md) · giới hạn → [constraints.md](constraints.md) · lỗi → [pitfalls.md](pitfalls.md) · ví dụ theo tác vụ → [recipes/](recipes/)._
