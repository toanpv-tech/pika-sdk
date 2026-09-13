# Pika Engine — Bắt đầu nhanh

Làm quen trong ~10 phút: cài tool, chạy một game mẫu, sửa một dòng, đóng gói ra
thẻ SD cho robot. Không cần biết C hay ESP-IDF.

## 1. Cài Pika Studio

Pika Studio là extension VS Code kèm sẵn simulator (chạy game trên PC, không cần
robot). Cài từ file `.vsix`:

```
code --install-extension pika-studio-<version>.vsix --force
```

Mở VS Code, panel **Pika Studio** xuất hiện ở thanh bên.

## 2. Trỏ tool tới SDK này

Tool đọc kho hỗ trợ (docs, thư viện, game mẫu) từ SDK qua một setting.
Mở **Settings → `pika.sdk.source`** và điền:

- **Đường dẫn thư mục** tới bản SDK trên máy, hoặc
- **git URL** của repo SDK (tool tự clone; Refresh chạy `git pull`).

## 3. Mở một game mẫu

Trong panel Pika Studio → mục **Examples**, chọn một game → **Open**. Tool sao
game mẫu vào vùng làm việc của bạn để sửa tự do. Các game mẫu đang có, mỗi cái
minh hoạ một mảng của engine:

| Example | Minh hoạ |
|---|---|
| `test_button` | `Input` — 3 nút, edge `just_pressed` / `just_released` |
| `test_font` | `Text` — font TTF, layout chữ trên panel 480×320 |
| `test_audio` | `Speaker` — phát sound theo alias `s.json`, hook `on_sound_end` |
| `test_voice` | `Voice` — phiên nhận giọng (cần mạng; xem §4) |

## 4. Chạy trên simulator

Bấm **Run** ở dòng game. Cửa sổ simulator 480×320 mở ra — đúng kích thước màn
robot. Bàn phím thay 3 nút robot:

| Nút robot | Phím |
|---|---|
| ENTER | `ENTER` hoặc `SPACE` |
| LEFT | `←` hoặc `A` |
| RIGHT | `→` hoặc `D` |

Một số hành vi chỉ có trên robot thật, simulator không mô phỏng:

- **Nút HOME** → hook `on_home()` không kích hoạt được trên PC; phải kiểm trên board.
- **Servo / LED** → không có phần cứng; lệnh chỉ được ghi log (xem panel Peripherals).
- **Voice** → cần backend thật; cấu hình `pika.voiceServer` + `pika.voiceMode`.

Các setting liên quan khi chạy: `pika.startParams` và `pika.language` (nội dung
`params` truyền vào `game_start`), `pika.simulateTalkFlow` (bật `params.is_a2a`),
`pika.rankMode` (nguồn dữ liệu cho `Ranking`).

## 5. Sửa và xem đổi ngay

Mở `scripts/main.lua`, đổi một chuỗi văn bản, lưu. Tool nạp lại game — không cần
build lại. Đây là vòng lặp phát triển chính: sửa Lua → thấy kết quả.

## 6. Đóng gói ra thẻ SD

Khi ưng ý, chuột phải game → **Package / Export to SD…**. Tool kiểm tra hợp lệ
(manifest, kích thước ảnh, tên file, đường dẫn sound) rồi chép game thành một
folder chạy được trên robot.

> Sửa file trực tiếp trên thẻ SD thì phải tạo lại `s.json` của folder (CRC),
> nếu không engine từ chối nạp. Export bằng tool đã lo việc này.

## Tiếp theo

- Hiểu engine: [Tổng quan](overview.md)
- Viết game từ đầu: [Guide](guide.md)
- Khai báo manifest: [manifest.json](manifest.md)
- Tra API: [API Reference](api.md)
- Thư viện Lua dùng lại (state machine, animator, UI, easing…): xem mục
  **Libraries** trong tool.

> ⚠️ Engine **không có API lưu trạng thái** (`State.*` đã bị gỡ) — Lua không ghi
> được file nào. Trạng thái chỉ sống trong 1 phiên chơi; muốn giữ điểm thì đẩy
> lên server bằng `Ranking.report`. Đừng thiết kế màn "Continue".
