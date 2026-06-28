# `images/` — thư viện ảnh PIKA SDK

Ảnh dùng chung cho mọi game (UI, brand, characters, effects, backgrounds, emoji), truy cập qua path `@sdk/images/...`. Một phần đã sinh procedural theo *PIKA visual signature* (xem dưới); phần còn lại cần art thật / tải ngoài. Sibling thiết kế: `Lua/SD-Resources.md`, memory `pika-audio-library` (cùng tư tưởng cho audio).

## Hiện trạng (thực tế trong thư mục)

| Nhóm | Trạng thái | File |
|---|---|---|
| `ui/icons/` | ✅ **REAL** (sinh) | `heart` `star` `arrow_l` `arrow_r` (.png, 64×64) |
| `backgrounds/` | ✅ **REAL** (sinh) | `forest` `city` `space` (.png, 480×320) |
| `brand/logo.png` | ✅ **REAL** (sinh) | emblem mặt PIKA (160×160) |
| `brand/mascot_*` | ⏳ **placeholder** (cần art) | `mascot_idle` `mascot_happy` (.png) |
| `characters/pika/` | ⏳ **placeholder** (cần art) | `idle` `sleep` `talk` (.gif) |
| `effects/` | ⏳ **placeholder** (cần art/GIF) | `sparkle` `confetti` `explosion` (.gif) |
| `emoji/png/` | ✅ **REAL** (Noto v2.047) | 30 curated → OTA expand full ~3.4k set, xem [emoji/README](emoji/README.md) |

> "placeholder" = file 0-byte, resolver miss thân thiện (game không crash). Nhóm cần **art thật** (nhân vật/linh vật) KHÔNG sinh procedural được — generator chỉ phủ phần hình học; emoji tải từ Noto v2.047.

## Visual signature (asset sinh tuân theo)

- **Palette trẻ em, tương phản cao, phẳng**: PIKA yellow `#FFD23F` (lead) · coral `#FF5A5F` · gold `#FFD23F` · sky `#4FC3F7` · leaf `#66BB6A` · ink `#2B2B2B`. RGB565-safe.
- **Hình khối to, bo tròn, ít chi tiết** — đọc rõ trên panel nhỏ, hợp 6–9 tuổi.
- **Icon = glyph trên nền đen** (lý do ở Format), background = full-panel có gradient tạo chiều sâu.
- Logo/mascot dùng ngôn ngữ tạo hình PIKA: mặt tròn vàng, tai nhọn, má hồng, cười.

## Access từ Lua

`@sdk/images/...` là **file-path** (dấu `/`, **có đuôi**), resolve qua resolver chung [bindings_util.c:16](../../../../head_esp32/components/pika_engine/src/bindings/bindings_util.c#L16) → `GAMES_ROOT/<sdk_root>/images/...`. (Khác audio: `@sdk:audio/` colon-alias, không đuôi.)

```lua
local heart = Sprite.image("@sdk/images/ui/icons/heart.png")   -- PNG → sprite
local bg    = Sprite.image("@sdk/images/backgrounds/forest.png")
local pika  = Anim.new("@sdk/images/characters/pika/idle.gif")  -- GIF → anim (khi có art)
local logo  = Sprite.image("@sdk/images/brand/logo.png")
```

Emoji có sugar riêng (`Emoji.lookup/path`) → trả về cùng path `@sdk/images/emoji/png/<hex>.png`. Xem [emoji/README](emoji/README.md).

## Format & ràng buộc embedded

| Ext | API | Decode-to | Giới hạn |
|---|---|---|---|
| `.png` | `Sprite.image(rel)` | RGB565 LE (PSRAM) | ≤ 1 MiB, **alpha flatten over black** |
| `.rgb565` | `Sprite.new(rel,w,h)` | raw blob (no header) | đúng `w*h*2` byte |
| `.gif` / `.mjpeg` | `Anim.new(rel)` | frame list (PSRAM) | ≤ 4 MiB, **1 anim đồng thời** |

- **Alpha flatten over black** (chưa có RGB565A8): vùng trong suốt → đen. Asset sinh vì thế **author opaque trên nền đen** ⇒ WYSIWYG đúng device. Cần phủ lên nền sáng → tự vẽ nền bằng `Sprite.solid` trước. (memory `lua-image-anim-display`)
- **Canvas ≤ 480×320**; PNG decode mỗi lần `Sprite.image()` (no cache phase 1); buffer PSRAM-only.
- Codec qua dependency-inverted hook (PNG=lgfx_pngle, GIF=AnimatedGIF, MJPEG=esp_jpeg baseline).

## Tái sinh bộ P0 (phần hình học)

Generator procedural deterministic, hand-encode PNG bằng stdlib `zlib`+`crc32`: `gen_pika_image.py` (recipe theo signature: shapes/gradient/particle). Đổi recipe → chạy lại để cập nhật đồng loạt. Sinh: `ui/icons/{heart,star,arrow_l,arrow_r}`, `backgrounds/{forest,city,space}`, `brand/logo`.

## Governance

- **Additive only** — file mới tên mới; KHÔNG rename/xóa file cũ (đường dẫn = hợp đồng ổn định như API; Pika CI kiểm). Đổi/xóa = breaking → bump SDK version.
- `category/name.ext`, lowercase snake, ngữ nghĩa (không kỹ thuật).
- Folder = nguồn chân lý; OTA per-file temp-rename atomic (`<path>.tmp` → `f_rename`); per-file CRC ở pipeline tải/verify (`f735bd9a`). Xem [SD-Resources.md §3](../../../../Lua/SD-Resources.md).
