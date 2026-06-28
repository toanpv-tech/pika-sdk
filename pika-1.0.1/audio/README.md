# `audio/` — thư viện âm thanh PIKA SDK

Bộ âm dùng chung cho mọi game, truy cập qua **alias** (`@sdk:audio/...`). Hiện tại chứa **bộ P0** (nền tảng) sinh theo *PIKA sonic signature* — tham khảo thiết kế đầy đủ ở `_bmad-output/brainstorming/brainstorming-session-2026-05-29-1609.md` và memory `pika-audio-library`.

## Hiện trạng (thực tế trong thư mục)

Toàn bộ là **WAV PCM 16-bit mono 22050 Hz**, peak ≈ −3 dBFS. Chưa có file `.mp3`.

```
audio/
├── ui/          # phản hồi giao diện (micro, mallet mềm)
│     back  cancel  confirm  error  hover  open  select  toggle
├── feedback/    # đúng/sai/thưởng (game-agnostic)
│     combo_up  correct  fail_soft  hint  perfect  reward  success  wrong_soft
└── emotion/     # "giọng/cảm xúc" PIKA (pitch-glide)
      celebrate  giggle  happy  sad  sleepy  surprised
```

> Các nhóm khác trong thiết kế (`gameplay/`, `stinger/`, `music/`, `voice/`) là **P1–P2, chưa tạo**. Sẽ thêm theo nguyên tắc additive (xem Governance).

## Sonic signature (mọi file tuân theo)

- Thang **C major pentatonic** (C-D-E-G-A) — bấm loạn vẫn hài hòa.
- Timbre lõi: sine/triangle mềm + bội âm nhẹ + "sparkle" lúc attack (music-box).
- Ngôn ngữ cao độ: tích cực = đi **lên**, tiêu cực = đi **xuống nhẹ** (không nghịch tai).
- `emotion/*` dùng pitch-glide ("ríu rít" kiểu R2-D2 em bé).

## Access từ Lua (audio alias)

`Speaker.play` nhận **alias** khai trong `manifest.audio.sounds`, KHÔNG nhận path. Path `@sdk:audio/...` CHỈ nằm trong manifest:

```json
// <game>/manifest.json
"audio": {
  "sounds": {
    "tap": { "path": "@sdk:audio/ui/select" },
    "win": { "path": "@sdk:audio/feedback/success" },
    "yay": { "path": "@sdk:audio/emotion/happy" }
  },
  "volume": 70
}
```

```lua
Speaker.play("tap")   -- alias do game tự đặt, KHÔNG phải path
Speaker.play("win")
```

- **Prefix `@sdk:audio/` (dấu hai chấm)** — KHÔNG `@sdk/audio/` (slash). Audio resolve qua `sound_table` (alias), không qua file-path resolver. Xem `head_esp32/components/pika_engine/src/sound_table.c`.
- **Extensionless là chuẩn** (`@sdk:audio/ui/select`) — resolver tự chọn file. Hiện mọi alias chỉ có bản `.wav` nên an toàn. Có thể ghi rõ `.wav` nếu muốn tường minh.

## Format & ràng buộc embedded

- **WAV** (PCM 16-bit, mono, 22050 Hz): SFX/feedback/emotion — decode nhanh, low-latency. Mọi clip ngắn (≤ ~600 ms) vì audio pipeline dùng chung (anim + speaker + voice tranh chấp).
- **MP3** (mono): dành cho music/voice dài (khi thêm sau). Pipeline đã hỗ trợ `.mp3/.wav` — xem `head_esp32/main/src/middleware/file_validator/file_validator.cpp`.
- Loudness chuẩn hóa 1 mức để trẻ không giật mình to/nhỏ lẫn lộn.

## Tái sinh bộ P0

Bộ P0 sinh bằng generator procedural (deterministic): `gen_pika_audio.py` (đọc "recipe" theo signature). Đổi recipe → chạy lại để cập nhật đồng loạt.

## Governance

- Alias = **hợp đồng ổn định như API**: chỉ **thêm** trong cùng version SDK; đổi/xóa alias = breaking → bump version + giữ alias cũ redirect 1 minor.
- `category/name`, lowercase snake, ngữ nghĩa (không kỹ thuật).
- Folder = nguồn chân lý; additive, per-file temp-rename atomic; per-file CRC ở pipeline tải/verify.
