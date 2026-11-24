// Click-through of the room editor at 360x700 with touch: library filter, open a room, paint,
// undo, place a prop and edit its field, next room in the filter, room sheet, back, sync and
// settings screens, autosave. Screenshots go to the folder given as argument (default: tmp).
let chromium;
try { chromium = require('playwright').chromium; } catch (e) { console.log('warning: playwright not installed, flow test skipped'); process.exit(0); }
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '../../tools/room_editor_web');
const OUT = process.argv[2] || require('os').tmpdir();
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 360, height: 700 }, hasTouch: true, isMobile: true, deviceScaleFactor: 1 });
  const p = await ctx.newPage();
  const errs = [];
  p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  p.on('pageerror', e => errs.push(String(e)));
  await p.route('http://editor.test/**', route => {
    const rel = new URL(route.request().url()).pathname.slice(1) || 'index.html';
    const file = path.join(ROOT, rel);
    if (!fs.existsSync(file)) return route.fulfill({ status: 404, body: '' });
    route.fulfill({ status: 200, contentType: /\.js$/.test(file) ? 'text/javascript' : /\.css$/.test(file) ? 'text/css' : 'text/html', body: fs.readFileSync(file) });
  });
  await p.goto('http://editor.test/index.html');
  await p.waitForTimeout(500);
  // make 30 rooms in two biomes
  await p.evaluate(() => {
    const L = App.state.level;
    for (let i = 0; i < 30; i++) {
      const r = RoomModel.addRoom(L, 'r' + i, 1 + (i % 2), 1);
      RoomModel.setBiome(r, i % 3 ? 'forest' : 'grotto');
      if (i % 5 === 0) RoomModel.setType(r, 'shop');
      RoomModel.toggleExit(L, r, 1, 10, false);
    }
    App.changed(null);
    App.show('library');
  });
  await p.waitForTimeout(300);
  await p.screenshot({ path: OUT + '/lib.png' });
  // filter by grotto then open first card
  await p.locator('button.chip', { hasText: 'grotto' }).first().tap();
  const cards = await p.locator('.card').count();
  await p.locator('.card').first().tap();
  await p.waitForTimeout(300);
  const before = await p.evaluate(() => ({ id: App.room().id, cur: App.current }));
  // paint a stroke with one finger: dispatch pointer events
  const box = await p.locator('canvas.room').boundingBox();
  const stroke = async (pts) => {
    await p.evaluate(({ pts, box }) => {
      const c = document.querySelector('canvas.room');
      const ev = (type, x, y) => c.dispatchEvent(new PointerEvent(type, { pointerId: 1, clientX: box.x + x, clientY: box.y + y, bubbles: true, pointerType: 'touch' }));
      ev('pointerdown', pts[0][0], pts[0][1]);
      for (const q of pts.slice(1)) ev('pointermove', q[0], q[1]);
      ev('pointerup', pts[pts.length - 1][0], pts[pts.length - 1][1]);
    }, { pts, box });
  };
  const textBefore = await p.evaluate(() => RoomModel.toText(App.state.level));
  const cy = box.height / 2;
  await stroke([[80, cy], [120, cy], [200, cy + 20]]);
  const changed = await p.evaluate((t) => RoomModel.toText(App.state.level) !== t, textBefore);
  await p.locator('button', { hasText: 'Undo' }).tap();
  const undone = await p.evaluate((t) => RoomModel.toText(App.state.level) === t, textBefore);
  // place a prop
  await p.locator('button.tool', { hasText: 'Prop' }).tap();
  await p.waitForTimeout(200);
  await p.locator('button.prop-pick', { hasText: 'Crate' }).first().tap();
  await stroke([[150, cy]]);
  const props = await p.evaluate(() => (App.room().props || []).length);
  await p.locator('button', { hasText: 'Edit' }).tap();
  await p.waitForTimeout(200);
  await p.screenshot({ path: OUT + '/propsheet.png' });
  await p.locator('.sheet button', { hasText: '+' }).first().tap();
  const fieldSet = await p.evaluate(() => JSON.stringify(App.room().props[0].fields));
  await p.evaluate(() => window.onAndroidBack());
  // next room within filter
  await p.locator('button.nav[aria-label="Next room"]').tap();
  const after = await p.evaluate(() => ({ id: App.room().id, biome: RoomModel.getBiome(App.room()) }));
  await p.screenshot({ path: OUT + '/editor.png' });
  await p.locator('#screen-editor button.title').tap();
  await p.waitForTimeout(200);
  await p.screenshot({ path: OUT + '/roomsheet.png' });
  await p.evaluate(() => window.onAndroidBack());
  await p.evaluate(() => window.onAndroidBack());
  const backTo = await p.evaluate(() => App.current);
  await p.evaluate(() => App.show('sync'));
  await p.screenshot({ path: OUT + '/sync.png' });
  await p.evaluate(() => App.show('settings'));
  await p.screenshot({ path: OUT + '/settings.png' });
  await p.waitForTimeout(1300);
  const saved = await p.evaluate(() => (localStorage.getItem('roomeditor.project.rooms.lvl') || '').length);
  const r = { cards, before, changed, undone, props, fieldSet, after, backTo, saved, errs };
  console.log(JSON.stringify(r));
  const ok = cards === 10 && changed && undone && props === 1 && fieldSet === '{"health":2}' &&
    after.biome === 'grotto' && after.id !== before.id && backTo === 'library' && saved > 0 && errs.length === 0;
  console.log(ok ? 'OK: flow' : 'FAILED: flow');
  if (!ok) process.exitCode = 1;
  await b.close();
})();
