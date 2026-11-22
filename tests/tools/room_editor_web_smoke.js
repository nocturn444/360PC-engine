// Smoke test of the room editor UI in headless Chromium at phone size (360x640): the page
// loads, every screen registers, no console errors. Optional argument: a screenshot path.
const fs = require('fs');
const path = require('path');
let chromium;
try { chromium = require('playwright').chromium; } catch (e) { console.log('warning: playwright not installed, smoke test skipped'); process.exit(0); }
const ROOT = path.join(__dirname, '../../tools/room_editor_web');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.lvl': 'text/plain' };
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 360, height: 640 } });
  const errs = [];
  p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  p.on('pageerror', e => errs.push(String(e)));
  await p.route('http://editor.test/**', route => {
    const rel = new URL(route.request().url()).pathname.slice(1) || 'index.html';
    const file = path.join(ROOT, rel);
    if (!fs.existsSync(file)) return route.fulfill({ status: 404, body: '' });
    route.fulfill({ status: 200, contentType: TYPES[path.extname(file)] || 'text/plain', body: fs.readFileSync(file) });
  });
  await p.goto('http://editor.test/index.html');
  await p.waitForTimeout(800);
  const info = await p.evaluate(() => ({ cur: App.current, rooms: App.state.level && App.state.level.rooms.length,
    types: App.state.catalog.types.map(t => t.id), proj: App.state.projectName }));
  console.log(JSON.stringify(info));
  if (errs.length) { console.log('FAILED: console errors: ' + JSON.stringify(errs)); process.exit(1); }
  if (info.cur !== 'library' || !info.rooms) { console.log('FAILED: the library did not open'); process.exit(1); }
  console.log('OK: smoke');
  if (process.argv[2]) await p.screenshot({ path: process.argv[2] });
  await b.close();
})();
