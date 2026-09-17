'use strict';
/* InkAI —— 真实模型请求模块（无模拟输出；仅 HTTPS 或本机 HTTP） */
(() => {
  const TIMEOUT_MS = 120000;
  const MAX_CHARS = 200000;
  const fail = (name, message) => { const e = new Error(message); e.name = name; return e; };

  /** 规范化端点：接受完整端点、/v1 或 origin；拒绝凭据/查询/片段与非白名单协议 */
  const buildUrl = (provider, baseUrl) => {
    const raw = String(baseUrl || '').trim();
    if (!raw) throw fail('配置错误', 'Base URL 不能为空');
    let url;
    try { url = new URL(raw); } catch { throw fail('配置错误', 'Base URL 格式无效'); }
    if (url.username || url.password) throw fail('配置错误', '不允许在 URL 中携带账号密码');
    if (url.search || url.hash) throw fail('配置错误', '不允许携带查询参数或锚点');
    const isLoopback = ['localhost', '[::1]'].includes(url.hostname) || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(url.hostname);
    if (url.protocol === 'http:' && !isLoopback) throw fail('配置错误', '非本机地址仅允许 HTTPS');
    if (url.protocol !== 'https:' && url.protocol !== 'http:') throw fail('配置错误', '仅支持 http/https 协议');
    const path = url.pathname.replace(/\/+$/, '');
    if (provider === 'ollama') {
      if (/\/api\/chat$/.test(path)) return url;
      if (/\/api$/.test(path)) return new URL(url.origin + path + '/chat');
      return new URL(url.origin + path + '/api/chat');
    }
    if (/\/chat\/completions$/.test(path)) return url;
    if (/\/v\d+$/.test(path)) return new URL(url.origin + path + '/chat/completions');
    return new URL(url.origin + path + '/v1/chat/completions');
  };

  /** 发起真实请求，返回模型文本；错误以 e.name 区分类别，不回显服务端响应体 */
  const request = async (config, messages, { signal } = {}) => {
    if (!config || typeof config.model !== 'string' || !config.model.trim()) throw fail('配置错误', '缺少模型配置');
    if (!['openai', 'ollama'].includes(config.provider)) throw fail('配置错误', '未知模型协议');
    if (signal?.aborted) throw fail('已取消', '请求已被用户取消');
    if (!Array.isArray(messages) || !messages.length) throw fail('配置错误', '缺少对话消息');
    const url = buildUrl(config.provider, config.baseUrl);
    const payload = config.provider === 'ollama'
      ? { model: config.model, messages, stream: false, options: { temperature: config.temperature, num_predict: config.maxTokens } }
      : { model: config.model, messages, stream: false, temperature: config.temperature, max_tokens: config.maxTokens };
    const headers = { 'Content-Type': 'application/json' };
    if (config.apiKey) headers.Authorization = `Bearer ${config.apiKey}`;
    const controller = new AbortController();
    const onExternalAbort = () => controller.abort();
    signal?.addEventListener('abort', onExternalAbort, { once: true });
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    let typedError;
    const checkedError = (name, message) => { typedError = fail(name, message); return typedError; };
    try {
      const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(payload), signal: controller.signal, redirect: 'error', credentials: 'omit' });
      if (!res.ok) {
        if (res.status === 401 || res.status === 403) throw checkedError('鉴权失败', `HTTP ${res.status}：请检查 API Key 与模型权限`);
        if (res.status === 429) throw checkedError('限流', 'HTTP 429：请求过于频繁或额度不足');
        throw checkedError('服务错误', `HTTP ${res.status}：服务返回错误`);
      }
      let data;
      try { data = await res.json(); }
      catch (error) { if (controller.signal.aborted) throw error; throw checkedError('响应格式', '响应不是有效 JSON'); }
      if (controller.signal.aborted) throw Error('aborted');
      const content = config.provider === 'ollama' ? data?.message?.content : data?.choices?.[0]?.message?.content;
      if (typeof content !== 'string' || !content.trim()) throw checkedError('空响应', '服务返回了空内容');
      if (content.length > MAX_CHARS) throw checkedError('响应过长', '模型输出超过限制，未截断保存，请降低输出 Token 数');
      return content;
    } catch (error) {
      if (signal?.aborted) throw fail('已取消', '请求已被用户取消');
      if (controller.signal.aborted) throw fail('超时', `请求超过 ${TIMEOUT_MS / 1000} 秒未完成，已中止`);
      if (error === typedError) throw error;
      throw fail('网络错误', '无法连接或读取端点（可能原因：CORS 未放行、服务未启动、网络中断）');
    } finally {
      clearTimeout(timer); signal?.removeEventListener('abort', onExternalAbort);
    }
  };

  window.InkAI = { request };
})();
