// Run with Node 22+; uses installed Chrome and no npm dependencies.
// 关系引导图（web/relations.html）冒烟验证：语法 / 唯一 id / 工作台自动播种 /
// 节点与连线增删 / 刷新恢复 / 类型过滤 / 自动布局 / 响应式无溢出 / 无运行时异常。
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const htmlPath = path.resolve(__dirname, '../web/relations.html');
const html = fs.readFileSync(htmlPath, 'utf8');
new (require('node:vm').Script)(html.match(/<script>([\s\S]*?)<\/script>/)[1]);
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
assert.equal(new Set(ids).size, ids.length, 'ids must be unique');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'inksmith-ui-'));
const chrome = process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const child = spawn(chrome, ['--headless', '--disable-gpu', '--no-sandbox', '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
let launchError;
child.on('error', error => { launchError = error; });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let ws;
(async () => {
  const portFile = path.join(profile, 'DevToolsActivePort');
  for (let i = 0; !fs.existsSync(portFile) && i < 300; i++) { if (launchError) throw launchError; await sleep(100); }
  if (!fs.existsSync(portFile)) throw Error(`Chrome did not create DevToolsActivePort (chrome=${chrome}${launchError ? `, launchError=${launchError.message}` : ''}). Is the binary present and runnable?`);
  const port = fs.readFileSync(portFile, 'utf8').split('\n')[0];
  let tabs;
  for (let i = 0; ; i++) {
    try { tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); break; }
    catch (e) { if (i >= 20) throw e; await sleep(250); }
  }
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
  const wait = async expression => { for (let i = 0; i < 120; i++) { if (await evaluate(expression)) return; await sleep(50); } throw Error('Timeout: ' + expression); };
  const act = async expression => { const value = await evaluate(expression); await sleep(60); return value; };
  await send('Runtime.enable');
  await send('Page.enable');
  const base = pathToFileURL(htmlPath).href;
  await send('Page.navigate', { url: base });
  await wait("document.getElementById('canvas') !== null");
  // 造一个工作台作品（与 app.js 的 inksmith.web.v1 同构），随后带 ?book= 进入触发自动播种。
  await act(`localStorage.setItem('inksmith.web.v1', JSON.stringify({ books: [{
    id: 'b1', title: '测试书', genre: '玄幻', tone: '', archived: false,
    createdAt: '2026-10-17T00:00:00.000Z', updatedAt: '2026-10-17T00:00:00.000Z',
    chapters: [{ id: 'c1', novelId: 'b1', order: 0, createdAt: '2026-10-17T00:00:00.000Z', updatedAt: '2026-10-17T00:00:00.000Z', title: '第一章 觉醒', content: '正文', outline: '林深觉醒剑魂' }],
    characters: [
      { id: 'x1', novelId: 'b1', name: '林深', role: '男主', traits: '坚韧', background: '', relationships: '与苏晚是恋人；与黑袍使是宿敌', dialogueStyle: '' },
      { id: 'x2', novelId: 'b1', name: '苏晚', role: '女主', traits: '', background: '', relationships: '与林深是恋人', dialogueStyle: '' }
    ],
    worldSettings: [
      { id: 'w1', novelId: 'b1', title: '古剑来历', category: '伏笔', content: '剑上刻字无人能认' },
      { id: 'w2', novelId: 'b1', title: '黑袍使', category: '势力', content: '反派组织首领' }
    ]
  }] })); true`);
  await send('Page.navigate', { url: base + '?book=b1' });
  await wait("document.querySelectorAll('.node').length > 0");
  // 自动播种：2 角色 + 1 伏笔 + 2 情节（势力设定 + 章节大纲）+ 2 条关系文本连线
  assert.equal(await evaluate("document.querySelectorAll('.node').length"), 5);
  assert.equal(await evaluate("document.querySelectorAll('.edge-line').length"), 2);
  assert.equal(await evaluate("document.querySelector('#graph-select').value"), 'b1');
  assert.equal(await evaluate("localStorage.getItem('inksmith.relations.v1').includes('古剑来历')"), true);
  // 重复进入不重复播种（按类型+名称去重）
  await send('Page.navigate', { url: base + '?book=b1' });
  await wait("document.querySelectorAll('.node').length > 0");
  assert.equal(await evaluate("document.querySelectorAll('.node').length"), 5);
  // 手动新增角色节点
  await act("document.getElementById('add-character').click()");
  await act("document.getElementById('node-name').value = '黑袍使·分身'; document.getElementById('node-form').requestSubmit()");
  assert.equal(await evaluate("document.querySelectorAll('.node').length"), 6);
  assert.equal(await evaluate("document.querySelectorAll('#node-list .node-row').length"), 6);
  // 手动新增连线
  const nodeIds = await evaluate("JSON.parse(localStorage.getItem('inksmith.relations.v1')).graphs.b1.nodes.filter(n => n.name === '林深' || n.name === '苏晚').map(n => n.id)");
  await act("document.getElementById('add-edge').click()");
  await act(`document.getElementById('edge-from').value = ${JSON.stringify(nodeIds[0])}; document.getElementById('edge-to').value = ${JSON.stringify(nodeIds[1])}; document.getElementById('edge-label').value = '师徒'; document.getElementById('edge-form').requestSubmit()`);
  assert.equal(await evaluate("document.querySelectorAll('.edge-line').length"), 3);
  // 刷新后恢复
  await send('Page.navigate', { url: base + '?book=b1' });
  await wait("document.querySelectorAll('.node').length > 0");
  assert.equal(await evaluate("document.querySelectorAll('.node').length"), 6);
  assert.equal(await evaluate("document.querySelectorAll('.edge-line').length"), 3);
  // 类型过滤：隐藏角色后画布不再渲染角色节点
  await act("(() => { const f = document.querySelector('[data-filter=character]'); f.checked = false; f.dispatchEvent(new Event('change')); })()");
  assert.equal(await evaluate("document.querySelectorAll('.node-rect.type-character').length"), 0);
  assert.equal(await evaluate("document.querySelectorAll('.node-rect.type-plot').length"), 2);
  await act("(() => { const f = document.querySelector('[data-filter=character]'); f.checked = true; f.dispatchEvent(new Event('change')); })()");
  // 自动布局：完成后所有节点坐标有限
  await act("document.getElementById('auto-layout').click()");
  await wait("document.querySelectorAll('.node').length === 6");
  await sleep(1500);
  assert.equal(await evaluate("[...JSON.parse(localStorage.getItem('inksmith.relations.v1')).graphs.b1.nodes].every(n => Number.isFinite(n.x) && Number.isFinite(n.y))"), true);
  // 选中与详情
  await act("document.querySelector('#node-list .node-row button').click()");
  assert.equal(await evaluate("document.querySelector('#detail .detail-box') !== null"), true);
  // 主题切换按钮可用
  const themeBefore = await evaluate("document.getElementById('theme-toggle').textContent");
  await act("document.getElementById('theme-toggle').click()");
  assert.notEqual(await evaluate("document.getElementById('theme-toggle').textContent"), themeBefore);
  // 响应式无横向溢出
  for (const width of [1440, 768, 390, 320]) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: width < 600 });
    assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true, `Overflow at ${width}px`);
  }
  assert.deepEqual(errors, [], 'Browser runtime errors');
  console.log('PASS: syntax, unique ids, workspace auto-seed (5 nodes / 2 edges), dedupe on re-entry, manual node/edge add, reload persistence, type filter, auto layout, selection detail, theme toggle, 320-1440px layouts, no runtime exceptions.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (ws) ws.close();
  child.kill();
  await sleep(500);
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Chrome may still hold temporary files. */ }
});
