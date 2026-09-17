// InkAI 请求模块验证：本地 mock fetch，覆盖协议/错误/取消/密钥路径，无外部网络。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.resolve(__dirname, '../web/index.html'), 'utf8');
assert.match(html, /<script defer src="ai\.js"><\/script>/);
const code = fs.readFileSync(path.resolve(__dirname, '../web/ai.js'), 'utf8');
const context = { window: {}, fetch: null, AbortController, URL, setTimeout, clearTimeout, console };
vm.createContext(context);
vm.runInContext(code, context);
const request = context.window.InkAI.request;

const ok = (body, status = 200) => ({ ok: status < 400, status, json: async () => body });
const capture = responses => {
  const calls = [];
  context.fetch = async (url, init) => { calls.push({ url: String(url), init }); if (responses instanceof Error) throw responses; return typeof responses.json === 'function' ? {ok:true,status:200,...responses} : ok(responses); };
  return calls;
};

(async () => {
  // OpenAI 兼容：/v1 与 origin 均规范化，返回文本，携带鉴权头
  let calls = capture({ choices: [{ message: { content: '正文' } }] });
  assert.equal(await request({ provider: 'openai', baseUrl: 'https://api.x.com/v1', model: 'm', apiKey: 'sk-1', temperature: 0.5, maxTokens: 100 }, [{ role: 'user', content: 'hi' }]), '正文');
  assert.equal(calls[0].url, 'https://api.x.com/v1/chat/completions');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer sk-1');
  const payload = JSON.parse(calls[0].init.body);
  assert.equal(payload.temperature, 0.5); assert.equal(payload.max_tokens, 100); assert.equal(payload.stream, false);

  // Ollama：origin → /api/chat；本机 http 允许
  capture({ message: { content: '本机回复' } });
  assert.equal(await request({ provider: 'ollama', baseUrl: 'http://localhost:11434', model: 'q' }, [{ role: 'user', content: 'hi' }]), '本机回复');

  // 完整端点直接使用
  let calls2 = capture({ choices: [{ message: { content: 'A' } }] });
  await request({ provider: 'openai', baseUrl: 'https://api.x.com/v1/chat/completions', model: 'm' }, [{ role: 'user', content: 'x' }]);
  assert.equal(calls2[0].url, 'https://api.x.com/v1/chat/completions');

  // 错误分类
  for (const [status, name] of [[401, '鉴权失败'], [429, '限流'], [500, '服务错误']]) {
    capture({ ok: false, status, json: async () => ({}) });
    await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === name);
  }
  capture({ choices: [{ message: { content: '' } }] });
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '空响应');
  capture(new Error('boom'));
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '网络错误');
  // JSON 坏响应
  capture({ json: async () => { throw new Error('bad'); } });
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '响应格式');

  // 安全校验：非本机 http、URL 凭据、查询串、坏协议、缺模型
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'http://api.x.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '配置错误');
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://u:p@a.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '配置错误');
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com/v1?key=1', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '配置错误');
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com', model: '' }, [{ role: 'user', content: 'x' }]), e => e.name === '配置错误');
  await assert.rejects(() => request({ provider: 'ftp', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }]), e => e.name === '配置错误');

  // 取消：外部 abort 立即返回“已取消”，不发起 fetch
  const abort = new AbortController(); abort.abort();
  capture({ choices: [{ message: { content: 'x' } }] });
  await assert.rejects(() => request({ provider: 'openai', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }], { signal: abort.signal }), e => e.name === '已取消');

  // 请求体不包含 apiKey 以外敏感信息；无密钥时不带 Authorization
  let calls3 = capture({ choices: [{ message: { content: 'x' } }] });
  await request({ provider: 'openai', baseUrl: 'https://a.com', model: 'm' }, [{ role: 'user', content: 'x' }]);
  assert.ok(!('Authorization' in calls3[0].init.headers));
  // 请求体不含密钥字段
  assert.ok(!calls3[0].init.body.includes('apiKey'));

  // 不把配置写入 localStorage（密钥不落盘的代码层面证据：模块从不引用 localStorage）
  assert.ok(!code.includes('localStorage'));
  assert.ok(!code.includes('document.cookie'));

  console.log('PASS: InkAI openai/ollama URL normalization, payload, auth header only with key, status/error classes, empty/format/network failures, loopback http, credential/query/bad-protocol rejection, external abort, no secret persistence.');
})().catch(e => { console.error(e); process.exitCode = 1; });
