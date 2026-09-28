// E2E live-update check: app open in the browser, a command is sent to the hub by
// someone else (curl); the app must reflect it via /ws without any user action.
const { chromium } = require('playwright-core');
const { execSync } = require('child_process');
(async () => {
  const b = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const p = await (await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 })).newPage();
  await p.goto('http://localhost:8088/', { waitUntil: 'networkidle' });
  await p.waitForTimeout(4000);
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await p.waitForTimeout(500);
  await p.getByRole('button', { name: /^연결$/ }).first().click().catch(() => {});
  await p.waitForTimeout(3000);
  const lockText = async () => (await p.getByRole('button', { name: /현관 도어락/ }).first().innerText()).replace(/\s+/g, ' ');
  console.log('before:', await lockText());
  execSync(`curl -s -X POST localhost:8099/devices/demo:lock/commands -H 'Content-Type: application/json' -d '{"capability":"lock","action":"unlock"}'`);
  await p.waitForTimeout(1500);
  console.log('after :', await lockText());
  execSync(`curl -s -X POST localhost:8099/devices/demo:lock/commands -H 'Content-Type: application/json' -d '{"capability":"lock","action":"lock"}'`);
  await b.close();
})();
