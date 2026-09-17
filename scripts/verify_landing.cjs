// Run with Node 22+; uses installed Chrome and no npm dependencies.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const htmlPath = path.resolve(__dirname, '../landing.html');
const html = fs.readFileSync(htmlPath, 'utf8');
new (require('node:vm').Script)(html.match(/<script>([\s\S]*?)<\/script>/)[1]);
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
assert.equal(new Set(ids).size, ids.length);
for (const m of html.matchAll(/href="#([^"]+)"/g)) assert(ids.includes(m[1]));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'inksmith-ui-'));
const chrome = process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const child = spawn(chrome, ['--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
let launchError;
child.on('error', error => { launchError = error; });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let ws;
(async () => {
  const portFile = path.join(profile, 'DevToolsActivePort');
  for (let i = 0; !fs.existsSync(portFile) && i < 100; i++) { if (launchError) throw launchError; await sleep(100); }
  const port = fs.readFileSync(portFile, 'utf8').split('\n')[0];
  const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws = new WebSocket(tabs.find(tab => tab.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let sequence = 0;
  const pending = new Map();
  const errors = [];
  ws.onmessage = event => {
    const response = JSON.parse(event.data);
    if (response.method === 'Runtime.exceptionThrown') errors.push(response.params.exceptionDetails.text);
    if (response.id && pending.has(response.id)) {
      const callback = pending.get(response.id); pending.delete(response.id);
      if (response.error) callback.reject(Error(JSON.stringify(response.error))); else callback.resolve(response.result);
    }
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence; pending.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const response = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (response.exceptionDetails) throw Error(JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Page.navigate', { url: pathToFileURL(htmlPath).href });
  for (let i = 0; i < 100; i++) {
    if (await evaluate("document.getElementById('feature-count')?.textContent.includes('12 / 12')")) break;
    await sleep(50);
  }
  await evaluate("window.$ = id => document.getElementById(id)");
  assert.equal(await evaluate("document.querySelectorAll('#feature-catalog .card').length"), 12);
  const original = await evaluate("$('draft').value");
  await evaluate("$('pipeline-run').click()");
  assert.equal(await evaluate("$('pipeline-run').disabled"), true);
  await sleep(650);
  assert((await evaluate("$('pipeline-progress').value")) > 0);
  await evaluate("$('pipeline-stop').click()");
  const stopped = await evaluate("$('pipeline-progress').value");
  await sleep(600);
  assert.equal(await evaluate("$('pipeline-progress').value"), stopped);
  assert.equal(await evaluate("$('draft').value"), original);
  const lengths = [];
  for (const quality of ['quick', 'standard', 'polished']) {
    await evaluate(`$('pipeline-quality').value = '${quality}'; $('pipeline-run').click()`);
    for (let i = 0; i < 100 && await evaluate("$('pipeline-run').disabled"); i++) await sleep(100);
    assert.equal(await evaluate("$('pipeline-progress').value"), 5);
    assert.equal(await evaluate("document.querySelectorAll('#pipeline-log li').length"), 5);
    lengths.push(await evaluate("$('pipeline-result').textContent.length"));
  }
  assert(lengths[0] < lengths[1] && lengths[1] < lengths[2]);
  await evaluate("$('pipeline-append').click()");
  assert((await evaluate("$('draft').value")).startsWith(original));
  assert.equal(await evaluate("localStorage.getItem('novel-writer-landing-draft-v1') === $('draft').value"), true);
  assert.equal(await evaluate("$('pipeline-append').disabled"), true);
  await evaluate("$('feature-search').value = 'EPUB'; $('feature-search').dispatchEvent(new Event('input'))");
  assert.equal(await evaluate("document.querySelectorAll('#feature-catalog .card:not([hidden])').length"), 1);
  await evaluate("$('feature-search').value = 'NO_MATCH_XYZ'; $('feature-search').dispatchEvent(new Event('input'))");
  assert.equal(await evaluate("$('feature-empty').hidden"), false);
  await evaluate("$('feature-search').value = ''; $('feature-search').dispatchEvent(new Event('input'))");
  await evaluate("$('pipeline-route').value = 'cloud'; $('pipeline-route').dispatchEvent(new Event('change'))");
  assert.equal(await evaluate("$('route-note').textContent.includes('不发送任何请求')"), true);
  await evaluate("$('pipeline-name').value = '   '; $('pipeline-run').click()");
  assert.equal(await evaluate("$('pipeline-run').disabled"), false);
  assert.equal(await evaluate("$('pipeline-status').textContent.includes('不能只有空白')"), true);
  await evaluate("$('pipeline-name').value = '林深'");
  for (const width of [1440, 768, 390, 320]) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: width < 600 });
    assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true, `Overflow at ${width}px`);
    assert.equal(await evaluate("$('pipeline-run').getBoundingClientRect().width > 0"), true);
  }
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.glow')).animationName"), 'none');
  const saved = await evaluate("$('draft').value");
  await send('Page.reload');
  for (let i = 0; i < 100; i++) {
    if (await evaluate(`document.getElementById('draft')?.value === ${JSON.stringify(saved)}`)) break;
    await sleep(50);
  }
  assert.equal(await evaluate("document.getElementById('draft').value"), saved);
  assert.deepEqual(errors, [], 'Browser runtime errors');
  console.log('PASS: syntax, unique IDs, anchor targets, 12 feature groups, generate/progress/stop/restart, three presets, append/save/restore, search/empty state, route note, whitespace validation, 320-1440px layouts, reduced motion, no browser exceptions.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (ws) ws.close();
  child.kill();
  await sleep(500);
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Chrome may still hold temporary files. */ }
});
