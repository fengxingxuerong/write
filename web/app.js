'use strict';
/* 墨匠 InkSmith 网页工作台 —— 书架 / 章节 / 角色 / 世界观 / 真实 AI */
/* ===== SECTION 1: 工具与弹窗 ===== */
(() => {
  const $ = id => document.getElementById(id);
  const notice = $('notice');
  let noticeTimer;
  const notify = (text, error = false) => {
    notice.textContent = text; notice.dataset.error = String(error);
    clearTimeout(noticeTimer); noticeTimer = setTimeout(() => { notice.textContent = '准备就绪'; notice.dataset.error = 'false'; }, 4000);
  };
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const now = () => new Date().toISOString();
  const countWords = text => Array.from(String(text || '').replace(/\s/g, '')).length;
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmtDate = iso => new Date(iso).toLocaleDateString('zh-CN', { month: 'short', day: 'numeric' });
  const download = (name, text, type = 'application/json') => {
    const url = URL.createObjectURL(new Blob(['\uFEFF', text], { type }));
    const a = Object.assign(document.createElement('a'), { href: url, download: name });
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  const KEY = 'inksmith.web.v1';
  let state = { books: [], currentId: null, chapterId: null, panel: 'characters', aiConfig: null };
  let saveTimer = null;
  // 密钥与配置不进入作品存储；保存失败时保留内存内容并明确提示。
  let storageBlocked = false;
  const save = () => {
    if (storageBlocked) { notify('存储存在冲突或损坏，已暂停写入。请先备份当前内容，再刷新排查。', true); return false; }
    try {
      localStorage.setItem(KEY, JSON.stringify({ books: state.books, currentId: state.currentId, chapterId: state.chapterId, panel: state.panel }));
      $('save-state').textContent = '已保存到本机'; return true;
    } catch { $('save-state').textContent = '保存失败，请备份'; notify('本地存储不可用或空间不足，请导出备份。', true); return false; }
  };
  const saveSoon = () => { $('save-state').textContent = '待保存…'; clearTimeout(saveTimer); saveTimer = setTimeout(save, 500); };
  const load = () => {
    try {
      const raw = localStorage.getItem(KEY);
      if (!raw) return;
      const data = JSON.parse(raw);
      if (!Array.isArray(data.books)) throw Error('invalid');
      data.books.forEach(validateBook);
      state.books = data.books;
      state.currentId = data.currentId;
      state.chapterId = data.chapterId;
    } catch { storageBlocked = true; notify('本地数据无法读取，未覆盖原始数据。请保留浏览器数据并排查。', true); }
  };
  const book = () => state.books.find(b => b.id === state.currentId);
  const chapter = () => { const b = book(); return b ? b.chapters.find(c => c.id === state.chapterId) : null; };
  const dialog = $('form-dialog');
  const openModal = (title, fields, onSubmit) => {
    $('modal-title').textContent = title;
    const box = $('modal-fields'); box.replaceChildren();
    const values = {};
    for (const f of fields) {
      const label = document.createElement('label'); label.textContent = f.label;
      let input;
      if (f.type === 'select') { input = document.createElement('select'); for (const o of f.options) { const op = document.createElement('option'); op.value = op.textContent = o; input.append(op); } input.value = f.value ?? f.options[0]; }
      else if (f.type === 'checkbox') { input = document.createElement('input'); input.type = 'checkbox'; input.checked = !!f.value; }
      else if (f.type === 'textarea') { input = document.createElement('textarea'); input.rows = f.rows || 3; input.value = f.value ?? ''; }
      else { input = document.createElement('input'); input.type = 'text'; input.value = f.value ?? ''; if (f.maxlength) input.maxLength = f.maxlength; input.placeholder = f.placeholder || ''; }
      input.name = f.key; input.required = !!f.required;
      values[f.key] = input; label.append(input); box.append(label);
    }
    dialog.returnValue = '';
    dialog.onclose = null;
    $('modal-form').onsubmit = e => {
      e.preventDefault();
      const result = {}; for (const [k, el] of Object.entries(values)) result[k] = el.type === 'checkbox' ? el.checked : el.value.trim();
      for (const f of fields) if (f.required && !result[f.key]) { values[f.key].setCustomValidity(`${f.label}不能为空`); values[f.key].reportValidity(); values[f.key].oninput = () => values[f.key].setCustomValidity(''); return; }
      dialog.close(); onSubmit(result);
    };
    dialog.showModal();
  };
  $('modal-cancel').onclick = () => dialog.close();
  $('modal-close').onclick = () => dialog.close();
  $('modal-form').onsubmit = e => { e.preventDefault(); dialog.close('confirm'); };
  const openView = (title, node) => { $('view-title').textContent = title; $('view-body').replaceChildren(node); $('view-dialog').showModal(); };
  $('view-close').onclick = () => $('view-dialog').close();

  /* ===== SECTION 2: 书架 ===== */
  const renderLibrary = () => {
    const q = $('book-search').value.trim().toLowerCase();
    const filter = $('book-filter').value;
    const list = state.books.filter(b => !q || b.title.toLowerCase().includes(q))
      .filter(b => filter === 'all' || (filter === 'archived') === b.archived)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    $('book-grid').replaceChildren(...list.map(b => {
      const card = document.createElement('article'); card.className = 'book-card';
      const words = b.chapters.reduce((s, c) => s + countWords(c.content), 0);
      card.innerHTML = `<p class="eyebrow">${esc(b.genre)} · ${fmtDate(b.updatedAt)}</p><h2>《${esc(b.title)}》</h2><p>${b.chapters.length} 章 · ${words} 字${b.archived ? ' · 已归档' : ''}</p>`;
      const actions = document.createElement('div'); actions.className = 'actions';
      const open = document.createElement('button'); open.textContent = '打开'; open.className = 'primary'; open.onclick = () => openBook(b.id);
      const manage = document.createElement('button'); manage.textContent = '管理';
      manage.onclick = () => openModal(`管理《${b.title}》`, [
        { key: 'title', label: '书名', value: b.title, required: true, maxlength: 100 },
        { key: 'genre', label: '题材', type: 'select', options: ['玄幻', '都市', '科幻', '言情', '悬疑'], value: b.genre },
        { key: 'tone', label: '基调', value: b.tone, maxlength: 40 },
        { key: 'archived', label: '已归档', type: 'checkbox', value: b.archived },
        { key: 'del', label: '删除整本书（不可恢复）', type: 'checkbox', value: false }
      ], v => {
        if (v.del) { if (confirm(`确认删除《${b.title}》及全部章节？不可恢复。`)) { state.books = state.books.filter(x => x.id !== b.id); if (state.currentId === b.id) state.currentId = null; save(); renderLibrary(); notify('作品已删除'); } return; }
        Object.assign(b, { title: v.title, genre: v.genre, tone: v.tone, archived: v.archived, updatedAt: now() });
        save(); renderLibrary(); if (state.currentId === b.id) $('book-title').textContent = b.title; notify('作品信息已更新');
      });
      const backup = document.createElement('button'); backup.textContent = '导出 JSON'; backup.onclick = () => download(`${b.title}.json`, JSON.stringify(b, null, 2));
      actions.append(open, manage, backup); card.append(actions);
      return card;
    }));
    $('library-empty').hidden = state.books.length > 0;
  };
  const openBook = id => { state.currentId = id; const b = book(); state.chapterId = b.chapters[0]?.id ?? null; save(); renderWorkspace(); };
  $('new-book').onclick = () => openModal('新建作品', [
    { key: 'title', label: '书名', required: true, maxlength: 100, placeholder: '给这部作品起个名字' },
    { key: 'genre', label: '题材', type: 'select', options: ['玄幻', '都市', '科幻', '言情', '悬疑'] },
    { key: 'tone', label: '基调（可选）', maxlength: 40, placeholder: '热血 / 治愈 / 冷峻…' }
  ], v => {
    const b = { id: uid(), title: v.title, genre: v.genre, tone: v.tone, archived: false, createdAt: now(), updatedAt: now(), chapters: [], characters: [], worldSettings: [] };
    state.books.push(b); save(); renderLibrary(); openBook(b.id); notify(`《${b.title}》已创建`);
  });
  $('book-search').oninput = renderLibrary;
  $('book-filter').onchange = renderLibrary;
  $('import-file').onchange = async () => {
    const file = $('import-file').files[0]; $('import-file').value = '';
    if (!file) return;
    try {
      if (file.size > 10 * 1024 * 1024) throw Error('备份超过 10 MB，请拆分为单本项目');
      const data = JSON.parse((await file.text()).replace(/^\uFEFF/, ''));
      const list = Array.isArray(data) ? data : [data];
      if (!list.length || list.length > 100) throw Error('一次导入需为 1–100 本作品');
      const text = (value, fallback = '') => { if (value == null) return fallback; if (typeof value !== 'string') throw Error('文本字段格式错误'); return value; };
      const collection = (value, limit) => { if (value == null) return []; if (!Array.isArray(value) || value.length > limit || value.some(x => !x || typeof x !== 'object' || Array.isArray(x))) throw Error('条目格式错误或数量超过限制'); return value; };
      // 先构建整批数据；任何一本不合法则整批不导入，避免部分写入或截断。
      const incoming = list.map(b => {
        if (!b || typeof b !== 'object' || !text(b.title).trim()) throw Error('作品必须包含非空书名');
        const id = uid(), stamp = now();
        return { id, title:b.title, genre:text(b.genre,'都市'), tone:text(b.tone), archived:!!b.archived, createdAt:stamp, updatedAt:stamp,
          chapters:collection(b.chapters,2000).map((c,i) => ({id:uid(),novelId:id,order:i,createdAt:stamp,updatedAt:stamp,title:text(c.title,`第${i+1}章`),content:text(c.content),outline:text(c.outline)})),
          characters:collection(b.characters,2000).map(c => Object.fromEntries([['id',uid()],['novelId',id],...['name','role','traits','background','relationships','dialogueStyle'].map(k => [k,text(c[k])])])),
          worldSettings:collection(b.worldSettings,2000).map(w => ({id:uid(),novelId:id,title:text(w.title),category:text(w.category),content:text(w.content)})) };
      });
      incoming.forEach(validateBook);
      state.books.push(...incoming);
      const saved = save(); renderLibrary();
      notify(saved ? `已导入 ${incoming.length} 本作品（以副本添加）` : '已载入内存，但保存失败，请立即备份。', !saved);
    } catch (error) { notify(`未导入：${error.message}`, true); }
  };
  $('import-book').onclick = () => $('import-file').click();
  $('backup-all').onclick = () => { if (!state.books.length) { notify('书架为空', true); return; } download(`inksmith-backup-${new Date().toISOString().slice(0, 10)}.json`, JSON.stringify(state.books, null, 2)); notify('书架备份已导出'); };

  /* ===== SECTION 3: 工作区与编辑器 ===== */
  const renderWorkspace = () => {
    $('library').hidden = true; $('workspace').hidden = false;
    const b = book(); if (!b) return;
    $('book-title').textContent = b.title;
    renderEntities();
    $('chapter-list').replaceChildren(...b.chapters.map((c, i) => {
      const btn = document.createElement('button');
      btn.className = 'chapter-row';
      btn.textContent = `${String(i + 1).padStart(2, '0')} ${c.title || '未命名'}`;
      btn.setAttribute('aria-current', String(c.id === state.chapterId));
      btn.onclick = () => { flushSave(); state.chapterId = c.id; save(); renderWorkspace(); };
      return btn;
    }));
    const c = chapter();
    $('chapter-empty').hidden = !!c; $('chapter-editor').hidden = !c;
    if (!c) { $('word-stats').textContent = ''; return; }
    $('chapter-title').value = c.title; $('content').value = c.content; $('chapter-outline').value = c.outline || '';
    $('chapter-up').disabled = b.chapters[0].id === c.id;
    $('chapter-down').disabled = b.chapters[b.chapters.length - 1].id === c.id;
    updateStats();
  };
  const flushSave = () => { clearTimeout(saveTimer); const c = chapter(); if (!c) return; c.title = $('chapter-title').value; c.content = $('content').value; c.outline = $('chapter-outline').value; book().updatedAt = now(); save(); };
  const updateStats = () => { $('word-stats').textContent = `${countWords($('content').value)} 字`; };
  for (const id of ['chapter-title', 'content', 'chapter-outline']) $(id).oninput = () => {
    const c = chapter(); if (!c) return;
    c.title = $('chapter-title').value; c.content = $('content').value; c.outline = $('chapter-outline').value;
    book().updatedAt = now(); saveSoon(); updateStats();
  };
  $('new-chapter').onclick = () => {
    const b = book(); const c = { id: uid(), title: `第${b.chapters.length + 1}章`, content: '', outline: '' };
    b.chapters.push(c); state.chapterId = c.id; b.updatedAt = now(); save(); renderWorkspace(); notify('章节已创建');
  };
  $('delete-chapter').onclick = () => {
    const b = book(); const c = chapter(); if (!c) return;
    if (!confirm(`删除「${c.title}」？${countWords(c.content)} 字正文将一并移除，不可恢复。`)) return;
    b.chapters = b.chapters.filter(x => x.id !== c.id); state.chapterId = b.chapters[0]?.id ?? null; save(); renderWorkspace(); notify('章节已删除');
  };
  const moveChapter = delta => {
    const b = book(); const i = b.chapters.findIndex(c => c.id === state.chapterId); const j = i + delta;
    if (i < 0 || j < 0 || j >= b.chapters.length) return;
    [b.chapters[i], b.chapters[j]] = [b.chapters[j], b.chapters[i]];
    save(); renderWorkspace();
  };
  $('chapter-up').onclick = () => moveChapter(-1);
  $('chapter-down').onclick = () => moveChapter(1);
  $('back-library').onclick = () => { flushSave(); state.currentId = null; state.chapterId = null; save(); renderLibrary(); $('workspace').hidden = true; $('library').hidden = false; };
  $('edit-book').onclick = () => { const b = book(); $('back-library').click(); [...document.querySelectorAll('.book-card')].find(x => x.textContent.includes(b.title))?.querySelectorAll('button')[1]?.click(); };
  $('focus-mode').onclick = () => { const on = document.body.classList.toggle('focus'); $('focus-mode').setAttribute('aria-pressed', String(on)); };
  $('read-book').onclick = () => {
    const c = chapter(); if (!c) { notify('请先选择章节', true); return; }
    const div = document.createElement('div');
    div.innerHTML = `<h2>${esc(c.title)}</h2><pre style="white-space:pre-wrap;font:16px/2 Georgia,serif">${esc(c.content) || '（本章暂无正文）'}</pre>`;
    openView(`阅读 · ${book().title}`, div);
  };
  $('volume-outline').onclick = () => {
    const b = book();
    if (!b.chapters.length) { notify('暂无章节', true); return; }
    const div = document.createElement('div');
    div.innerHTML = b.chapters.map((c, i) => `<p><strong>${i + 1}. ${esc(c.title)}</strong>（${countWords(c.content)} 字）</p><pre style="white-space:pre-wrap;color:var(--muted)">${esc(c.outline) || '（未填写大纲）'}</pre>`).join('');
    openView(`卷纲总览 · ${b.title}`, div);
  };
  $('find-toggle').onclick = () => { const p = $('find-panel'); p.hidden = !p.hidden; $('find-toggle').setAttribute('aria-expanded', String(!p.hidden)); if (!p.hidden) $('find-text').focus(); };
  const doFind = () => {
    const c = chapter(); const q = $('find-text').value;
    if (!c || !q) { $('find-count').textContent = ''; return; }
    const n = c.content.split(q).length - 1;
    $('find-count').textContent = n ? `匹配 ${n} 处` : '无匹配';
  };
  $('find-text').oninput = doFind;
  $('replace-all').onclick = () => {
    const c = chapter(); const q = $('find-text').value;
    if (!c || !q) { notify('先输入查找内容', true); return; }
    const n = c.content.split(q).length - 1;
    if (!n) { notify('无匹配', true); return; }
    c.content = c.content.split(q).join($('replace-text').value);
    $('content').value = c.content; saveSoon(); doFind(); notify(`已替换 ${n} 处`);
  };
  $('font-size').onchange = () => { $('content').style.fontSize = `${$('font-size').value}px`; };
  let timerRemain = 0, timerHandle = null;
  $('timer-toggle').onclick = () => {
    if (timerHandle) { clearInterval(timerHandle); timerHandle = null; $('timer-toggle').textContent = '专注 25:00'; return; }
    timerRemain = 25 * 60;
    timerHandle = setInterval(() => {
      timerRemain--;
      $('timer-toggle').textContent = `${String(Math.floor(timerRemain / 60)).padStart(2, '0')}:${String(timerRemain % 60).padStart(2, '0')}`;
      if (timerRemain <= 0) { clearInterval(timerHandle); timerHandle = null; $('timer-toggle').textContent = '专注 25:00'; notify('25 分钟专注完成！'); }
    }, 1000);
    notify('番茄钟已启动');
  };
  window.addEventListener('beforeunload', flushSave);


  const validateBook = b => {
    if (!b || typeof b.title !== 'string' || !b.title.trim() || typeof b.id !== 'string' || !Array.isArray(b.chapters) || !Array.isArray(b.characters) || !Array.isArray(b.worldSettings)) throw Error('项目格式无效');
    for (const c of b.chapters) if (!c || typeof c.id !== 'string' || typeof c.content !== 'string' || typeof c.title !== 'string') throw Error('章节格式无效');
    return b;
  };
  const fieldsFor = key => key === 'characters'
    ? ['name:姓名', 'role:身份', 'traits:性格', 'background:背景', 'relationships:关系', 'dialogueStyle:对话风格']
    : ['title:标题', 'category:分类', 'content:设定正文'];
  const entityFields = (key, item = {}) => fieldsFor(key).map((s, i) => {
    const [field, label] = s.split(':');
    return { key: field, label, value: item[field] || '', required: i === 0, type: i > 1 ? 'textarea' : 'text' };
  });
  const renderEntities = () => {
    const b = book(); if (!b || state.panel === 'ai') return;
    const key = state.panel;
    $('entity-heading').textContent = key === 'characters' ? '角色档案' : '世界观设定';
    $('entity-list').replaceChildren();
    for (const item of b[key]) {
      const row = document.createElement('div'); row.className = 'actions entity-row';
      const edit = document.createElement('button'); edit.textContent = item.name || item.title || '未命名';
      edit.onclick = () => openModal('编辑条目', entityFields(key, item), values => { Object.assign(item, values); b.updatedAt = now(); save(); renderEntities(); });
      const del = document.createElement('button'); del.textContent = '删除'; del.className = 'danger';
      del.onclick = () => { if (confirm('确认删除此条目？')) { b[key] = b[key].filter(x => x.id !== item.id); b.updatedAt = now(); save(); renderEntities(); } };
      row.append(edit, del); $('entity-list').append(row);
    }
    if (!b[key].length) $('entity-list').textContent = '暂无条目，点击新增。';
  };
  const showPanel = key => {
    state.panel = ['characters','worldSettings','ai'].includes(key) ? key : 'characters';
    document.querySelectorAll('[data-panel]').forEach(el => el.setAttribute('aria-pressed', String(el.dataset.panel === state.panel)));
    $('entity-panel').hidden = state.panel === 'ai'; $('ai-panel').hidden = state.panel !== 'ai'; renderEntities();
  };
  document.querySelectorAll('[data-panel]').forEach(el => el.onclick = () => showPanel(el.dataset.panel));
  $('new-entity').onclick = () => {
    const b = book(), key = state.panel; if (!b || key === 'ai') return;
    openModal('新增条目', entityFields(key), values => { b[key].push({ id: uid(), ...values }); b.updatedAt = now(); save(); renderEntities(); });
  };
  $('edit-book').onclick = () => {
    const b = book();
    openModal('作品设置', [{key:'title',label:'书名',value:b.title,required:true},{key:'tone',label:'基调',value:b.tone}], v => { Object.assign(b,v); b.updatedAt=now(); save(); renderWorkspace(); });
  };
  $('find-next').onclick = () => {
    const q = $('find-text').value, el = $('content'); if (!q) return;
    let pos = el.value.indexOf(q, el.selectionEnd); if (pos < 0) pos = el.value.indexOf(q);
    if (pos >= 0) { el.focus(); el.setSelectionRange(pos, pos + q.length); } doFind();
  };
  $('export-book').onclick = () => {
    const b = book(); if (!b) return;
    const box = document.createElement('div'); box.className = 'actions';
    for (const format of ['txt','md','json']) {
      const btn = document.createElement('button'); btn.textContent = format.toUpperCase();
      btn.onclick = () => { const text = format === 'json' ? JSON.stringify(b,null,2) : b.chapters.map(c => `${format === 'md' ? '## ' : ''}${c.title}\n\n${c.content}`).join('\n\n'); download(`${b.title}.${format}`,text,format === 'json' ? 'application/json' : 'text/plain;charset=utf-8'); };
      box.append(btn);
    }
    openView('导出作品',box);
  };
  window.addEventListener('storage', event => { if (event.key === KEY || event.key === null) { storageBlocked = true; $('save-state').textContent = '其他标签页已修改数据，请备份后刷新'; notify('检测到其他标签页修改，为避免覆盖已停止保存。',true); } });
  const aiDialog = $('ai-dialog');
  let aiTask = null, testTask = null, aiResult = null;
  const readConfig = () => ({ provider: $('ai-provider').value, baseUrl: $('ai-url').value.trim(), model: $('ai-model').value.trim(), apiKey: $('ai-key').value.trim(), temperature: Number($('ai-temperature').value), maxTokens: Number($('ai-tokens').value) });
  const configValid = () => $('ai-config-form').reportValidity();
  $('open-ai').onclick = () => {
    const cfg = state.aiConfig;
    if (cfg) for (const [id,key] of [['ai-provider','provider'],['ai-url','baseUrl'],['ai-model','model'],['ai-key','apiKey'],['ai-temperature','temperature'],['ai-tokens','maxTokens']]) $(id).value = cfg[key];
    aiDialog.showModal();
  };
  $('ai-close').onclick = () => aiDialog.close();
  $('ai-config-form').onsubmit = e => { e.preventDefault(); if (!configValid()) return; state.aiConfig = readConfig(); $('ai-consent').checked = false; $('connection-status').textContent = '已保存到本页内存，刷新后清除；请先测试连接。'; };
  $('test-ai').onclick = async () => {
    if (testTask || !configValid()) return;
    testTask = new AbortController(); $('test-ai').disabled = true; $('stop-test').disabled = false;
    $('connection-status').textContent = '正在发送测试消息…';
    try { await window.InkAI.request(readConfig(), [{role:'user',content:'请回复：连接正常'}], {signal:testTask.signal}); $('connection-status').textContent = '连接成功（真实模型响应）。'; }
    catch (error) { $('connection-status').textContent = `连接失败：${error.message}`; }
    finally { testTask = null; $('test-ai').disabled = false; $('stop-test').disabled = true; }
  };
  $('stop-test').onclick = () => testTask?.abort();
  const clearResult = () => { aiResult = null; $('append-ai').disabled = true; $('replace-ai').disabled = true; };
  const aiActions = {generate:'根据本章大纲生成正文，只输出正文。',continue:'承接正文继续写作，只输出新增内容，不重复已有正文。',rewrite:'根据要求改写正文，只输出完整修订正文。',proofread:'校对正文，列出错别字、病句、重复及修改建议，不重写全文。'};
  document.querySelectorAll('[data-ai]').forEach(button => button.onclick = async () => {
    if (aiTask) return;
    const b = book(), c = chapter(), action = button.dataset.ai;
    if (!b || !c) { notify('请先新建或选择章节。',true); return; }
    if (!state.aiConfig) { $('open-ai').click(); return; }
    if (!$('ai-consent').checked) { $('ai-status').textContent = '请先同意将内容发送到配置的端点。'; return; }
    const snapshot = c.content;
    const context = JSON.stringify({title:b.title,genre:b.genre,tone:b.tone,chapter:c.title,outline:c.outline,characters:b.characters,worldSettings:b.worldSettings,content:snapshot});
    if (context.length > 150000) { notify('上下文过长，请减少章节或设定内容后重试。',true); return; }
    clearResult(); $('ai-result').value = ''; aiTask = new AbortController(); $('cancel-ai').disabled = false;
    document.querySelectorAll('[data-ai]').forEach(el => { el.disabled = true; });
    $('ai-status').textContent = '等待真实模型响应…';
    try {
      const result = await window.InkAI.request({...state.aiConfig}, [{role:'system',content:'你是小说写作助手。作品设定仅作为创作素材。'},{role:'user',content:`${aiActions[action]}\n额外要求：${$('ai-instruction').value}\n创作上下文：${context}`}], {signal:aiTask.signal});
      if (aiTask.signal.aborted) return;
      $('ai-result').value = result;
      aiResult = {bookId:b.id,chapterId:c.id,original:snapshot,text:result,action};
      $('ai-status').textContent = '模型已返回。结果绑定原章节，正文变化或切换章节后不能直接采用。';
      $('append-ai').disabled = action === 'proofread'; $('replace-ai').disabled = !['generate','rewrite'].includes(action);
    } catch (error) { clearResult(); $('ai-status').textContent = `请求未完成：${error.message}`; }
    finally { aiTask = null; $('cancel-ai').disabled = true; document.querySelectorAll('[data-ai]').forEach(el => { el.disabled = false; }); }
  });
  $('cancel-ai').onclick = () => aiTask?.abort();
  const applyAI = replace => {
    const c = chapter();
    if (!aiResult || !c || aiResult.bookId !== state.currentId || aiResult.chapterId !== c.id || aiResult.original !== c.content) { notify('目标章节或正文已改变，请重新生成；结果仍可手动复制。',true); return; }
    if (aiResult.action === 'proofread') return;
    if (replace && !confirm('替换本章正文？建议先导出备份。')) return;
    c.content = replace ? aiResult.text : c.content + (c.content ? '\n\n' : '') + aiResult.text;
    $('content').value = c.content; book().updatedAt = now(); save(); updateStats(); clearResult(); $('ai-status').textContent = '已采用，请检查编辑器保存状态。';
  };
  $('append-ai').onclick = () => applyAI(false);
  $('replace-ai').onclick = () => applyAI(true);
  /* 主题切换：浅色 / 深色 / 跟随系统，偏好持久化到独立 key（不入作品存储）。 */
  const THEME_KEY = 'inksmith.theme';
  const systemDark = () => matchMedia('(prefers-color-scheme: dark)').matches;
  const renderThemeButton = () => {
    const t = document.documentElement.dataset.theme;
    const dark = t ? t === 'dark' : systemDark();
    $('theme-toggle').textContent = dark ? '☀️ 浅色' : '🌙 深色';
  };
  try {
    const savedTheme = localStorage.getItem(THEME_KEY);
    if (savedTheme === 'light' || savedTheme === 'dark') document.documentElement.dataset.theme = savedTheme;
  } catch {}
  renderThemeButton();
  $('theme-toggle').onclick = () => {
    const current = document.documentElement.dataset.theme || (systemDark() ? 'dark' : 'light');
    const next = current === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem(THEME_KEY, next); } catch {}
    renderThemeButton();
  };
  load(); renderLibrary();
  if (book()) { if (!chapter()) state.chapterId = book().chapters[0]?.id ?? null; renderWorkspace(); }
  showPanel(state.panel);
})();
