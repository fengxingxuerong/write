const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.resolve(__dirname, '../web/ai.js'), 'utf8');
const config = {provider:'openai',baseUrl:'https://example.test/v1',model:'test',temperature:0,maxTokens:500};
const messages = [{role:'user',content:'test'}];
function api(fetch, timers = {}) {
  const context = {window:{},URL,AbortController,setTimeout,clearTimeout,fetch,...timers};
  vm.runInNewContext(source,context);
  return context.window.InkAI;
}
(async () => {
  let sent;
  let client = api(async (url, options) => { sent={url:String(url),...options}; return {ok:true,json:async()=>({choices:[{message:{content:'正文'}}]})}; });
  assert.equal(await client.request(config,messages),'正文');
  assert.equal(sent.url,'https://example.test/v1/chat/completions');
  assert.equal(sent.credentials,'omit'); assert.equal(sent.redirect,'error');
  assert.equal(JSON.parse(sent.body).temperature,0);
  client = api(async (url, options) => { sent={url:String(url),...options}; return {ok:true,json:async()=>({message:{content:'Ollama'}})}; });
  assert.equal(await client.request({...config,provider:'ollama',baseUrl:'http://127.0.0.1:11434'},messages),'Ollama');
  assert.equal(sent.url,'http://127.0.0.1:11434/api/chat');
  assert.equal(JSON.parse(sent.body).options.num_predict,500);
  for (const [status,name] of [[401,'鉴权失败'],[403,'鉴权失败'],[429,'限流'],[500,'服务错误']]) {
    await assert.rejects(api(async()=>({ok:false,status})).request(config,messages),e=>e.name===name);
  }
  await assert.rejects(api(async()=>({ok:true,json:async()=>{throw Error('bad')}})).request(config,messages),e=>e.name==='响应格式');
  await assert.rejects(api(async()=>({ok:true,json:async()=>({})})).request(config,messages),e=>e.name==='空响应');
  await assert.rejects(api(async()=>{throw Error('offline')}).request(config,messages),e=>e.name==='网络错误');
  for (const baseUrl of ['http://example.test','http://127.evil.test','https://user:pass@example.test','https://example.test?key=secret']) {
    await assert.rejects(api(async()=>{throw Error('must not request')}).request({...config,baseUrl},messages),e=>e.name==='配置错误');
  }
  const aborted = new AbortController(); aborted.abort();
  await assert.rejects(client.request(config,messages,{signal:aborted.signal}),e=>e.name==='已取消');
  // Headers received, but response body is pending: cancellation/timeout must still work.
  const stalledBody = async (url,options) => ({ok:true,json:()=>new Promise((resolve,reject)=>{options.signal.addEventListener('abort',()=>reject(Error('aborted')),{once:true});})});
  const controller = new AbortController();
  const task = api(stalledBody).request(config,messages,{signal:controller.signal});
  await new Promise(resolve=>setTimeout(resolve,10)); controller.abort();
  await assert.rejects(task,e=>e.name==='已取消');
  await assert.rejects(api(stalledBody,{setTimeout:fn=>setTimeout(fn,10)}).request(config,messages),e=>e.name==='超时');
  console.log('PASS: OpenAI/Ollama payloads, HTTP/JSON/empty/network errors, URL validation, pre-cancel, response-body cancel and timeout.');
})().catch(error=>{console.error(error);process.exitCode=1;});
