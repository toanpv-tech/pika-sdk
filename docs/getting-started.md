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

Tool đọc kho hỗ trợ (assets, docs, thư viện, game mẫu) từ SDK qua một setting.
Mở **Settings → `pika.sdk.source`** và điền:

- **Đường dẫn thư mục** tới bản SDK trên máy, hoặc
- **git URL** của repo SDK (tool tự clone; Refresh chạy `git pull`).

## 3. Mở một game mẫu

Trong panel Pika Studio → mục **Examples**, chọn một game (ví dụ `hello-text`) →
**Open**. Tool sao game mẫu vào vùng làm việc của bạn để sửa tự do.

## 4. Chạy trên simulator

Bấm **Run** ở dòng game. Cửa sổ simulator 480×320 mở ra — đúng kích thước màn
robot. Bàn phím thay 3 nút robot: `ENTER/SPACE`, `LEFT/A`, `RIGHT/D`.

## 5. Sửa và xem đổi ngay

Mở `scripts/main.lua`, đổi một chuỗi văn bản, lưu. Tool nạp lại game — không cần
build lại. Đây là vòng lặp phát triển chính: sửa Lua → thấy kết quả.

## 6. Đóng gói ra thẻ SD

Khi ưng ý, chuột phải game → **Package / Export to SD…**. Tool kiểm tra hợp lệ
(manifest, kích thước ảnh, tên file) rồi chép game thành một folder chạy được
trên robot.

## Tiếp theo

- Hiểu engine: [Tổng quan](overview.md)
- Viết game từ đầu: [Guide](guide.md)
- Tra API: [API Reference](api.md)
- Thư viện Lua dùng lại (state machine, menu, save…): xem mục **Libraries** trong tool.
