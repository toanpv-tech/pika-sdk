# `images/emoji/` — Unicode emoji full set (FLAT, codepoint-keyed)

Full ~3.4k Unicode emoji ship qua OTA. **Image set: Noto Emoji 72px PNG** ([Apache 2.0](https://github.com/googlefonts/noto-emoji)). **Keyword search: emojilib v4.0.3** ([MIT](https://github.com/muan/emojilib)), curate EN+VI.

## Layout

```
emoji/
├── README.md
├── meta.json                   # image set source/version/license attribution
├── png/                        # Noto Emoji PNG, naming = <codepoint_hex>.png
│   ├── 1f600.png               # 😀 grinning
│   ├── 1f44b.png               # 👋 wave
│   ├── 2764.png                # ❤ red heart
│   ├── 1f1fb_1f1f3.png         # 🇻🇳 (ZWJ/sequence: codepoints joined với `_`)
│   └── ... (~3.4k file phase 1 production; 30 placeholder trong skeleton)
└── aliases/                    # emojilib keyword metadata, per-language
    ├── en.json                 # cherry-pick từ emojilib dist/emoji-en-US.json
    └── vi.json                 # Pika curated (emojilib chưa có VI native)
```

**Naming convention** (`png/` files):
- Single codepoint: `<hex_lowercase>.png` — vd `1f600.png` cho 😀 (U+1F600)
- Multi-codepoint (ZWJ, sequence, skin tone): codepoints lowercase, join với `_` — vd `1f1fb_1f1f3.png` cho 🇻🇳 (U+1F1FB U+1F1F3)
- KHÔNG có prefix `emoji_u` (khác Noto upstream convention; rename khi ingest để parseable)

## Access từ Lua

```lua
-- A. lookup theo keyword (dùng lang hiện tại; đổi bằng Emoji.set_lang)
local path = Emoji.lookup("happy")             -- "@sdk/images/emoji/png/1f600.png" | nil,msg
local sprite = Sprite.image(path)

-- B. explicit lang
local path = Emoji.lookup("vui", "vi")         -- "@sdk/images/emoji/png/1f600.png"

-- C. emoji char -> codepoint hex
local hex = Emoji.path("😀")                   -- "1f600" | nil,msg

-- D. trực tiếp bằng codepoint hex (skip metadata)
local sprite = Sprite.image("@sdk/images/emoji/png/1f600.png")

-- E. đổi ngôn ngữ keyword cho lookup
Emoji.set_lang("vi")
```

## Resolver flow (C-side)

```c
// Emoji.lookup("happy", "en") → path
// 1. Load aliases/en.json (lazy, cache after first hit)
// 2. Scan: foreach (emoji_char, keywords) → if "happy" in keywords → return emoji_char
// 3. Convert emoji_char (UTF-8) → codepoint(s)
// 4. Format codepoint hex lowercase, join multi với `_`
// 5. Return "@sdk/images/emoji/png/<hex>.png"
// 6. (Sprite.image resolve tiếp qua @sdk/ resolver chung)
```

## Size budget

| Asset | Per-file | Total ~3.4k |
|---|---|---|
| Noto Emoji 72px PNG | ~3KB avg | ~10MB |
| `aliases/en.json` | — | ~250KB (sau khi cherry-pick) |
| `aliases/vi.json` | — | ~50KB (VI ít keyword hơn) |
| `meta.json` | — | <1KB |

**Total**: ~10.3MB cho full set. SD card 8GB+ thoải mái.

## OTA flow

Flat subsys, per-file temp-rename atomic (xem [SD-Resources.md §3 Mode 2](../../../../Lua/SD-Resources.md)). Pipeline `f735bd9a` đã hỗ trợ `.png/.json` trong `IsTargetExtension`.

**Update gradual:** không cần ship 3.4k cùng lúc. OTA push thêm emoji mới từng đợt; resolver miss → resolver fail miss-asset thân thiện (game không crash).

## Lazy-load consideration

aliases.json đọc 1 lần lúc Lua VM warm-up (load `Emoji` binding). Sau đó cache trong PSRAM (~250-300KB). Nếu phase 1 chỉ cần EN, có thể `Emoji.set_lang("vi")` mới load VI lazy.

## Hiện trạng vs production

**Hiện tại**: 30 emoji **REAL** (Noto Emoji v2.047 72px PNG) — curated phổ biến: faces, hands, hearts, fire, star, party. Tên file = `<codepoint_hex>.png`, khớp đúng keyword trong `aliases/{en,vi}.json`. Đã verify hợp lệ. (Lưu ý: Noto PNG có alpha → engine flatten over black, hiển thị trên nền đen — xem [images/README](../README.md) §Format.)

**Mở rộng full ~3.4k Unicode set** (OTA về sau, additive):
```bash
# Source: googlefonts/noto-emoji @ v2.047, png/72/  (Apache-2.0)
# Naming: emoji_u<hex>.png → <hex>.png (strip prefix "emoji_u")
BASE=https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.047/png/72
curl -sfL -o png/1f600.png "$BASE/emoji_u1f600.png"   # mẫu 1 file
# Thêm keyword tương ứng vào aliases/{en,vi}.json; resolver miss thân thiện nếu thiếu file
```

## Skin tone & ZWJ sequences

Phase 1 SKIP — only base emoji (no skin tone variant, no family combinations). Lý do:
- Skin tone × 5 nhân file lên 5×; ZWJ family × N nhân tiếp
- UI Pika hiếm cần variant
- Có thể OTA add sau (file mới = thêm `png/<hex>_<skin>.png`)

API `Emoji.lookup` phase 1 không expose skin tone selector. Phase 2 (nếu cần): `Emoji.lookup("wave", {skin = "1f3fb"})`.

## License attribution

- **Noto Emoji** (PNG assets): Apache 2.0 — không cần attribution UI bắt buộc, nhưng ship `meta.json` để tracking
- **emojilib** (JSON keywords): MIT — copyright notice trong `meta.json`

Cả hai license commercial-friendly cho firmware proprietary. Xem [meta.json](meta.json) cho full attribution.
