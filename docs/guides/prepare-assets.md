# Prepare assets

> **For:** artists and audio · **Needs:** the game's brief or demo · **Result:** final images, fonts and recordings the pack loads as they are (stage S7)

Read this **before drawing or recording**. The robot shows every image at the size it was
exported and has no runtime effects, so a wrong size or a missing bake means redoing the
work. Exact limits are in the [API reference](../reference/api.md#limits); the values that
matter most are repeated here as (`key` = value) and checked against the firmware.

## 1. Pick the format

| What | Transparent? | Several frames? | Format | Loaded with |
| --- | --- | --- | --- | --- |
| Character, icon, item | yes | no | PNG with alpha | `Sprite.image` |
| Background, panel, tile | no | no | `.rgb565`, or a PNG without alpha | `Sprite.new` / `Sprite.image` |
| States of one thing (idle, happy, sad) | no | yes | `.rgb565` frame strip | `Sprite.new` + `set_frame` |
| Short looping animation | no: drawn on an opaque black canvas ([Anim](../reference/api.md#anim)) | many | GIF or MJPEG | `Anim` |
| Plain colour block | no | no | nothing: the developer uses `Sprite.solid` | `Sprite.solid` |
| Text that changes with the language | — | — | a TTF font | `Text` |

Make `.rgb565` files from PNGs with the SDK tool (several inputs of the same size make a
strip, in order; transparent pixels are composited over `--bg`):

```bash
python tools/png2rgb565.py assets/bg.rgb565 art/bg.png
python tools/png2rgb565.py assets/hero.rgb565 art/hero_idle.png art/hero_happy.png --bg 0x6fa36b
```

It prints the `Sprite.new(...)` call to use.

## 2. Sizes are final

- The screen is 480 × 320, landscape; no image may be larger (`img_max_w` = 480,
  `img_max_h` = 320).
- Export every image at **exactly the size it is shown**: a character shown at 44 × 44 is
  exported at 44 × 44.
- Only sprites whose width **and** height are both within the transform limit
  (`transform_max_px` = 96) can be scaled or rotated at runtime. Anything larger that must
  appear at several sizes or angles is exported once per size or angle.
- Mirroring (`set_flip`) rewrites pixels: fine for a character turning around, not for
  per-frame effects, and not for sprites that change frames
  ([KI-FLIP-FRAME](../reference/known-issues.md#ki-flip-frame)): draw the mirrored frames
  into the strip instead.

## 3. Memory

There is no cap on the number of images; the limit is free memory while they are loaded.
File size does not matter, pixel size does:

| Kind | Memory while loaded |
| --- | --- |
| PNG that can be transparent (RGBA, grey+alpha, or any PNG with a `tRNS` chunk) | `w*h*3` bytes |
| PNG without alpha (RGB, grey or palette without `tRNS`) | `w*h*2` bytes |
| `.rgb565` or a solid block | `w*h*2` bytes |
| GIF / MJPEG | the whole file plus `w*h*2` bytes |

A full-screen image costs about 450 KB as a transparent PNG and about 300 KB without alpha.
The robot decides from the PNG header, so an RGBA PNG whose alpha is always opaque still
costs the larger amount: **export opaque images without an alpha channel**. While a PNG
decodes, its file is held in memory as well. Agree on each scene's total with the developer
before drawing many large images; `tools/smoke.py` reports the peak.

## 4. Frame strips

A strip holds all frames of one sprite back to back, frame 0 first, every frame the same
size, as raw pixels with no header. For `Sprite.new` each frame is `w*h*2` bytes of
little-endian RGB565, which is what `tools/png2rgb565.py` writes. Switching frames reads the
SD card each time, so strips suit state changes (idle → happy), not a continuous animation:
use a GIF or MJPEG for that. Paint the background colour behind the character, because
`.rgb565` has no transparency.

## 5. Text and fonts

- Text is drawn from a TTF shipped in the pack (`font_max_file_bytes` = 524288). The default
  font covers little beyond ASCII: every script shown (Vietnamese diacritics, Korean,
  Japanese, Chinese, Thai, ...) needs a TTF that contains those glyphs, under a licence that
  allows embedding. Symbols and emoji (★ ◀ ▶) go into images.
- Only a few (font, size) pairs can be in use at once (`font_slots` = 4): settle on a small
  set of sizes for the whole game.
- There is no word wrap and no width query: design each line for the **longest**
  translation, with the line breaks decided in advance.
- Do not bake text that changes with the language into an image. Text that is part of the
  artwork (a logo) can be drawn.
- `tools/check_spec.py` checks that the demo's text is covered by the shipped font.

## 6. Effects are baked

Gradients, shadows, blur, glow, rounded corners, tints and blend modes do not exist at
runtime; bake them into the image. A glow drawn with a "screen" blend over black becomes the
alpha channel of a PNG. More substitutions: [Port a demo](port-a-demo.md#porting-a-demo-that-was-not-built-on-the-kit).

## 7. Audio

- Formats: WAV or MP3. The shipped examples use WAV, 16 kHz, mono, 16-bit PCM; other WAV
  variants are untested.
- Every sound gets a short **alias** (`coin`, `hurt`, `ask_apple`) that the developer declares
  in `manifest.json`. A pack declares at most `sound_aliases_max` = 64 aliases, and every
  declared file must exist: either mistake rejects the **whole** pack, so deliver placeholder
  files under the final names early.
- **One channel:** a new sound cuts the one playing, and plays closer together than the
  cooldown (`sound_cooldown_ms` = 150) are refused. Keep frequent effects short, and make sure
  spoken instructions are not cut by an effect.
- There is no text-to-speech: every spoken line is a recording. The demo gate prints the list.
- Trim leading and trailing silence and normalise loudness across files.

## 8. File names

Lowercase ASCII letters, digits, `_` and `-`; no spaces, accents or upper case
(`hero_idle.png`, `tiles.rgb565`, `ask_apple.wav`). The robot's SD card is case-insensitive
and does not handle non-ASCII names reliably. Keep paths short: sound paths have a length
cap (`sound_path_len_max` = 64, including the terminator).

## Hand-off checklist

- [ ] Every image is exported at its on-screen size and fits the screen.
- [ ] PNG with alpha only where transparency is needed; opaque images as `.rgb565` or PNG
      without alpha.
- [ ] Frame strips are `.rgb565`, frames equal in size and in order, mirrored frames drawn in.
- [ ] Effects are baked in; nothing relies on runtime blur, gradients or blend modes.
- [ ] Scene memory agreed with the developer (section 3).
- [ ] Fonts cover every character shown and may be embedded.
- [ ] Audio: alias → file list, every file present, silence trimmed, loudness even.
- [ ] File names follow section 8.
