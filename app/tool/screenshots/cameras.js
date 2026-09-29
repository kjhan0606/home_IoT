// Camera screens against a hub in demo mode (two example cameras, pictures drawn by the hub).
const { chromium } = require('playwright-core');
const OUT = process.env.OUT || '/workspace/screenshots';
(async () => {
  const b = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const p = await (await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'ko-KR' })).newPage();
  const wait = (ms = 1500) => p.waitForTimeout(ms);
  await p.goto('http://localhost:8088/', { waitUntil: 'networkidle' });
  await wait(4000);
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await wait(500);
  await p.getByRole('button', { name: /^홈 허브$/ }).first().click();
  await wait(1000);
  await p.getByRole('button', { name: /허브 찾기/ }).first().click();
  await wait(1500);
  await p.getByRole('button', { name: /^연결$/ }).first().click();
  await wait(3000);
  await p.screenshot({ path: `${OUT}/cam-01-list.png` });
  await p.getByRole('button', { name: /거실 카메라/ }).first().click();
  await wait(2500);
  await p.screenshot({ path: `${OUT}/cam-02-view.png` });
  await p.getByRole('button', { name: /오른쪽/ }).first().click().catch(() => console.log('no ptz-right label'));
  await wait(2500);
  await p.screenshot({ path: `${OUT}/cam-03-ptz.png` });
  await b.close();
})();
