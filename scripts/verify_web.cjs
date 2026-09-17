// Run with Node 22+; uses installed Chrome and no npm dependencies.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const htmlPath = path.resolve(__dirname, '../web/index.html');
const html = fs.readFileSync(htmlPath, 'utf8');
for (const file of ['app.js','ai.js']) new (require('node:vm').Script)(fs.readFileSync(path.join(path.dirname(htmlPath),file),'utf8'));
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
  const wait = async expression => { for(let i=0;i<100;i++){if(await evaluate(expression))return;await sleep(50);}throw Error('Timeout: '+expression); };
  await wait("typeof document.getElementById('new-book')?.onclick === 'function'");
  await evaluate("window.$=id=>document.getElementById(id); window.fill=(id,v)=>{$(id).value=v;$(id).dispatchEvent(new Event('input',{bubbles:true}));}");
  const act = async expression => { await evaluate(expression); await sleep(80); };
  const stored = () => evaluate("JSON.parse(localStorage.getItem('inksmith.web.v1'))");
  assert.equal(await evaluate("$('library-empty').hidden"),false);
  await act("$('new-book').click(); $('modal-cancel').click()");
  assert.equal(await evaluate("document.querySelectorAll('.book-card').length"),0);
  await act("$('new-book').click(); document.querySelector('#modal-fields [name=title]').value='   '; $('modal-form').requestSubmit()");
  assert.equal(await evaluate("document.querySelectorAll('.book-card').length"),0);
  await act("if($('form-dialog').open)$('modal-cancel').click(); $('new-book').click(); document.querySelector('#modal-fields [name=title]').value='验收小说'; $('modal-form').requestSubmit()");
  assert.equal((await stored()).books[0].title,'验收小说');
  await act(`$('new-chapter').click(); fill('chapter-title','第一章'); fill('content',${JSON.stringify('测试正文\n第二段')}); fill('chapter-outline','寻找来信')`);
  await sleep(650);
  assert.equal((await stored()).books[0].chapters[0].content,'测试正文\n第二段');
  await act("$('new-entity').click(); document.querySelector('#modal-fields [name=name]').value='林深'; $('modal-form').requestSubmit()");
  assert.equal((await stored()).books[0].characters[0].name,'林深');
  await act("document.querySelector('#entity-list button').click()");
  assert.equal(await evaluate("document.querySelector('#modal-fields [name=name]').value"),'林深');
  await act("document.querySelector('#modal-fields [name=traits]').value='冷静'; $('modal-form').requestSubmit()");
  await act("document.querySelector('[data-panel=worldSettings]').click(); $('new-entity').click(); document.querySelector('#modal-fields [name=title]').value='旧书店'; $('modal-form').requestSubmit()");
  assert.equal((await stored()).books[0].worldSettings[0].title,'旧书店');
  await act("$('new-chapter').click(); fill('content','第二章内容'); $('chapter-up').click()");
  assert.equal((await stored()).books[0].chapters[0].content,'第二章内容');
  await act("window.confirm=()=>false; $('delete-chapter').click()");
  assert.equal((await stored()).books[0].chapters.length,2);
  await act("window.confirm=()=>true; $('delete-chapter').click()");
  assert.equal((await stored()).books[0].chapters.length,1);
  await act("$('find-toggle').click(); fill('find-text','测试'); fill('replace-text','正式'); $('replace-all').click()");
  await sleep(650);
  assert.equal((await stored()).books[0].chapters[0].content,'正式正文\n第二段');
  await send('Page.reload');
  await wait("document.getElementById('content')?.value === '正式正文\\n第二段'");
  await evaluate("window.$=id=>document.getElementById(id)");
  await act("$('read-book').click()");
  assert((await evaluate("$('view-body').textContent")).includes('正式正文'));
  await act("$('view-close').click(); $('back-library').click()");
  assert.equal(await evaluate("document.querySelectorAll('.book-card').length"),1);
  await act("document.querySelectorAll('.book-card button')[1].click(); document.querySelector('#modal-fields [name=archived]').checked=true; $('modal-form').requestSubmit()");
  await act("$('book-filter').value='active'; $('book-filter').dispatchEvent(new Event('change'))");
  assert.equal(await evaluate("document.querySelectorAll('.book-card').length"),0);
  await act("$('book-filter').value='all'; $('book-filter').dispatchEvent(new Event('change')); document.querySelector('.book-card button').click()");
  // AI_CHECKS
  for(const width of [1440,768,390,320]){
    await send('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:width<600});
    assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'),true,`Overflow at ${width}`);
  }
  assert.deepEqual(errors,[]);
  console.log('PASS: empty shelf, create/cancel/whitespace, chapter edit/save/reload/order/delete confirmation, characters CRUD editing, world settings, find/replace, reader, archive filter, responsive layouts, no runtime exceptions.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (ws) ws.close();
  child.kill();
  await sleep(500);
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Chrome may still hold temporary files. */ }
});
