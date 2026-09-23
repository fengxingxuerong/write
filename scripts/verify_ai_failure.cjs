// Standalone HTTP 401 UI regression. Node 22+ and installed Chrome; no packages.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../web');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let server, browser, socket, profile;
let requests = 0;
const errors = [];
const pending = new Map();
async function main() {
  // Serve only three known application files; never read project data or keys.
  server = http.createServer((req, res) => {
    if (req.url === '/v1/chat/completions' && req.method === 'POST') {
      requests++;
      req.resume();
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'TEST_ONLY_INVALID_KEY' } }));
      return;
    }
    const files = { '/': ['index.html', 'text/html'], '/app.js': ['app.js', 'text/javascript'], '/ai.js': ['ai.js', 'text/javascript'] };
    const file = files[req.url];
    if (!file) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': file[1] + ';charset=utf-8' });
    res.end(fs.readFileSync(path.join(root, file[0])));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const appUrl = `http://127.0.0.1:${server.address().port}`;
  profile = fs.mkdtempSync(path.join(os.tmpdir(), 'inksmith-401-'));
  const chrome = process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  browser = spawn(chrome, ['--headless', '--disable-gpu', '--no-sandbox', '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  let launchError;
  browser.on('error', error => { launchError = error; });
  const portFile = path.join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !fs.existsSync(portFile); i++) { if (launchError) throw launchError; await sleep(50); }
  if (!fs.existsSync(portFile)) throw Error(`Chrome did not create DevToolsActivePort (chrome=${chrome}${launchError ? `, launchError=${launchError.message}` : ''}). Is the binary present and runnable?`);
  const debugPort = fs.readFileSync(portFile, 'utf8').split('\n')[0];
  const pages = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`, { signal: AbortSignal.timeout(4000) })).json();
  socket = new WebSocket(pages.find(p => p.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { const timer = setTimeout(() => reject(Error('WebSocket timeout')), 5000); socket.onopen = () => { clearTimeout(timer); resolve(); }; socket.onerror = () => { clearTimeout(timer); reject(Error('WebSocket error')); }; });
  let serial = 0;
  socket.onmessage = event => {
    const msg = JSON.parse(event.data);
    if (msg.method === 'Runtime.exceptionThrown') errors.push(msg.params.exceptionDetails.text);
    const entry = pending.get(msg.id);
    if (!entry) return;
    clearTimeout(entry.timer); pending.delete(msg.id);
    if (msg.error) entry.reject(Error(JSON.stringify(msg.error))); else entry.resolve(msg.result);
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { pending.delete(id); reject(Error('CDP timeout: ' + method)); }, 5000);
    pending.set(id, { resolve, reject, timer }); socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const response = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (response.exceptionDetails) throw Error(JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  const wait = async expression => {
    for (let i = 0; i < 100; i++) { if (await evaluate(expression)) return; await sleep(50); }
    throw Error('Condition not reached: ' + expression);
  };
  await send('Runtime.enable');
  await send('Page.navigate', { url: appUrl });
  await wait("typeof document.getElementById('open-ai')?.onclick === 'function'");
  await evaluate(`(() => {
    const el = id => document.getElementById(id);
    el('open-ai').click();
    el('ai-provider').value = 'openai';
    el('ai-url').value = ${JSON.stringify(appUrl)};
    el('ai-model').value = 'test-only-model';
    el('ai-key').value = 'test-only-invalid-key';
    el('test-ai').click();
  })()`);
  await wait("document.getElementById('connection-status').textContent.includes('401')");
  const result = await evaluate(`(() => {
    const status = document.getElementById('connection-status');
    return { text: status.textContent, visible: status.getClientRects().length > 0 && getComputedStyle(status).visibility !== 'hidden', open: document.getElementById('ai-dialog').open, retryEnabled: !document.getElementById('test-ai').disabled };
  })()`);
  assert.equal(requests, 1);
  assert.equal(result.visible && result.open && result.retryEnabled, true);
  assert.match(result.text, /401/);
  assert.equal(result.text.includes('TEST_ONLY_INVALID_KEY'), false, 'Do not expose raw provider response');
  assert.deepEqual(errors, []);
  console.log('PASS: one local HTTP 401 request; visible failure in open model dialog; retry enabled; no runtime exceptions.');
  console.log('Visible message:', result.text);
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  for (const entry of pending.values()) clearTimeout(entry.timer);
  if (socket) socket.close();
  if (browser) browser.kill();
  if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  await sleep(300);
  if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Chrome may temporarily hold its isolated profile. */ } }
});
