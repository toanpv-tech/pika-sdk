"""Convert PNG files to the raw RGB565 file that Sprite.new reads.

Output: 2 bytes per pixel, little-endian, row-major, no header, the format
asset_load_rgb565 copies straight into an LVGL RGB565 buffer. Channels are
truncated to 5/6/5 bits, as the engine's own PNG decoder does
(host/asset_hooks.cpp png_draw_cb). Several inputs of the same size are written
back to back in order: a frame strip for spr:set_frame(path, i).

The engine has no alpha in .rgb565: pixels with alpha below 255 are blended
over --bg, which is required when an input has transparency.

Reads non-interlaced 8-bit PNGs (colour types 0, 2, 3, 4, 6), stdlib only.

usage: python tools/png2rgb565.py <out.rgb565> <in.png> [<in2.png> ...] [--bg 0xRRGGBB]
exit 0 = written, 1 = error.
"""
import argparse
import json
import os
import struct
import sys
import zlib

SIG = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
CONSTRAINTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "contract", "constraints.json")


class PngError(Exception):
    pass


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def unfilter(raw, w, h, bpp):
    stride = w * bpp
    out = bytearray(stride * h)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ft = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if len(line) != stride:
            raise PngError("image data is truncated")
        if ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up_left = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + paeth(left, prev[i], up_left)) & 0xFF
        elif ft != 0:
            raise PngError("unknown filter type %d" % ft)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def decode(path):
    """Return (w, h, pixels as [(r, g, b, a)], has_alpha)."""
    with open(path, "rb") as f:
        d = f.read()
    if d[:8] != SIG:
        raise PngError("not a PNG file")
    pos, ihdr, plte, trns, idat = 8, None, None, None, []
    while pos + 8 <= len(d):
        ln, typ = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            plte = body
        elif typ == b"tRNS":
            trns = body
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    if not ihdr:
        raise PngError("no IHDR chunk")
    w, h, depth, ct, _, _, interlace = ihdr
    if depth != 8:
        raise PngError("bit depth %d is not supported: re-export as 8-bit" % depth)
    if interlace:
        raise PngError("interlaced PNG is not supported: re-export without interlacing")
    if ct not in CHANNELS:
        raise PngError("colour type %d is not supported" % ct)
    if ct == 3 and not plte:
        raise PngError("palette image without PLTE chunk")
    bpp = CHANNELS[ct]
    try:
        raw = zlib.decompress(b"".join(idat))
    except zlib.error as e:
        raise PngError("bad image data: %s" % e)
    data = unfilter(raw, w, h, bpp)

    px = []
    key = None
    if trns and ct == 0 and len(trns) >= 2:
        key = struct.unpack(">H", trns[:2])[0] & 0xFF
    elif trns and ct == 2 and len(trns) >= 6:
        key = tuple(v & 0xFF for v in struct.unpack(">HHH", trns[:6]))
    for i in range(w * h):
        o = i * bpp
        if ct == 0:
            v = data[o]
            px.append((v, v, v, 0 if v == key else 255))
        elif ct == 2:
            rgb = (data[o], data[o + 1], data[o + 2])
            px.append(rgb + (0 if rgb == key else 255,))
        elif ct == 3:
            idx = data[o]
            if 3 * idx + 2 >= len(plte):
                raise PngError("palette index %d out of range" % idx)
            a = trns[idx] if trns and idx < len(trns) else 255
            px.append((plte[3 * idx], plte[3 * idx + 1], plte[3 * idx + 2], a))
        elif ct == 4:
            px.append((data[o], data[o], data[o], data[o + 1]))
        else:
            px.append((data[o], data[o + 1], data[o + 2], data[o + 3]))
    return w, h, px, any(p[3] < 255 for p in px)


def to_rgb565(px, bg):
    br, bgg, bb = (bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF
    out = bytearray(len(px) * 2)
    for i, (r, g, b, a) in enumerate(px):
        if a < 255:
            r = (r * a + br * (255 - a) + 127) // 255
            g = (g * a + bgg * (255 - a) + 127) // 255
            b = (b * a + bb * (255 - a) + 127) // 255
        struct.pack_into("<H", out, 2 * i, ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out")
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--bg", help="background 0xRRGGBB for pixels with alpha < 255")
    a = ap.parse_args()
    with open(CONSTRAINTS, encoding="utf-8") as f:
        lim = json.load(f)["limits"]
    bg = None
    if a.bg is not None:
        try:
            bg = int(a.bg, 16)
        except ValueError:
            bg = -1
        if not 0 <= bg <= 0xFFFFFF:
            print("error: --bg must be 0xRRGGBB, got %s" % a.bg)
            return 1

    blob, size = bytearray(), None
    for path in a.inputs:
        try:
            w, h, px, alpha = decode(path)
        except (OSError, PngError) as e:
            print("error: %s: %s" % (path, e))
            return 1
        if size and (w, h) != size:
            print("error: %s is %dx%d, the first frame is %dx%d: strip frames must be the same size" % ((path, w, h) + size))
            return 1
        size = (w, h)
        if w > lim["img_max_w"] or h > lim["img_max_h"]:
            print("error: %s is %dx%d, larger than %dx%d: Sprite.new refuses it" % (path, w, h, lim["img_max_w"], lim["img_max_h"]))
            return 1
        if alpha and bg is None:
            print("error: %s has transparent pixels and .rgb565 has no alpha: pass --bg 0xRRGGBB "
                  "(the colour behind it), or keep it a PNG for Sprite.image" % path)
            return 1
        blob += to_rgb565(px, bg or 0)

    with open(a.out, "wb") as f:
        f.write(blob)
    w, h = size
    print("wrote %s: %dx%d, %d frame(s), %d bytes → Sprite.new(\"%s\", %d, %d)"
          % (a.out, w, h, len(a.inputs), len(blob), a.out.replace("\\", "/"), w, h))
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
