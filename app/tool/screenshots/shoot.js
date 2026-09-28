const { chromium } = require('playwright-core');
const OUT = '/workspace/screenshots';
(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const scheme = process.env.SCHEME || 'light';
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: scheme, locale: 'ko-KR' });
  const page = await ctx.newPage();
  page.on('console', m => { if (m.type() === 'error') console.log('console:', m.text()); });
  const settle = (ms = 1500) => page.waitForTimeout(ms);
  const shot = async (name, h) => {
    if (h) await page.setViewportSize({ width: 390, height: h });
    await settle(1200);
    await page.screenshot({ path: `${OUT}/${name}.png` });
    console.log('saved', name);
    if (h) await page.setViewportSize({ width: 390, height: 844 });
  };
  const semantics = async () => {
    await page.evaluate(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); });
    await settle(500);
  };
  const click = async (re) => { await page.getByRole('button', { name: re }).first().click(); await settle(); };
  const clickRole = async (role, re) => { await page.getByRole(role, { name: re }).first().click(); await settle(); };
  const back = async () => { await page.mouse.click(24, 28); await settle(); };

  await page.goto('http://localhost:8088/', { waitUntil: 'networkidle' });
  await settle(4000);
  await semantics();
  if (process.env.ONLY_DARK) {
    await clickRole('button', /^연결$/);
    await settle(2500);
    await shot(`01-device-list-dark`);
    await browser.close();
    return;
  }
  await shot('00-connect');
  await clickRole('button', /^연결$/);
  await settle(2500);
  await shot('01-device-list');

  await click(/거실 TV/); await shot('02-tv-remote', 1000); await back();
  await click(/세탁기 \(예시\)/); await shot('03-washer'); await back();
  await click(/냉장고 \(예시\)/); await shot('04-fridge'); await back();
  await click(/로봇청소기 \(예시\)/); await shot('05-vacuum', 1500);
  await clickRole('button', /지도 열기/);
  await settle(2500);
  // tap two rooms on the map canvas: image px -> screen px via the canvas box
  const mb = await page.evaluate(() => {
    const n = [...document.querySelectorAll('flt-semantics')].find(e => (e.getAttribute('aria-label') || e.innerText || '').trim() === '청소 지도');
    const r = n.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height };
  });
  console.log('map box', mb);
  const s = mb.width / 600;
  await page.mouse.click(mb.x + 120 * s, mb.y + 150 * s); await settle(700);  // 거실
  await page.mouse.click(mb.x + 450 * s, mb.y + 450 * s); await settle(700);  // 침실
  await clickRole('button', /^2회$/);
  await shot('06-vacuum-map-room-selected');
  await back(); await back();
  await clickRole('button', /설정/); await settle(2000);
  await shot('07-settings', 1500);
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
