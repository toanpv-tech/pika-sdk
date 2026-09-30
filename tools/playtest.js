/* Scripted playthrough of a pika-frame demo in headless Chromium.
 *
 * usage: node playtest.js <demo.html> [steps] [--out <dir>]
 *   steps: comma list run in order, e.g. "wait:800,right,enter,wait:1500,voice:jump,home"
 *          left|right|enter|home = press, wait:<ms>, voice:<keyword>, restart
 * writes <out>/pika-spec.json and <out>/shot.png (default out = demo folder),
 * prints lints + JS errors; exit 1 on any JS error.
 *
 * One-time setup: `npm install && npx playwright install chromium` in tools/.
 */
'use strict';
const path = require('path');
const fs = require('fs');
const { pathToFileURL } = require('url');
const { chromium } = require('playwright');

(async () => {
  const args = process.argv.slice(2);
  const oi = args.indexOf('--out');
  const out = oi >= 0 ? path.resolve(args.splice(oi, 2)[1]) : null;
  const demo = path.resolve(args[0] || '');
  if (!args[0] || !fs.existsSync(demo)) { console.error('usage: node playtest.js <demo.html> [steps] [--out dir]'); process.exit(2); }
  const steps = (args[1] || 'wait:1000').split(',').map((s) => s.trim()).filter(Boolean);
  const outDir = out || path.dirname(demo);

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/ERR_FILE_NOT_FOUND/.test(m.text())) errors.push(m.text()); });
  await page.goto(pathToFileURL(demo).href);
  await page.waitForTimeout(500);

  for (const s of steps) {
    const [k, v] = s.split(':');
    if (k === 'wait') await page.waitForTimeout(Number(v) || 0);
    else if (k === 'voice') await page.evaluate((kw) => window.__pika.voice(kw), v);
    else if (k === 'restart') {
      await Promise.all([page.waitForEvent('load'), page.evaluate(() => window.__pika.restart())]);
      await page.waitForTimeout(300);
    }
    else { await page.evaluate((a) => window.__pika.press(a), k); await page.waitForTimeout(200); }
  }
  await page.waitForTimeout(300);

  const res = await page.evaluate(() => ({
    manifest: window.PIKA_MANIFEST || {}, lints: window.__pika.lints(), spec: window.__pika.spec(),
  }));
  const spec = Object.assign({ schema: 'pika-spec/1', game: res.manifest.id || path.basename(demo), manifest: res.manifest },
    res.spec, { lint: res.lints });
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'pika-spec.json'), JSON.stringify(spec, null, 1));
  await page.locator('#pk-screen').screenshot({ path: path.join(outDir, 'shot.png') });
  await browser.close();

  for (const l of res.lints) console.log(l.code + (l.n > 1 ? ' x' + l.n : '') + '  ' + l.msg);
  for (const e of errors) console.log('JS-ERROR  ' + e);
  console.log('peak: ' + JSON.stringify(spec.peak) + '\nwrote ' + path.join(outDir, 'pika-spec.json'));
  process.exit(errors.length ? 1 : 0);
})();
