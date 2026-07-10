# Pika SDK

Kho thông tin hỗ trợ cho **Pika Studio** — assets, tài liệu, thư viện Lua và
game mẫu cho engine game Pika (Lua trên robot ESP32-S3).

Đây là **repo độc lập, read-only**. Pika Studio nạp nó qua setting
`pika.sdk.source` (đường dẫn thư mục cục bộ hoặc git URL; tool clone và
`git pull` để cập nhật). Repo firmware không phụ thuộc kho này.

## Bố cục

```
pika-sdk/
├── sdk_version           # version hợp đồng API (tool đối chiếu firmware)
├── sdk.index.json        # manifest gốc: kho có những phần nào
├── assets/               # pack sprite/audio (Kenney) + index + script giải nén
│   ├── 2D/ 3D/ Audio/ Pixel/ Textures/ UI/
│   ├── assets.index.json     # catalog máy-đọc (id, loại, license, cover, counts)
│   ├── unzip_assets.sh       # giải nén .zip → folder per-pack (idempotent)
│   └── gen_assets_index.sh   # sinh assets.index.json từ pack đã giải nén
├── docs/                 # tham chiếu API + hướng dẫn (getting-started, guide, api…)
├── libraries/            # thư viện Lua chuẩn (bản gốc) — create-game copy từ đây
└── examples/             # game mẫu chạy được, mỗi cái minh hoạ một mảng engine
```

Mỗi phần có một `*.index.json` để tool đọc mà không phải quét cây thư mục.

## Version

`sdk_version` là số hợp đồng API mà kho này viết theo. Tool hiển thị nó và cảnh
báo (mềm) nếu firmware trên board báo version khác — vì SDK và firmware là hai
repo tách rời, đây là cách duy nhất phát hiện lệch.

## Assets

Từ [Kenney](https://kenney.nl) — CC0 trừ khi `License.txt` của pack nói khác.
Chỉ commit file `.zip` gốc + index; folder giải nén bị `.gitignore` (dựng lại
bằng `assets/unzip_assets.sh`).

## Dùng trong tool

Xem [docs/getting-started.md](docs/getting-started.md).
