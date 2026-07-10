# Prompt bắt đầu vibe-code (đã có PRD)

> Dùng khi bạn đã có **file PRD** và muốn AI bắt đầu làm game. Copy khối prompt phù hợp, thay phần `[...]`, dán cho AI.
>
> **Nếu bạn làm trong một project MỚI** (không phải repo pika-sdk): AI ở đó chưa thấy `skill/`. Phải chỉ cho nó **đường tới pika-sdk trước** (git URL hoặc thư mục local), nếu không nó không có API contract và sẽ bịa hàm.

---

## A. Prompt đầy đủ (khuyến nghị) — project mới, có PRD

Thay `[SDK]` bằng git URL **hoặc** đường dẫn local tới pika-sdk, và trỏ tới PRD của bạn:

```
Bạn sẽ giúp tôi vibe-code một game cho robot Pika (engine Lua, ESP32-S3).

BƯỚC 1 — Nạp hợp đồng (BẮT BUỘC, làm trước khi viết bất kỳ dòng code nào):
Đọc thư mục skill/ trong Pika SDK tại: [SDK]
  (git URL thì clone/đọc; đường dẫn local thì đọc trực tiếp)
Đọc theo thứ tự: skill/SKILL.md → skill/api-contract.md → skill/constraints.md.
Quy tắc bất di: CHỈ dùng API có trong api-contract.md. Không bịa hàm
(không Engine.now_ms, os.time, spr:rotate, require ngoài libs/…).

BƯỚC 2 — Đọc PRD của tôi:
[Đường dẫn PRD, vd: docs/PRD.md]   (hoặc dán nội dung PRD ở cuối prompt này)

BƯỚC 3 — TRƯỚC KHI CODE, hãy hỏi lại:
1. Tóm tắt trong 3–5 câu bạn hiểu game này làm gì.
2. Map cơ chế PRD về ràng buộc engine và nêu chỗ cần tôi chốt:
   - Điều khiển ép về ĐÚNG 3 nút (enter/left/right) — cái gì gắn nút nào?
   - Điều kiện thắng / thua cụ thể là gì?
   - Có yếu tố Pika không (giọng nói keyword tiếng Anh / servo / led)?
   - Màn 480x320, ≤ 8 nhãn chữ, không xoay sprite — PRD có gì vượt trần này?
3. Liệt kê phần PRD KHÔNG khả thi trên engine (nếu có) + đề xuất thay thế.
Chưa viết code cho tới khi tôi trả lời.

BƯỚC 4 — Sau khi tôi chốt:
- Khởi tạo từ skill/templates/minimal-game (hoặc example gần nhất trong SDK).
- Sprite/Anim tạo ở on_tick đầu, KHÔNG trong game_start.
- Dùng thư viện có sẵn trong libs/ (settings, animator…) thay vì tự viết.
- Xong: tóm tắt game làm gì + tôi bấm nút nào để test trên simulator.

--- PRD (dán vào đây nếu không trỏ được file) ---
[dán toàn bộ nội dung PRD, hoặc xoá mục này nếu đã trỏ đường dẫn ở BƯỚC 2]
```

---

## B. Prompt gọn — nếu AI đã đọc được skill/ rồi

Khi làm ngay trong repo có pika-sdk (hoặc phiên trước đã nạp skill/):

```
Đã đọc skill/ chưa? Nếu chưa, đọc skill/SKILL.md + skill/api-contract.md trước.
Chỉ dùng API trong api-contract.md.

Đọc PRD: [đường dẫn PRD]

Trước khi code: tóm tắt bạn hiểu gì, map điều khiển về 3 nút enter/left/right,
nêu điều kiện thắng/thua và mọi chỗ PRD vượt trần engine (480x320, ≤8 Text,
không xoay sprite). Chờ tôi chốt rồi mới viết.
```

---

## Sau khi có bản đầu

1. **Run** trong Pika Studio → simulator 480×320. Nút: `ENTER/SPACE`, `LEFT/A`, `RIGHT/D`.
2. Lưu file = hot-reload, không build lại.
3. Sai gì → mô tả cho AI ("nhân vật nháy góc trái", "va chạm không ăn"). AI tra [pitfalls.md](pitfalls.md) sửa.
4. Ưng → export ra SD (regen `s.json`) khi lên board thật.

Quy trình đầy đủ 6 bước: [workflow.md](workflow.md).

---

### Vì sao prompt ép "đọc skill/ trước" + "hỏi lại trước khi code"

- **Đọc skill/ trước** = AI có API thật → không bịa hàm (lỗi phổ biến nhất khiến game không chạy).
- **Hỏi lại trước khi code** = bắt AI map PRD (thường viết cho màn hình lớn, nhiều nút, chuột) về **ràng buộc Pika** (3 nút, 480×320) *trước*, thay vì code sai rồi sửa. Nhanh hơn về tổng thể.
