# `fonts/` — typography PIKA SDK

Font `.ttf` cho HUD text, **render runtime ở size tùy ý** qua LVGL Tiny TTF. Nạp bằng `HUD.set_font("@sdk/fonts/<lang>/<weight>.ttf", size)`.

> Đổi từ `.bin` (bitmap pre-render fixed-size) sang `.ttf`: 1 file phủ **mọi size**, đổi size ở runtime không cần thêm file.

## Hiện trạng (thực tế trong thư mục)

| File | Family | Glyph range |
|---|---|---|
| `latin/regular.ttf` ✅ | Noto Sans | ASCII + Latin-1 + dấu câu + € (221 glyph) |
| `latin/bold.ttf` ✅ | Noto Sans | (như trên) |
| `vi/regular.ttf` ✅ | Noto Sans | + Latin-Ext-A + ơ/ư + khối Việt (1EA0–1EFF) + ₫ (486 glyph) |
| `vi/bold.ttf` ✅ | Noto Sans | (như trên) |
| `arimo/regular.ttf` ✅ | Arimo | Latin + đầy đủ tiếng Việt + € + ₫ (470 glyph) |
| `arimo/bold.ttf` ✅ | Arimo | (như trên) |

Tất cả **REAL**, redistributable. **Noto Sans** ([Apache-2.0](https://github.com/notofonts/notofonts.github.io)) ~16KB latin / ~36KB vi. **Arimo** ([Apache-2.0](https://github.com/googlefonts/Arimo), **metric-compatible với Arial** — nhìn như Arial, ship hợp pháp) ~33KB, 1 file phủ cả Latin+VN. Resident PSRAM khi dùng.

> ⚠️ KHÔNG nhúng font proprietary (Arial/Times/Calibri/Segoe UI của Microsoft) — cấm redistribute. Cần "kiểu Arial" → dùng Arimo (đã có). Thêm font mới: chỉ chọn license OFL/Apache.

> `zh/` `ja/` (CJK): nay khả thi vì không cần bake từng size, nhưng vẫn **defer** — buffer .ttf full + glyph cache lớn, cần subset per-game + cân ngân sách RAM.

## Access từ Lua

```lua
HUD.set_font("@sdk/fonts/vi/regular.ttf", 18)   -- render 18px
HUD.set_label("Xin chào PIKA! Giá: 50.000₫")
HUD.set_font("@sdk/fonts/vi/regular.ttf", 28)   -- cùng file, resize tại chỗ
HUD.set_font("@sdk/fonts/latin/bold.ttf", 20)
```

- `size`: px, **optional** (mặc định 16), clamp về `[8, 96]`.
- Contract MUTATOR: thành công → không trả gì; lỗi (file thiếu/format sai) → `nil, msg` để script degrade (không raise).
- Resolve qua `@sdk/` resolver chung ([bindings_util.c:16](../../../../head_esp32/components/pika_engine/src/bindings/bindings_util.c#L16)).
- Trước khi game gọi `set_font`, HUD dùng font mặc định LVGL (Montserrat, **không có glyph tiếng Việt** → dấu VN ra ô vuông cho tới khi nạp `vi/*`).

## Cơ chế nạp (bridge)

1. Resolve path → mở qua asset-opener (spot-CRC FileValidator) → đọc trọn `.ttf` vào **buffer PSRAM giữ RESIDENT** (`heap_caps_malloc SPIRAM`, cap **512KB**).
2. `lv_tiny_ttf_create_data(buf, size, px)` → `lv_font_t*`. Tiny TTF (stb_truetype) **chỉ giữ con trỏ** vào buffer và raster glyph theo nhu cầu (KHÔNG copy) → buffer **không được free** cho tới khi destroy face. Glyph cache nằm trong heap TLSF của LVGL (PSRAM).
3. Apply `lv_obj_set_style_text_font` lên HUD label. Tối đa **4 face** cache theo session (key theo **path**); gọi lại cùng path với size khác → `lv_tiny_ttf_set_size` resize tại chỗ (flush glyph cache). `game_end`/abort → `renderer_font_reset()` destroy hết + **free buffer SAU destroy** + label về font mặc định. Không leak.

> **Lưu ý 1 active font**: HUD hiện 1 label → 1 size hiển thị/face tại một thời điểm. Cần 2 size cùng family đồng thời (nhiều label) sẽ phải đổi key cache sang (path,size).

**Config**: `LV_USE_TINY_TTF 1` (+ `LV_TINY_TTF_FILE_SUPPORT 0`, dùng `create_data` từ buffer đã validate) trong `head_esp32/main/src/driver/display/lv_conf.h` (file config LVGL authoritative; lv_conf.h override Kconfig/sdkconfig).

Code: [lvgl_renderer.c](../../../../head_esp32/components/pika_engine/src/lvgl_renderer.c) (`renderer_set_font`/`renderer_font_reset`), [bind_engine.c](../../../../head_esp32/components/pika_engine/src/bindings/bind_engine.c) (`HUD.set_font`).

## Tái sinh

Generator: `gen_pika_fonts.py` (`pyftsubset` từ `fontTools` — `pip install fonttools`). Source TTF (Noto Sans, Arimo) đặt ở `C:/temp/fonts_src/`; thêm font mới = chỉnh `JOBS`/`LATIN`/`VI`/`FULL` rồi chạy lại. Drop hinting + GSUB/GPOS (Tiny TTF không shape; dùng glyph precomposed).

## Governance

- **Additive only** — file mới tên mới; KHÔNG rename/xóa (đường dẫn = hợp đồng như API; đổi/xóa = breaking → bump SDK version).
- `lang/weight.ttf`, lowercase. Folder = nguồn chân lý; OTA per-file temp-rename atomic + per-file CRC (`f735bd9a`).

> **Verify**: build-verified (`idf.py build` sạch, tiny_ttf compiled in). Render trên device: cần flash + `font-demo` để xác nhận glyph (đặc biệt dấu tiếng Việt) + đổi size runtime.
