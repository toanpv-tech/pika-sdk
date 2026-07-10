# Pika Engine — Tài liệu

Tài liệu tham chiếu cho **Pika Engine** — runtime game viết bằng Lua 5.5.0, nạp
game pack từ thẻ SD và điều khiển ngoại vi robot. Đây là bản trong **Pika SDK**;
tool Pika Studio hiển thị các trang này trực tiếp.

| Tài liệu | Đối tượng | Nội dung |
|---|---|---|
| [Bắt đầu nhanh](getting-started.md) | Người mới | Cài tool → mở game mẫu → Run → sửa → Export. Đọc đầu tiên. |
| [Tổng quan](overview.md) | Đội phát triển game | Ngoại vi điều khiển được, hai luồng chơi (Offline / A2A), ràng buộc tài nguyên. |
| [Guide](guide.md) | Người viết game (Lua) | Cách viết game pack: `manifest.json`, cấu trúc SD, vòng đời & hook, sandbox. |
| [API Reference](api.md) | Người viết game (Lua) | Tra cứu toàn bộ API Lua (~60 hàm) + bảng tra giá trị nhanh. |
| [Module Firmware](module.md) | Kỹ sư firmware | Kiến trúc nội bộ component `game_engine` (tham khảo). |
| [Monitor](monitor.md) | Khi chạy trên board | Từ khoá log để chẩn đoán. |

## Bắt đầu nhanh

- **Chưa từng dùng?** → [Bắt đầu nhanh](getting-started.md)
- **Engine làm được gì?** → [Tổng quan](overview.md)
- **Viết một game?** → [Guide · Quickstart](guide.md)
- **Tra cứu API Lua** → [API Reference](api.md)

> Đây là kho tham chiếu (read-only). Khi engine đổi public API / binding /
> manifest schema, tài liệu ở đây được cập nhật theo và `sdk_version` tăng lên.
