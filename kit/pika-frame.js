/* pika-frame.js - robot-frame kit for Pika Engine demos.
 *
 * A demo written against this file uses the same hooks (game_start, on_tick,
 * on_input, on_sound_end, on_voice_event, on_home, game_end) and the same API
 * names as the Lua engine (Sprite, Text, Anim, Speaker, Input, Timer, Led,
 * Servo, Voice, Engine), with the same limits. Porting is transliteration:
 * `spr.set_pos(x, y)` becomes `spr:set_pos(x, y)`. The API table is checked
 * against contract/api.json at boot, so the kit never offers a call the robot
 * does not have.
 *
 * Load order: pika-constraints.js, then the demo's PIKA_MANIFEST + hooks,
 * then this file. Art lives in <template id="pika-art"> as elements tagged
 * data-pika-sprite="<path>" (any CSS inside: it is baked to a PNG); the demo
 * only moves, fades, flips, stacks and swaps them at runtime.
 */
(function () {
  'use strict';

  const C = window.PIKA_CONSTRAINTS;
  if (!C) throw new Error('pika-frame: load kit/pika-constraints.js first');
  const L = C.limits;
  const W = C.facts.screen[0], H = C.facts.screen[1];
  const TICK_MS = Math.round(1000 / L.target_fps);
  // Soft reference level from shipped packs (~1 MB of sprites), not a firmware limit.
  const PSRAM_SOFT_WARN = 1.5 * 1024 * 1024;

  const nativeTimeout = window.setTimeout.bind(window);
  const nativeRaf = window.requestAnimationFrame.bind(window);
  const man = window.PIKA_MANIFEST || {};
  const qs = new URLSearchParams(location.search);

  /* ---------------- lint ---------------- */
  const lints = new Map();   // code+detail -> {code, msg, n}
  function lint(code, msg) {
    const k = code + '|' + msg;
    const e = lints.get(k);
    if (e) { e.n++; return; }
    lints.set(k, { code, msg, n: 1 });
    console.warn('[pika-lint] ' + code + ': ' + msg);
    ui.dirty = true;
  }

  // Game code must use on_tick + Timer.millis(); async waits do not port.
  // The kit itself only uses the native copies captured above.
  function trapAsync(name) {
    const orig = window[name].bind(window);
    window[name] = function () {
      lint('L-ASYNC', name + '() in game code; use Timer.millis() deadlines checked in on_tick');
      return orig.apply(null, arguments);
    };
  }
  ['setTimeout', 'setInterval', 'requestAnimationFrame'].forEach(trapAsync);

  /* ---------------- DOM shell ---------------- */
  const css = `
  .pk-wrap{display:flex;gap:16px;align-items:flex-start;font:13px system-ui,sans-serif;color:#dde;background:#15171c;padding:16px;min-height:100vh;box-sizing:border-box;flex-wrap:wrap}
  .pk-dev{display:flex;flex-direction:column;align-items:center;gap:10px}
  .pk-bezel{background:#0b0c0f;border-radius:18px;padding:14px;box-shadow:0 0 0 2px #2a2d35}
  #pk-screen{position:relative;width:${W}px;height:${H}px;overflow:hidden;background:#000;transform-origin:top left}
  #pk-screen>*{position:absolute;left:0;top:0}
  #pk-grid{pointer-events:none;inset:0;width:${W}px;height:${H}px;display:none;
    background-image:linear-gradient(rgba(0,255,200,.18) 1px,transparent 1px),linear-gradient(90deg,rgba(0,255,200,.18) 1px,transparent 1px);background-size:8px 8px}
  .pk-btns{display:flex;gap:10px}.pk-btns button{width:56px;height:40px;border-radius:10px;border:0;background:#2a2d35;color:#fff;font-size:18px;cursor:pointer}
  .pk-btns button.on{background:#4a7cff}
  .pk-side{width:320px;display:flex;flex-direction:column;gap:8px}
  .pk-card{background:#1d2027;border-radius:10px;padding:10px}
  .pk-card h4{margin:0 0 6px;font-size:12px;letter-spacing:.04em;color:#9aa}
  .pk-row{display:flex;justify-content:space-between}.pk-bad{color:#ff7a7a}.pk-warn{color:#ffc658}
  .pk-lints{max-height:220px;overflow:auto;font:12px ui-monospace,monospace}
  .pk-led{width:22px;height:22px;border-radius:50%;background:#000;display:inline-block;vertical-align:middle;box-shadow:0 0 0 2px #333}
  .pk-log{max-height:120px;overflow:auto;font:11px ui-monospace,monospace;color:#9ab}
  .pk-side input{width:60%;background:#111;border:1px solid #333;color:#fff;border-radius:6px;padding:3px 6px}
  .pk-side button.sm{background:#2a2d35;color:#fff;border:0;border-radius:6px;padding:4px 8px;cursor:pointer}`;
  const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);

  const art = document.getElementById('pika-art');
  const root = document.createElement('div');
  root.className = 'pk-wrap';
  root.innerHTML = `
   <div class="pk-dev"><div class="pk-bezel"><div id="pk-screen"></div></div>
    <div class="pk-btns"><button data-a="left">◀</button><button data-a="enter">●</button><button data-a="right">▶</button><button data-a="home">⌂</button></div>
    <div style="color:#778">keys: ←/A · Enter/Space · →/D · H=Home · G=grid · Z=zoom · R=restart</div></div>
   <div class="pk-side">
    <div class="pk-card"><h4>BUDGET (now · peak / cap)</h4><div id="pk-bud"></div></div>
    <div class="pk-card"><h4>LINT</h4><div class="pk-lints" id="pk-lints"></div></div>
    <div class="pk-card"><h4>PERIPHERALS</h4><div>LED <span class="pk-led" id="pk-led"></span> <span id="pk-servo"></span></div>
     <div style="margin-top:6px">Voice <input id="pk-kw" placeholder="keyword"> <button class="sm" id="pk-say">send</button></div>
     <div class="pk-log" id="pk-log"></div></div>
    <div class="pk-card"><button class="sm" id="pk-export">Export pika-spec.json</button> <span style="color:#778">hand-off to porting</span></div>
   </div>`;
  document.body.appendChild(root);
  const screen = root.querySelector('#pk-screen');
  const grid = document.createElement('div'); grid.id = 'pk-grid';
  const ui = { dirty: true };

  function log(s) {
    const el = root.querySelector('#pk-log');
    el.textContent = (s + '\n' + el.textContent).slice(0, 4000);
  }

  /* ---------------- session state ---------------- */
  let S;   // reset per session so restart is a clean run, as on the robot
  const spec = { sprites: {}, fonts: {}, sounds: {}, texts: {}, glyphs: {}, peak: { sprites: 0, texts: 0, psram_bytes: 0, fonts: 0 } };

  function newSession() {
    screen.textContent = '';
    screen.appendChild(grid);
    S = {
      t0: performance.now(), running: true, exitReason: null,
      sprites: new Set(), texts: new Array(L.text_slots).fill(null),
      faces: new Map(), anim: null, psram: 0,
      btn: {}, phys: {}, events: [],
      sound: { cur: null, lastPlay: -1e9, audio: null },
      frameCalls: 0, frameWindow: 0,
      phase: 'start', voice: 'idle', hooks: {},
    };
  }

  function now() { return Math.floor(performance.now() - S.t0); }

  function bump() {
    const p = spec.peak;
    p.sprites = Math.max(p.sprites, S.sprites.size);
    p.texts = Math.max(p.texts, S.texts.filter(Boolean).length);
    p.psram_bytes = Math.max(p.psram_bytes, S.psram);
    p.fonts = Math.max(p.fonts, S.faces.size);
    if (S.psram > PSRAM_SOFT_WARN) lint('L-PSRAM', 'sprite PSRAM ' + kb(S.psram) + ' KB > reference level ' + kb(PSRAM_SOFT_WARN) + ' KB');
    ui.dirty = true;
  }
  const kb = (b) => Math.round(b / 1024);
  // Must match BLOCKING_LINTS in tools/check_spec.py.
  const BLOCKING = new Set(['L-FRAME-FMT', 'L-TEXT', 'L-TEXT-OVF', 'L-TEXT-OVL', 'L-XFORM', 'L-SIZE', 'L-WDOG', 'L-ERROR',
    'L-ASYNC', 'L-INT', 'L-LED', 'L-INPUT', 'L-SOUND', 'L-API', 'L-VOICE-EARLY', 'L-HOOK-REBIND']);

  /* Children of #pk-screen are the engine's single LVGL parent: stacking is
   * creation order, set_z is a child index, Text shares the same list. */
  function place(el) { screen.insertBefore(el, grid); }

  /* ---------------- Sprite ---------------- */
  function artFor(path) {
    if (!art) return null;
    const base = path.replace(/^.*\//, '').replace(/\.(png|rgb565)$/i, '');
    return art.content.querySelector('[data-pika-sprite="' + path + '"]') ||
           art.content.querySelector('[data-pika-sprite="' + base + '"]');
  }

  function measure(el) {
    const probe = el.cloneNode(true);
    probe.style.position = 'absolute'; probe.style.visibility = 'hidden';
    screen.appendChild(probe);
    const r = probe.getBoundingClientRect();
    const sc = screenScale();
    const w = Math.round(r.width / sc), h = Math.round(r.height / sc);
    screen.removeChild(probe);
    return [w, h];
  }

  function checkBakedMotion(el, path) {
    const all = [el].concat(Array.from(el.querySelectorAll('*')));
    for (const n of all) {
      const cs = getComputedStyle(n);
      if (cs.animationName && cs.animationName !== 'none') {
        lint('L-BAKE', path + ': CSS animation inside a sprite is baked into a still image');
        return;
      }
    }
  }

  function makeSprite(path, el, w, h, bpp, kind) {
    if (w > W || h > H) { lint('L-SIZE', path + ' ' + w + 'x' + h + ' > ' + W + 'x' + H); return [null, 'too_big']; }
    el.style.width = w + 'px'; el.style.height = h + 'px';
    el.style.transformOrigin = 'center';
    place(el);
    if (kind === 'image') checkBakedMotion(el, path);
    const bytes = w * h * bpp;
    // Like the engine: hidden until the first set_pos / set_visible.
    el.style.display = 'none';
    // fh/fv: flip state the engine records; sh/sv: orientation of the pixels shown.
    // They differ after set_frame (KI-FLIP-FRAME).
    const rec = { path, el, w, h, x: 0, y: 0, bytes, sx: 1, rot: 0, fh: false, fv: false, sh: false, sv: false, alive: true,
                  pending: true, hidden: false, born: now() };
    S.sprites.add(rec); S.psram += bytes;
    const e = spec.sprites[path] || (spec.sprites[path] = { w, h, format: bpp === 3 ? 'png_alpha' : 'rgb565', frames: 0, created: 0 });
    e.created++;
    if (el.querySelector('[data-pika-frame]')) e.frames = el.querySelectorAll('[data-pika-frame]').length;
    bump();
    return [spriteApi(rec)];
  }

  function applyVis(r) { r.el.style.display = r.pending || r.hidden ? 'none' : ''; }

  function applyXform(r) {
    const t = [];
    if (r.sh || r.sv) t.push('scale(' + (r.sh ? -1 : 1) + ',' + (r.sv ? -1 : 1) + ')');
    if (r.sx !== 1) t.push('scale(' + r.sx + ')');
    if (r.rot) t.push('rotate(' + r.rot + 'deg)');
    r.el.style.transform = t.join(' ');
  }

  function transformable(r, what) {
    if (r.w <= L.transform_max_px && r.h <= L.transform_max_px) return true;
    lint('L-XFORM', what + ' refused: ' + r.path + ' ' + r.w + 'x' + r.h + ' > ' + L.transform_max_px + 'px (the robot refuses it too)');
    return false;
  }

  function spriteApi(r) {
    const live = () => r.alive;
    return {
      set_pos(x, y) {
        if (!live()) return;
        if (!Number.isInteger(x) || !Number.isInteger(y)) lint('L-INT', 'set_pos got a non-integer; Lua raises — round first (' + r.path + ')');
        r.x = Math.round(x); r.y = Math.round(y);
        r.el.style.left = r.x + 'px'; r.el.style.top = r.y + 'px';
        if (r.pending) { r.pending = false; applyVis(r); }
      },
      get_pos() { return [r.x, r.y]; },
      get_size() { return [r.w, r.h]; },
      set_visible(b) { if (!live()) return; r.pending = false; r.hidden = !b; applyVis(r); },
      set_opacity(o) { if (live()) r.el.style.opacity = Math.max(0, Math.min(255, o)) / 255; },
      set_z(z) {
        if (!live()) return;
        const kids = Array.from(screen.children).filter((n) => n !== grid);
        const i = Math.max(0, Math.min(kids.length - 1, z | 0));
        screen.removeChild(r.el);
        const rest = Array.from(screen.children).filter((n) => n !== grid);
        screen.insertBefore(r.el, rest[i] || grid);
      },
      to_front() { if (live()) place(r.el); },
      to_back() { if (live()) screen.insertBefore(r.el, screen.firstChild); },
      set_flip(fh, fv) {
        if (!live()) return false;
        S.frameCalls++;
        fh = !!fh; fv = !!fv;
        // The engine rewrites only the axes where the request differs from the recorded state.
        const dh = fh !== r.fh, dv = fv !== r.fv;
        if (!dh && !dv && (r.sh !== fh || r.sv !== fv)) lint('L-FLIP-FRAME', r.path + ': set_flip after set_frame is a no-op (same state as recorded), the frame stays unflipped; ship pre-flipped frames (KI-FLIP-FRAME)');
        if (dh) r.sh = !r.sh;
        if (dv) r.sv = !r.sv;
        r.fh = fh; r.fv = fv; applyXform(r); return true;
      },
      set_frame(path, idx) {
        if (!live()) return false;
        S.frameCalls++;
        // The robot copies raw bytes of frame idx from `path` in the sprite's own
        // pixel format; a PNG file is never a valid frame strip.
        if (/\.png$/i.test(path) || r.bytes !== r.w * r.h * 2) {
          lint('L-FRAME-FMT', r.path + ': set_frame reads raw frames, never a PNG; the kit supports opaque .rgb565 strips only (PC-STRIP): Sprite.new(strip, w, h) + set_frame(strip, idx)');
          return false;
        }
        if (r.fh || r.fv) lint('L-FLIP-FRAME', r.path + ': set_frame on a flipped sprite loads the frame unflipped but keeps the recorded flip; ship pre-flipped frames (KI-FLIP-FRAME)');
        r.sh = false; r.sv = false; applyXform(r);
        const e = spec.sprites[r.path];
        if (e) e.strip = path;
        const frames = r.el.querySelectorAll('[data-pika-frame]');
        if (!frames.length) { lint('L-FRAME', r.path + ': set_frame needs [data-pika-frame] children'); return false; }
        if (idx < 0 || idx >= frames.length) return false;
        frames.forEach((f, i) => { f.style.display = i === idx ? '' : 'none'; });
        return true;
      },
      set_scale(n) {
        if (!live() || !transformable(r, 'set_scale')) return false;
        r.sx = n / 256; applyXform(r); return true;
      },
      set_rotation(d10) {
        if (!live() || !transformable(r, 'set_rotation')) return false;
        r.rot = d10 / 10; applyXform(r); return true;
      },
      set_pivot(px, py) {
        if (!live()) return false;
        r.el.style.transformOrigin = px + 'px ' + py + 'px'; return true;
      },
      hit_test(qx, qy) { return qx >= r.x && qx < r.x + r.w && qy >= r.y && qy < r.y + r.h; },
      intersects(o) {
        const [ox, oy] = o.get_pos(), [ow, oh] = o.get_size();
        return r.x < ox + ow && ox < r.x + r.w && r.y < oy + oh && oy < r.y + r.h;
      },
      destroy() {
        if (!r.alive) return;
        r.alive = false; r.el.remove(); S.sprites.delete(r); S.psram -= r.bytes; ui.dirty = true;
      },
    };
  }

  function fromPath(path, bpp, kind, wIn, hIn) {
    if (typeof path !== 'string' || path.startsWith('/') || path.includes('..')) throw new Error('unsafe path: ' + path);
    if (path.length > L.sandbox_path_max) throw new Error('path too long: ' + path);
    const src = artFor(path);
    let el;
    if (src) el = src.cloneNode(true);
    else { el = document.createElement('img'); el.src = path; lint('L-ART', path + ' is not in <template id="pika-art">; using the image file directly'); }
    const [mw, mh] = src ? measure(el) : [wIn || 0, hIn || 0];
    const w = wIn || mw, h = hIn || mh;
    if (!w || !h) { lint('L-ART', path + ': size unknown; give the element a fixed width/height'); return [null, 'no_size']; }
    return makeSprite(path, el, w, h, bpp, kind);
  }

  const Sprite = {
    image(path) { return fromPath(path, 3, 'image'); },
    new(path, w, h) { return fromPath(path, 2, 'image', w, h); },
    solid(w, h, rgb565) {
      const c = rgb565 & 0xffff;
      const r = ((c >> 11) & 31) * 255 / 31, g = ((c >> 5) & 63) * 255 / 63, b = (c & 31) * 255 / 31;
      const el = document.createElement('div');
      el.style.background = 'rgb(' + Math.round(r) + ',' + Math.round(g) + ',' + Math.round(b) + ')';
      return makeSprite('solid:' + w + 'x' + h, el, w, h, 2, 'solid');
    },
  };

  /* ---------------- Text ---------------- */
  function faceKey(path, size) { return path + '@' + size; }

  /* A glyph the shipped TTF lacks renders as tofu on the robot, but the
   * browser silently falls back. If a char measures differently under two
   * different fallbacks, it did not come from the shipped face. */
  const glyphCache = new Map();
  const probeCtx = document.createElement('canvas').getContext('2d');
  function missingGlyphs(str, fam) {
    const miss = [];
    for (const ch of new Set(Array.from(str))) {
      if (ch <= ' ') continue;
      const k = fam + '|' + ch;
      let ok = glyphCache.get(k);
      if (ok === undefined) {
        probeCtx.font = '32px "' + fam + '", monospace';
        const a = probeCtx.measureText(ch).width;
        probeCtx.font = '32px "' + fam + '", serif';
        ok = a === probeCtx.measureText(ch).width;
        glyphCache.set(k, ok);
      }
      if (!ok) miss.push(ch);
    }
    return miss;
  }

  function textCheck(t) {
    if (!t.alive || t.el.style.display === 'none') return;
    const sc = screenScale();
    const r = t.el.getBoundingClientRect(), s = screen.getBoundingClientRect();
    const x = (r.left - s.left) / sc, y = (r.top - s.top) / sc, w = r.width / sc, h = r.height / sc;
    t.box = [x, y, w, h];
    const rec = spec.texts[t.slot] || (spec.texts[t.slot] = { longest: '', max_w: 0 });
    if (w > rec.max_w) { rec.max_w = Math.ceil(w); rec.longest = t.str; }
    const gk = t.fontPath || '(default)';
    const seen = spec.glyphs[gk] || '';
    let add = '';
    for (const ch of t.str) if (ch > ' ' && !seen.includes(ch) && !add.includes(ch)) add += ch;
    if (add) spec.glyphs[gk] = seen + add;
    if (t.fam && document.fonts.check('16px "' + t.fam + '"')) {
      const miss = missingGlyphs(t.str, t.fam);
      if (miss.length) lint('L-GLYPH', 'font ' + t.fontPath + ' may lack glyphs "' + miss.join('') + '" (confirm with tools/check_spec.py)');
    }
    if (x < 0 || y < 0 || x + w > W || y + h > H) lint('L-TEXT-OVF', '"' + t.str.slice(0, 40) + '" runs off screen (' + Math.round(x + w) + 'px)');
    for (const o of S.texts) {
      if (!o || o === t || !o.box || o.el.style.display === 'none') continue;
      const [ox, oy, ow, oh] = o.box;
      if (x < ox + ow && ox < x + w && y < oy + oh && oy < y + h) {
        const [a, b] = t.slot < o.slot ? [t, o] : [o, t];
        lint('L-TEXT-OVL', 'Text#' + a.slot + ' "' + a.str.slice(0, 20) + '" overlaps Text#' + b.slot + ' "' + b.str.slice(0, 20) + '"');
      }
    }
  }

  function textApi(t) {
    const recheck = () => nativeTimeout(() => textCheck(t), 0);
    return {
      set(str) { if (!t.alive) return; str = String(str); if (str === t.str) return; t.str = str; t.el.textContent = str; recheck(); },
      move(x, y) { if (!t.alive) return; t.el.style.left = x + 'px'; t.el.style.top = y + 'px'; t.align = null; recheck(); },
      align(where, dx, dy) {
        if (!t.alive) return;
        t.align = [where, dx || 0, dy || 0];
        const [w, h] = [t.el.offsetWidth, t.el.offsetHeight];
        const hx = { left: 0, top_left: 0, bottom_left: 0, center: (W - w) / 2, top: (W - w) / 2, bottom: (W - w) / 2, right: W - w, top_right: W - w, bottom_right: W - w };
        const vy = { top: 0, top_left: 0, top_right: 0, center: (H - h) / 2, left: (H - h) / 2, right: (H - h) / 2, bottom: H - h, bottom_left: H - h, bottom_right: H - h };
        if (!(where in hx)) return [null, 'bad_align'];
        t.el.style.left = Math.round(hx[where] + t.align[1]) + 'px';
        t.el.style.top = Math.round(vy[where] + t.align[2]) + 'px';
        recheck();
      },
      set_font(path, size) {
        if (!t.alive) return;
        size = size || L.font_px_default;
        if (size < L.font_px_min || size > L.font_px_max) return [null, 'bad_size'];
        const fam = (man.fonts || {})[path];
        if (!fam) { lint('L-FONT', path + ' is not declared in PIKA_MANIFEST.fonts'); return [null, 'not_found']; }
        const key = faceKey(path, size);
        if (!S.faces.has(key)) {
          if (S.faces.size >= L.font_slots) {
            const free = Array.from(S.faces.entries()).find(([, n]) => n === 0);
            if (!free) { lint('L-FONT', 'all ' + L.font_slots + ' faces (path+size) are in use; ' + key + ' refused'); return [null, 'font_cache_full']; }
            S.faces.delete(free[0]);
          }
          S.faces.set(key, 0);
          spec.fonts[key] = { path, size };
        }
        if (t.face) S.faces.set(t.face, S.faces.get(t.face) - 1);
        t.face = key; S.faces.set(key, S.faces.get(key) + 1);
        t.fam = fam; t.fontPath = path;
        t.el.style.fontFamily = '"' + fam + '"'; t.el.style.fontSize = size + 'px';
        document.fonts.load(size + 'px "' + fam + '"').then(recheck, () => lint('L-FONT', path + ' failed to load'));
        bump(); recheck();
      },
      set_color(rgb) { if (t.alive) t.el.style.color = '#' + (rgb & 0xffffff).toString(16).padStart(6, '0'); },
      show(b) { if (t.alive) { t.el.style.display = b ? '' : 'none'; recheck(); } },
      destroy() {
        if (!t.alive) return;
        t.alive = false; t.el.remove(); S.texts[t.slot] = null;
        if (t.face) S.faces.set(t.face, S.faces.get(t.face) - 1);
        ui.dirty = true;
      },
    };
  }

  const Text = {
    new(str, x, y) {
      const slot = S.texts.indexOf(null);
      if (slot < 0) { lint('L-TEXT', 'Text.new #' + (L.text_slots + 1) + ': pool_full'); return [null, 'pool_full']; }
      const el = document.createElement('div');
      el.style.whiteSpace = 'pre'; el.style.color = '#fff';
      el.style.fontSize = L.font_px_default + 'px'; el.style.lineHeight = '1.2';
      el.style.left = x + 'px'; el.style.top = y + 'px';
      el.textContent = String(str);
      place(el);
      const t = { slot, el, str: String(str), alive: true, face: null, box: null };
      S.texts[slot] = t; bump();
      nativeTimeout(() => { if (t.alive && !t.face) lint('L-FONT', 'Text "' + t.str.slice(0, 20) + '" has no set_font: the robot default font differs from the browser'); textCheck(t); }, 0);
      return [textApi(t)];
    },
  };

  /* ---------------- Anim ---------------- */
  /* Like anim.c: Anim.new stops nothing; one Anim plays at a time; play() stops
   * (and rewinds) the other one and rewinds itself only if it had ended. */
  const Anim = {
    new(path) {
      if (!/\.(gif|mjpe?g)$/i.test(path)) throw new Error('Anim: unsupported extension ' + path);
      const el = document.createElement('img'); el.src = path; el.style.display = 'none';
      el.style.background = '#000';   // the robot's Anim canvas is opaque RGB565, zeroed to black

      place(el);
      const a = { el, playing: false, ended: false, alive: true };
      const api = {
        play() {
          if (!a.alive) return false;
          if (S.anim && S.anim !== api) S.anim.stop();
          if (a.ended) el.src = path;
          S.anim = api; a.playing = true; a.ended = false; el.style.display = ''; return true;
        },
        pause() { a.playing = false; },
        resume() {
          if (!a.alive || a.ended) return;
          if (S.anim && S.anim !== api) S.anim.stop();
          S.anim = api; a.playing = true;
        },
        stop() { a.playing = false; a.ended = true; if (S.anim === api) S.anim = null; el.style.display = 'none'; },
        is_playing() { return a.playing; },
        set_pos(x, y) { el.style.left = x + 'px'; el.style.top = y + 'px'; },
        set_visible(b) { el.style.display = b ? '' : 'none'; },
        destroy() { if (a.alive) { a.alive = false; el.remove(); if (S.anim === api) S.anim = null; } },
      };
      return [api];
    },
  };

  /* ---------------- Speaker ---------------- */
  const sounds = man.sounds || {};
  (function checkSounds() {
    const aliases = Object.keys(sounds);
    if (aliases.length > L.sound_aliases_max) lint('L-SOUND', aliases.length + ' alias > ' + L.sound_aliases_max + ': the robot rejects the WHOLE pack');
    for (const a of aliases) {
      if (a.length > L.sound_alias_len_max - 1) lint('L-SOUND', 'alias "' + a + '" is longer than ' + (L.sound_alias_len_max - 1) + ' chars');
      const p = sounds[a].path || '';
      if (p.length > L.sound_path_len_max - 1) lint('L-SOUND', 'path of "' + a + '" is longer than ' + (L.sound_path_len_max - 1) + ' chars');
      spec.sounds[a] = { path: p, say: sounds[a].say || '', lang: sounds[a].lang || '', file_ok: null, played: 0 };
    }
  })();

  function soundEnd(alias, reason) { S.events.push(['sound_end', alias, reason]); }

  const Speaker = {
    REASON_COMPLETED: 0, REASON_STOPPED: 1, REASON_PREEMPTED: 2, REASON_ERROR: 3,
    play(alias) {
      const def = sounds[alias];
      if (!def) { lint('L-SOUND', 'Speaker.play("' + alias + '") alias is not declared in the manifest'); return false; }
      const t = now();
      if (t - S.sound.lastPlay < L.sound_cooldown_ms) { lint('L-COOLDOWN', 'play within the ' + L.sound_cooldown_ms + ' ms cooldown refused ("' + alias + '")'); return false; }
      S.sound.lastPlay = t;
      if (S.sound.cur) { stopCurrent(); soundEnd(S.sound.cur, Speaker.REASON_PREEMPTED); }
      S.sound.cur = alias; spec.sounds[alias].played++;
      const done = (reason) => { if (S.sound.cur === alias) { S.sound.cur = null; soundEnd(alias, reason); } };
      const tts = () => {
        spec.sounds[alias].file_ok = false;
        lint('L-VOICE', '"' + alias + '" has no recording yet → browser TTS stand-in');
        if (!def.say || !window.speechSynthesis) { nativeTimeout(() => done(Speaker.REASON_COMPLETED), 300); return; }
        const u = new SpeechSynthesisUtterance(def.say);
        if (def.lang) u.lang = def.lang;
        u.onend = () => done(Speaker.REASON_COMPLETED);
        speechSynthesis.speak(u);
      };
      if (!def.path) { tts(); return true; }
      const au = new Audio(def.path);
      S.sound.audio = au;
      au.onended = () => done(Speaker.REASON_COMPLETED);
      au.onerror = () => tts();
      au.play().then(() => { spec.sounds[alias].file_ok = true; }, () => {});
      return true;
    },
    // REASON_STOPPED is queued: on_sound_end runs at the start of the next frame.
    stop(alias) {
      if (S.sound.cur !== alias) return false;
      stopCurrent(); S.sound.cur = null; soundEnd(alias, Speaker.REASON_STOPPED); return true;
    },
    stop_all() { if (S.sound.cur) Speaker.stop(S.sound.cur); return true; },
    set_url(alias, url) {
      const def = sounds[alias];
      if (!def || !(def.remote === true || typeof def.url === 'string')) return false;
      return typeof url === 'string' && /^https?:\/\/[\x21-\x7e]*$/.test(url) && url.length <= L.sound_url_len_max - 1;
    },
    is_playing(alias) { return S.sound.cur === alias; },
    is_busy() { return !!S.sound.cur; },
    set_volume() {}, get_volume() { return 80; },
  };
  function stopCurrent() {
    if (S.sound.audio) { S.sound.audio.onended = null; S.sound.audio.onerror = null; S.sound.audio.pause(); S.sound.audio = null; }
    if (window.speechSynthesis) speechSynthesis.cancel();
  }

  /* ---------------- Led / Servo / Voice ---------------- */
  const ledEl = root.querySelector('#pk-led');
  const inRange = (v, lo, hi) => v >= lo && v <= hi;
  const Led = {
    set(r, g, b) { ledEl.style.background = 'rgb(' + r + ',' + g + ',' + b + ')'; return true; },
    off() { ledEl.style.background = '#000'; return true; },
    preset(name) { log('LED preset ' + name); return true; },
    blink(r, g, b, p) { if (!inRange(p, L.led_blink_min_ms, L.led_blink_max_ms)) { lint('L-LED', 'blink ' + p + 'ms outside [' + L.led_blink_min_ms + ',' + L.led_blink_max_ms + ']: REJECT'); return false; } return Led.set(r, g, b); },
    pulse(r, g, b, d) { if (!inRange(d, L.led_pulse_min_ms, L.led_pulse_max_ms)) { lint('L-LED', 'pulse ' + d + 'ms outside [' + L.led_pulse_min_ms + ',' + L.led_pulse_max_ms + ']: REJECT'); return false; } Led.set(r, g, b); nativeTimeout(Led.off, d); return true; },
    set_brightness(p) { if (!inRange(p, 0, 100)) { lint('L-LED', 'set_brightness ' + p + ' outside [0,100]: returns false'); return false; } return true; },
    // Like bind_led.c: false until the engine runs (top level and game_start).
    get_brightness() { return 100; }, is_available() { return S.phase === 'run'; },
  };
  const servoEl = root.querySelector('#pk-servo');
  const Servo = {
    pose(a) { servoEl.textContent = 'servo: ' + a; log('Servo.pose ' + a); return true; },
    move(a, ang, ms) { servoEl.textContent = 'servo: ' + a + '→' + ang; log('Servo.move ' + a + ' ' + ang + ' ' + ms + 'ms'); return true; },
    stop() { return true; }, is_busy() { return false; },
  };
  /* Like the body board (game_voice.cpp): the session exists only after
   * game_start returns; set_keywords sends the list and starts listening; a
   * second one while active is refused with error/busy; Voice.start only
   * reports no_keywords when idle. Refusals arrive as on_voice_event next frame. */
  let keywords = [];
  function voiceError(code, message) { S.events.push(['voice', { type: 'error', code, message }]); }
  function voiceEarly(name) {
    if (S.phase === 'run') return false;
    lint('L-VOICE-EARLY', name + ' in game_start: dropped on the robot: the voice session starts after game_start returns; send keywords from on_tick');
    return true;
  }
  const Voice = {
    set_keywords(list) {
      if (!Array.isArray(list) || !list.length) return [null, 'keywords_not_array'];
      if (list.length > L.voice_keywords_max) return [null, 'too_many_keywords'];
      if (voiceEarly('Voice.set_keywords')) return true;
      if (S.voice !== 'idle') { voiceError('busy', 'game_voice already active'); return true; }
      keywords = list.slice(); S.voice = 'listening'; log('Voice keywords: ' + list.join(', '));
      return true;
    },
    start() {
      if (voiceEarly('Voice.start')) return true;
      if (S.voice === 'idle') voiceError('no_keywords', 'Voice.set_keywords must precede Voice.start');
      return true;
    },
    stop() { S.voice = 'idle'; return true; },
    is_available() { return S.phase === 'run'; },
  };
  root.querySelector('#pk-say').onclick = () => {
    const kw = root.querySelector('#pk-kw').value.trim();
    if (!kw) return;
    if (keywords.length && !keywords.includes(kw)) log('keyword "' + kw + '" is not in set_keywords');
    S.events.push(['voice', { type: 'VOICE_COMMAND', data: { keyword: kw } }]);
  };

  /* ---------------- Input ---------------- */
  const KEYMAP = { ArrowLeft: 'left', a: 'left', A: 'left', Enter: 'enter', ' ': 'enter', ArrowRight: 'right', d: 'right', D: 'right', h: 'home', H: 'home', Escape: 'home' };
  const actions = Object.keys((man.input && man.input.actions) || { left: 1, enter: 1, right: 1 });
  if (actions.length > L.input_actions_max) lint('L-INPUT', actions.length + ' action > ' + L.input_actions_max);
  const actionMap = (man.input && man.input.actions) || { left: ['button:left'], enter: ['button:enter'], right: ['button:right'] };
  const HW_BUTTONS = ['left', 'enter', 'right'];
  const HOLD_MS_MAX = 65535;   // wire field is u16 (application.cpp ForwardGameInput)
  // Like input.c: one event fans out to every action bound to its button, in manifest order.
  function actionsFor(hw) { return actions.filter((a) => (actionMap[a] || []).includes('button:' + hw)); }
  function buttonsOf(a) { return HW_BUTTONS.filter((hw) => (actionMap[a] || []).includes('button:' + hw)); }
  // phys: the button itself (body board); btn: what the engine has applied from the event queue.
  function btn(hw) { return S.btn[hw] || (S.btn[hw] = { down: false, just: false, justUp: false, hold: 0 }); }
  function phys(hw) { return S.phys[hw] || (S.phys[hw] = { down: false, pressedAt: 0, nextRepeat: 0 }); }
  function hwEvent(hw, down) {
    if (hw === 'home') { if (down) S.events.push(['home']); return; }
    const b = phys(hw);
    if (down === b.down) return;
    const t = now();
    if (down) { b.down = true; b.pressedAt = t; b.nextRepeat = t + L.button_repeat_delay_ms; S.events.push(['input', hw, 0, 0]); }
    else { b.down = false; S.events.push(['input', hw, 1, Math.min(t - b.pressedAt, HOLD_MS_MAX)]); }
  }
  // Like the body board's repeat scan (button.cpp TickGameRepeatTimers): one REPEAT when due, no burst.
  function queueRepeats() {
    const t = now();
    for (const hw of HW_BUTTONS) {
      const b = S.phys[hw];
      if (!b || !b.down || t < b.nextRepeat) continue;
      S.events.push(['input', hw, 2, Math.min(t - b.pressedAt, HOLD_MS_MAX)]);
      // Frames are coarser than the repeat rate: keep the schedule, but never queue a burst.
      b.nextRepeat += L.button_repeat_rate_ms;
      if (b.nextRepeat <= t) b.nextRepeat = t + L.button_repeat_rate_ms;
    }
  }
  window.addEventListener('keydown', (e) => {
    if (e.target && e.target.tagName === 'INPUT') return;
    if (e.key === 'g' || e.key === 'G') { grid.style.display = grid.style.display ? '' : 'block'; return; }
    if (e.key === 'z' || e.key === 'Z') { zoom = zoom === 1 ? 2 : 1; screen.style.transform = 'scale(' + zoom + ')'; screen.parentNode.style.width = W * zoom + 'px'; screen.parentNode.style.height = H * zoom + 'px'; return; }
    if (e.key === 'r' || e.key === 'R') { restart(); return; }
    const hw = KEYMAP[e.key]; if (!hw || e.repeat) return;
    e.preventDefault(); hwEvent(hw, true);
  });
  window.addEventListener('keyup', (e) => { const hw = KEYMAP[e.key]; if (hw) hwEvent(hw, false); });
  root.querySelectorAll('.pk-btns button').forEach((b) => {
    b.onpointerdown = () => { b.classList.add('on'); hwEvent(b.dataset.a, true); };
    b.onpointerup = b.onpointerleave = () => { if (b.classList.contains('on')) { b.classList.remove('on'); hwEvent(b.dataset.a, false); } };
  });
  let zoom = 1;
  function screenScale() { return zoom; }

  const Input = {
    PRESS: 0, RELEASE: 1, REPEAT: 2,
    is_down(a) { return buttonsOf(a).some((hw) => btn(hw).down); },
    just_pressed(a) { return buttonsOf(a).some((hw) => btn(hw).just); },
    just_released(a) { return buttonsOf(a).some((hw) => btn(hw).justUp); },
    // Hold time carried by the last REPEAT/RELEASE, largest across bound buttons (input.c).
    hold_ms(a) { return buttonsOf(a).reduce((m, hw) => Math.max(m, btn(hw).hold), 0); },
    actions() { return actions.slice(); },
  };

  /* ---------------- Engine / loop ---------------- */
  const Timer = { millis: now };
  const Engine = { exit(reason) { if (S.running) { S.running = false; S.exitReason = reason || 'lua'; } } };

  /* on_tick/on_input are bound once before game_start (lua_vm_bind_frame_hooks);
   * the robot keeps calling those functions whatever the globals hold later. */
  const FRAME_HOOKS = ['on_tick', 'on_input'];
  function hook(name) {
    let fn = window[name];
    if (FRAME_HOOKS.includes(name)) {
      if (fn !== S.hooks[name]) lint('L-HOOK-REBIND', name + ' was reassigned after load: robot keeps calling the function defined at load; switch on state inside one ' + name);
      fn = S.hooks[name];
    }
    if (typeof fn !== 'function') return undefined;
    const t = performance.now();
    let ret;
    try { ret = fn.apply(null, Array.prototype.slice.call(arguments, 1)); }
    catch (err) { console.error(err); lint('L-ERROR', name + ': ' + err.message); if (name === 'game_start') Engine.exit('error'); }
    const dt = performance.now() - t;
    if (dt > L.hook_watchdog_ms) lint('L-WDOG', name + ' ran ' + Math.round(dt) + ' ms > watchdog ' + L.hook_watchdog_ms + 'ms');
    return ret;
  }

  function frame() {
    if (!S.running) { teardown(); return; }
    for (const hw in S.btn) { S.btn[hw].just = false; S.btn[hw].justUp = false; }
    queueRepeats();
    const evs = S.events; S.events = [];
    for (const e of evs) {
      if (e[0] === 'input') {
        const [, hw, phase, hold] = e;
        const b = btn(hw);
        if (phase === Input.PRESS) { b.down = true; b.just = true; b.hold = 0; }
        else if (phase === Input.RELEASE) { b.down = false; b.justUp = true; b.hold = hold; }
        else { b.down = true; b.hold = hold; }
        for (const a of actionsFor(hw)) hook('on_input', a, phase, hold);
      } else if (e[0] === 'sound_end') hook('on_sound_end', e[1], e[2]);
      else if (e[0] === 'voice') hook('on_voice_event', e[1]);
      else if (e[0] === 'home') {
        // Lua truthiness: only nil and false end the game (0 and '' keep it running).
        const r = hook('on_home');
        if (r === undefined || r === null || r === false) Engine.exit('home');
      }
    }
    hook('on_tick', TICK_MS);
    for (const r of S.sprites) {
      if (r.pending && now() - r.born > 1000) lint('L-HIDDEN', r.path + ' created but never set_pos/set_visible: invisible on the robot');
    }
    // set_flip/set_frame rewrite pixels (set_frame reads SD) on the robot.
    const t = now();
    if (t - S.frameWindow >= 1000) {
      if (S.frameCalls > 10) lint('L-FRAME', S.frameCalls + ' set_flip/set_frame calls in 1 s: expensive on the robot (O(w*h) / SD read)');
      S.frameCalls = 0; S.frameWindow = t;
    }
    if (ui.dirty) renderPanel();
  }

  function teardown() {
    if (S.torn) return;
    S.torn = true;
    hook('game_end');
    stopCurrent();
    const left = S.sprites.size + S.texts.filter(Boolean).length;
    log('game exit: ' + S.exitReason + (left ? ' (' + left + ' objects left for the engine to free)' : ''));
    const msg = document.createElement('div');
    msg.style.cssText = 'inset:0;width:' + W + 'px;height:' + H + 'px;display:flex;align-items:center;justify-content:center;color:#889;font:14px system-ui';
    msg.textContent = 'exited (' + S.exitReason + ') — press R to restart';
    screen.appendChild(msg);
    renderPanel();
  }

  function renderPanel() {
    ui.dirty = false;
    const p = spec.peak, liveT = S.texts.filter(Boolean).length;
    const row = (k, cur, peak, cap, soft) => {
      const cls = cap && peak > cap ? 'pk-bad' : (soft && peak > soft ? 'pk-warn' : '');
      return '<div class="pk-row ' + cls + '"><span>' + k + '</span><span>' + cur + ' · peak ' + peak + (cap ? ' / ' + cap : '') + '</span></div>';
    };
    root.querySelector('#pk-bud').innerHTML =
      row('Text', liveT, p.texts, L.text_slots, Math.floor(L.text_slots * 0.8)) +
      row('Font face', S.faces.size, p.fonts, L.font_slots) +
      row('Sprite', S.sprites.size, p.sprites, 0) +
      row('PSRAM sprite KB', kb(S.psram), kb(p.psram_bytes), 0, kb(PSRAM_SOFT_WARN)) +
      row('Sound alias', Object.keys(sounds).length, Object.keys(sounds).length, L.sound_aliases_max);
    const box = root.querySelector('#pk-lints');
    box.innerHTML = lints.size ? '' : '<span style="color:#6c8">no violations</span>';
    for (const e of lints.values()) {
      const d = document.createElement('div');
      d.className = BLOCKING.has(e.code) ? 'pk-bad' : 'pk-warn';
      d.textContent = e.code + (e.n > 1 ? ' ×' + e.n : '') + ' — ' + e.msg;
      box.appendChild(d);
    }
  }

  root.querySelector('#pk-export').onclick = () => {
    const out = Object.assign({ schema: 'pika-spec/1', game: man.id || document.title, constraints: C.schema, manifest: man }, spec, { lint: Array.from(lints.values()) });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([JSON.stringify(out, null, 1)], { type: 'application/json' }));
    a.download = 'pika-spec.json'; a.click();
  };

  function loop() {
    let acc = 0, last = performance.now();
    function step(ts) {
      acc += ts - last; last = ts;
      if (acc > 250) acc = TICK_MS;
      while (acc >= TICK_MS) { acc -= TICK_MS; frame(); }
      nativeRaf(step);
    }
    nativeRaf(step);
  }

  function start() {
    newSession();
    const params = { is_a2a: qs.get('a2a') === '1', language: qs.get('lang') || 'vi' };
    for (const n of FRAME_HOOKS) S.hooks[n] = window[n];
    hook('game_start', params);
    S.phase = 'run';
    renderPanel();
  }
  /* The robot builds a fresh Lua VM per run, so every module-level value
   * resets. Page globals would not, so a restart is a reload that carries
   * only the kit's own findings across. */
  const CARRY = 'pika-frame-carry';
  function restart() {
    if (S && S.running) { Engine.exit('restart'); teardown(); }
    try { sessionStorage.setItem(CARRY, JSON.stringify({ spec, lints: Array.from(lints.entries()) })); } catch (e) { /* storage blocked: start clean */ }
    location.reload();
  }
  (function carryIn() {
    let c = null;
    try { c = JSON.parse(sessionStorage.getItem(CARRY) || 'null'); sessionStorage.removeItem(CARRY); } catch (e) { c = null; }
    if (!c) return;
    Object.assign(spec, c.spec);
    for (const [k, v] of c.lints) lints.set(k, v);
  })();

  Object.assign(window, { Sprite, Text, Anim, Speaker, Input, Timer, Engine, Led, Servo, Voice });
  (function checkApi() {
    const real = (window.PIKA_API || {}).globals;
    if (!real) return;
    const kit = { Sprite, Text, Anim, Speaker, Input, Timer, Engine, Led, Servo, Voice };
    for (const g in kit) {
      const r = real[g];
      if (!r) { lint('L-API', 'kit exposes ' + g + ', which the engine does not register'); continue; }
      const known = new Set([].concat(r.functions, r.constants));
      for (const k in kit[g]) if (!known.has(k)) lint('L-API', 'kit exposes ' + g + '.' + k + ', which the engine does not register');
    }
    const objects = { Sprite: spriteApi({}), Text: textApi({}) };
    for (const g in objects) {
      const methods = new Set((real[g] || {}).methods || []);
      for (const k in objects[g]) if (!methods.has(k)) lint('L-API', 'kit exposes ' + g + ':' + k + ', which the engine does not register');
    }
  })();
  // Test hook for scripted playthroughs (headless or by an agent).
  window.__pika = {
    press(a, ms) { hwEvent(a, true); nativeTimeout(() => hwEvent(a, false), ms || 80); },
    voice(kw) { S.events.push(['voice', { type: 'VOICE_COMMAND', data: { keyword: kw } }]); },
    lints() { return Array.from(lints.values()); },
    spec() { return JSON.parse(JSON.stringify(spec)); },
    restart,
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { start(); loop(); });
  else { start(); loop(); }
})();
