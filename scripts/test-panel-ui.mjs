#!/usr/bin/env node
// 原生 DOM 行为桩 + Node VM；不安装浏览器或 npm 依赖。
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { createFixture } from './panel-ui-fixture.mjs';

const html = readFileSync(new URL('../deploy/panel/web/index.html', import.meta.url), 'utf8');
const script = html.match(/<script>\n([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, '必须存在单一内联脚本');
assert.doesNotMatch(script, /innerHTML|outerHTML|insertAdjacentHTML|\.on(?:click|change|input)\s*=/, '禁止 HTML 字符串插入和内联事件');
assert.doesNotMatch(html, /\son(?:click|change|input|submit)=|<link[^>]+https?:|<script[^>]+https?:/i, '禁止内联事件和外部资源');
const syntax = spawnSync(process.execPath, ['--check', '-'], { input: script, encoding: 'utf8' });
assert.equal(syntax.status, 0, syntax.stderr);
console.log('ok - 内联脚本 node --check；无外部依赖和 HTML 注入入口');

class DOMEvent {
  constructor(type, options = {}) { this.type = type; Object.assign(this, options); }
  preventDefault() { this.defaultPrevented = true; }
}
class Node {
  constructor(tag = '', doc = null, text = null) {
    this.tagName = tag.toUpperCase(); this.ownerDocument = doc; this.childNodes = []; this.parentNode = null;
    this.attributes = new Map(); this.dataset = {}; this.style = {}; this.listeners = new Map(); this._text = text;
    this.value = ''; this.hidden = false; this.disabled = false; this.open = false; this.type = ''; this.checked = false;
    this.classList = {
      contains: c => this.className.split(/\s+/).includes(c),
      add: c => { if (!this.classList.contains(c)) this.className = [this.className, c].filter(Boolean).join(' '); },
      remove: c => { this.className = this.className.split(/\s+/).filter(v => v !== c).join(' '); },
      toggle: (c, force) => { const next = force ?? !this.classList.contains(c); next ? this.classList.add(c) : this.classList.remove(c); return next; },
    };
  }
  get children() { return this.childNodes.filter(n => n.tagName); }
  get lastChild() { return this.childNodes.at(-1); }
  get firstChild() { return this.childNodes[0]; }
  get nextElementSibling() { const siblings = this.parentNode?.children || []; return siblings[siblings.indexOf(this) + 1] || null; }
  get isConnected() { return this === this.ownerDocument?.documentElement || !!this.parentNode?.isConnected; }
  get className() { return this.attributes.get('class') || ''; }
  set className(v) { this.attributes.set('class', v); }
  get id() { return this.attributes.get('id') || ''; }
  set id(v) { this.attributes.set('id', v); }
  get textContent() { return (this._text ?? '') + this.childNodes.map(n => n.textContent).join(''); }
  set textContent(v) { this.childNodes.forEach(n => n.parentNode = null); this.childNodes = []; this._text = String(v ?? ''); }
  set innerHTML(_) { throw new Error('测试拒绝 innerHTML'); }
  set outerHTML(_) { throw new Error('测试拒绝 outerHTML'); }
  append(...nodes) { for (let n of nodes) { if (typeof n === 'string') n = this.ownerDocument.createTextNode(n); n.remove(); n.parentNode = this; this.childNodes.push(n); } }
  replaceChildren(...nodes) { this.textContent = ''; this.append(...nodes); }
  replaceWith(node) { const parent = this.parentNode; if (!parent) return; const index = parent.childNodes.indexOf(this); node.remove(); parent.childNodes[index] = node; node.parentNode = parent; this.parentNode = null; }
  remove() { if (this.parentNode) { const p = this.parentNode; p.childNodes.splice(p.childNodes.indexOf(this), 1); this.parentNode = null; } }
  after(node) { const p = this.parentNode; if (!p) return; node.remove(); p.childNodes.splice(p.childNodes.indexOf(this) + 1, 0, node); node.parentNode = p; }
  setAttribute(k, v) { this.attributes.set(k, String(v)); if (k.startsWith('data-')) this.dataset[k.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = String(v); }
  getAttribute(k) { return this.attributes.get(k) ?? null; }
  removeAttribute(k) { this.attributes.delete(k); }
  addEventListener(type, fn) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(fn); }
  dispatchEvent(e) { e.target ??= this; for (const fn of this.listeners.get(e.type) || []) fn(e); if (e.bubbles) this.parentNode?.dispatchEvent(e); return !e.defaultPrevented; }
  click() { if (!this.disabled) this.dispatchEvent(new DOMEvent('click')); }
  focus() { this.ownerDocument.activeElement = this; }
  matches(selector) {
    if (selector.includes(',')) return selector.split(',').some(s => this.matches(s.trim()));
    const attr = selector.match(/\[([^=\]]+)(?:="([^"]*)")?\]/);
    if (attr) { const value = attr[1].startsWith('data-') ? this.dataset[attr[1].slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] : this.getAttribute(attr[1]); if (value == null || (attr[2] !== undefined && value !== attr[2])) return false; selector = selector.replace(attr[0], ''); }
    if (selector.startsWith('#')) return this.id === selector.slice(1);
    const [tag, cls] = selector.split('.');
    return (!tag || this.tagName.toLowerCase() === tag) && (!cls || this.classList.contains(cls));
  }
  querySelectorAll(selector) { return this.children.flatMap(n => [...(n.matches(selector) ? [n] : []), ...n.querySelectorAll(selector)]); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
function documentStub() {
  const doc = { createElement: tag => new Node(tag, doc), createTextNode: t => new Node('', doc, String(t)), createElementNS: (ns, tag) => { const n = new Node(tag, doc); n.namespaceURI = ns; return n; }, addEventListener() {}, title: '' };
  doc.documentElement = doc.createElement('html'); doc.body = doc.createElement('body'); doc.documentElement.append(doc.body);
  doc.querySelector = s => doc.documentElement.querySelector(s); doc.querySelectorAll = s => doc.documentElement.querySelectorAll(s); doc.getElementById = id => doc.querySelector('#' + id);
  // 仅解析固定静态骨架；动态界面必须由脚本真实 createElement 构建。
  const body = html.match(/<body>([\s\S]*?)<script>/)[1], stack = [doc.body];
  for (const m of body.matchAll(/<\/?[a-zA-Z][^>]*>/g)) {
    const token = m[0], tag = token.match(/^<\/?([\w-]+)/)[1];
    if (token.startsWith('</')) { if (stack.at(-1)?.tagName.toLowerCase() === tag) stack.pop(); continue; }
    const n = doc.createElement(tag);
    for (const a of token.matchAll(/([\w-]+)(?:="([^"]*)")?/g)) { if (a[1] === tag) continue; n.setAttribute(a[1], a[2] || ''); if (a[1] === 'hidden') n.hidden = true; if (a[1] === 'type') n.type = a[2]; }
    stack.at(-1).append(n); if (!['input', 'br', 'meta', 'img', 'hr'].includes(tag)) stack.push(n);
  }
  return doc;
}
const settle = async () => { for (let i = 0; i < 8; i++) await new Promise(resolve => setImmediate(resolve)); };
async function boot(options = {}) {
  const fixture = createFixture(options), posts = [], requests = [], document = documentStub(), storage = new Map(), timeouts = new Map(), qr = [], copies = [], events = new Map(); let timerId = 0;
  const context = {
    document, console, Event: DOMEvent, URL, Uint8Array, crypto: webcrypto, btoa, atob, confirm: () => true,
    navigator: { clipboard: { writeText: async v => copies.push(v) } }, location: { href: 'http://localhost/fixture01/' },
    localStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, String(v)) },
    setTimeout: (fn, ms) => { timeouts.set(++timerId, { fn, ms }); return timerId; }, clearTimeout: id => timeouts.delete(id), setInterval: () => 0, clearInterval() {},
    QRCode: class { constructor(_, o) { qr.push(o.text); } },
    fetch: async (url, opts = {}) => {
      const key = String(url).replace(/^api\//, ''), method = opts.method || 'GET', body = opts.body ? JSON.parse(opts.body) : {};
      requests.push({ key, method }); if (method === 'POST') posts.push({ key, body });
      const r = await (context.intercept?.(key, method, body) ?? fixture.request(key, method, body));
      return { status: r.status, ok: r.status >= 200 && r.status < 300, text: async () => JSON.stringify(r.body) };
    },
  };
  context.window = { addEventListener: (type, fn) => events.set(type, fn), matchMedia: () => ({ matches: false }) };
  context.globalThis = context;
  vm.createContext(context); vm.runInContext(script, context); await settle();
  return { ctx: context, fixture, posts, requests, document, storage, timeouts, qr, copies, events, get: expr => vm.runInContext(expr, context), tab: async t => { await context.showTab(t, { force: true }); await settle(); } };
}
function input(n, value) { n.value = String(value); n.dispatchEvent(new DOMEvent('input', { bubbles: true })); }
function change(n, value) { n.value = String(value); n.dispatchEvent(new DOMEvent('change', { bubbles: true })); }
function findButton(root, text) { const b = root.querySelectorAll('button').find(b => b.textContent.trim() === text); assert.ok(b, '按钮存在：' + text); return b; }
async function click(b) { b.click(); await settle(); }
let passed = 1;
async function test(name, fn) { try { await fn(); passed++; console.log('ok - ' + name); } catch (error) { console.error('FAIL - ' + name); throw error; } }

await test('落地 SS↔SOCKS 切换保留双份值，显式关闭远端仍提交 false', async () => {
  const b = await boot(); await b.tab('landing'); const e = b.get('state.landings.get("1")');
  input(e.inputs.ss_host, 'your-domain.com'); input(e.inputs.ss_password, 'SS-draft');
  await click(e.segment.children[1]); input(e.inputs.socks_host, 'socks.your-domain.com'); input(e.inputs.socks_password, 'SOCKS-draft');
  await click(e.segment.children[0]); assert.equal(e.inputs.ss_password.value, 'SS-draft'); await click(e.segment.children[1]); change(e.inputs.remote_enabled, 'false');
  assert.equal(e.mark.hidden, false); assert.equal(e.ss.hidden, true); assert.equal(e.socks.hidden, false);
  await click(findButton(e.root, '保存修改'));
  const payload = b.posts.find(p => p.key === 'landings/update').body;
  assert.deepEqual(payload.remote_ss, { host: 'your-domain.com', port: 8388, method: '2022-blake3-aes-128-gcm', password: 'SS-draft' });
  assert.deepEqual(payload.remote_socks, { host: 'socks.your-domain.com', port: 1080, user: 'fake-user', password: 'SOCKS-draft' });
  assert.equal(payload.remote_type, 'socks'); assert.equal(payload.remote_enabled, false);
  const saved = b.get('state.landings.get("1")'); assert.equal(saved.mark.hidden, true); assert.match(saved.summary.textContent, /direct 直连/);
});
await test('创建/保存/重置/删除只操作对应落地卡，保留其他卡片草稿与 DOM', async () => {
  const b = await boot(); await b.tab('landing'); const other = b.get('state.landings.get("2")'); input(other.inputs.name, '尚未保存的名称'); input(other.inputs.ss_password, 'unsaved-SS');
  let first = b.get('state.landings.get("1")'); await click(findButton(first.root, '保存修改')); first = b.get('state.landings.get("1")');
  input(first.inputs.name, '本卡片也有草稿'); await click(findButton(first.root, '重置凭证')); assert.equal(first.inputs.name.value, '本卡片也有草稿'); assert.equal(first.inputs.password.value, 'fake-regenerated-password');
  const create = b.document.querySelector('[data-fold="landing.create"]'), fields = create.querySelectorAll('input'); input(fields[0], '新线路'); input(fields[1], 23463); await click(findButton(create, '创建落地'));
  await click(findButton(first.root, '删除'));
  assert.equal(other, b.get('state.landings.get("2")')); assert.equal(other.inputs.name.value, '尚未保存的名称'); assert.equal(other.inputs.ss_password.value, 'unsaved-SS'); assert.equal(other.mark.hidden, false); assert.equal(other.root.isConnected, true);
});
await test('落地草稿的离页确认与 beforeunload；取消离页保持原页面', async () => {
  const b = await boot(); await b.tab('landing'); input(b.get('state.landings.get("1").inputs.name'), 'draft'); b.ctx.confirm = () => false;
  await b.ctx.showTab('node'); assert.equal(b.get('state.tab'), 'landing');
  const event = new DOMEvent('beforeunload'); b.events.get('beforeunload')(event); assert.equal(event.defaultPrevented, true);
});
await test('仪表盘健康检测为次级按钮；内容焦点无青色边框，页面不透明度渐入', async () => {
  const b = await boot(); await b.tab('dash');
  const buttons = b.document.querySelector('[data-fold="dash.services"]').querySelectorAll('button').filter(n => n.textContent === '健康检测');
  assert.equal(buttons.length, 4); assert.ok(buttons.every(n => n.classList.contains('secondary')));
  assert.match(html, /\.content:focus-visible\{outline:none\}/);
  assert.doesNotMatch(html, /animation:appear|@keyframes appear/);
});
await test('仪表盘、服务与落地健康检测显示摘要、展开详情及 direct 提示', async () => {
  const b = await boot({ docker: true });
  for (const tab of ['dash', 'mgmt', 'landing']) {
    await b.tab(tab);
    const root = tab === 'dash' ? b.document.querySelector('[data-fold="dash.services"]')
      : b.get(tab === 'mgmt' ? 'state.services.get("ss").root' : 'state.landings.get("1").root');
    await click(findButton(root, '健康检测'));
    const box = root.querySelector('.diagnostic');
    assert.ok(box?.isConnected); assert.equal(box.hidden, false);
    assert.match(box.textContent, /假数据：入口与 TCP 握手正常/);
    const details = box.querySelector('details');
    assert.equal(details.open, false);
    assert.equal(details.querySelector('summary').textContent, '展开详情');
    details.open = true;
    assert.match(details.textContent, /端口监听.*TCP 握手/);
    assert.match(details.textContent, /Docker 共享宿主时间/);
    if (tab === 'landing') assert.match(box.textContent, /未启用远端出口（走 direct）/);
  }
  b.ctx.intercept = key => key === 'health' ? { status: 200, body: { ok: true, enabled: true, active: 'failed', summary: '<错误>：启动限速', landing_remote: 'no', landing_remote_reason: '远端不可达' } } : null;
  const root = b.get('state.landings.get("1").root');
  await click(findButton(root, '健康检测'));
  assert.match(root.querySelector('.diagnostic').textContent, /需要关注.*<错误>：启动限速.*远端不可达/);
});
await test('manual 填凭证后直接签发切换，失败日志可见且按钮恢复', async () => {
  const b = await boot({ certMode: 'manual', dynu: 'none' }); await b.tab('cert');
  const e = b.get('state.cert'), action = findButton(e.form.root, '签发并切换到 ACME');
  assert.equal(e.apiKey.wrap.parentNode.parentNode.hidden, false);
  input(e.apiKey.input, 'example-key'); input(e.email.input, 'admin@your-domain.com');
  b.ctx.intercept = (key, method) => key === 'cert/issue' && method === 'POST' ? { status: 500, body: { ok: false, error: '签发失败', log: '本次 DNS 校验失败' } } : null;
  await click(action);
  assert.equal(e.mode.input.value, 'manual'); assert.equal(e.log.hidden, false); assert.equal(e.log.textContent, '本次 DNS 校验失败'); assert.equal(e.actions.root.open, true); assert.equal(action.disabled, false);
  assert.equal(b.posts.at(-1).body.dynu_api_key, 'example-key');
  assert.equal(b.posts.at(-1).key, 'cert/issue'); assert.ok(!b.posts.some(p => p.key === 'cert/config'));
  b.ctx.intercept = (key, method) => key === 'cert/issue' && method === 'POST' ? { status: 200, body: { ok: true, log: '本次签发成功', restart_in: 3, new_url: 'https://your-domain.com/admin/' } } : null;
  await click(action); assert.equal(e.log.textContent, '本次签发成功'); assert.equal(b.document.querySelector('#overlay').hidden, false);
});
await test('证书脚本仅 Docker+manual 显示；未保存来源隐藏所有旧模式操作', async () => {
  for (const docker of [false, true]) for (const mode of ['acme', 'manual']) {
    const b = await boot({ docker, certMode: mode }); await b.tab('cert'); const sync = b.document.querySelector('#docker_sync_wrap'), entry = b.get('state.cert');
    if (docker) assert.equal(sync.hidden, mode !== 'manual'); else assert.equal(sync, null);
    change(entry.mode.input, mode === 'manual' ? 'acme' : 'manual');
    assert.equal(entry.acmeOps.hidden, true); assert.equal(entry.manualOps.hidden, true); assert.equal(entry.pending.hidden, false);
    if (docker) assert.equal(sync.hidden, mode === 'manual');
    await click(findButton(entry.form.root, '保存来源设置'));
    const payload = b.posts.find(p => p.key === 'cert/config').body; assert.equal(payload.mode, mode === 'manual' ? 'acme' : 'manual');
    assert.ok(!('dynu_client_id' in payload)); assert.equal(entry.pending.hidden, true);
  }
});
await test('证书 API Key/邮箱提交与 OAuth 兼容提示；同步脚本 Bash 语法/引号安全', async () => {
  const b = await boot({ docker: true, certMode: 'manual', dynu: 'oauth' }); await b.tab('cert');
  assert.match(b.document.querySelector('#content').textContent, /OAuth.*兼容.*迁移/);
  const path = "/etc/your-domain.com/a'quoted\nANSGO_SYNC_EOF\n$(touch /tmp/should-not-exist)";
  const script1 = b.ctx.dockerManualSyncScript(path, '/etc/key.pem'), script2 = b.ctx.dockerManualCronInstallScript(path, '/etc/key.pem');
  for (const text of [script1, script2]) { assert.ok(text.startsWith('#!/usr/bin/env bash\n')); const r = spawnSync('/bin/bash', ['-n'], { input: text, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); }
  assert.match(script2, /root \/bin\/bash \/usr\/local\/bin\/ansgo-docker-sync-manual-cert/);
  const e = b.get('state.cert'); change(e.mode.input, 'acme'); input(b.document.querySelector('#dynu_api_key'), 'fake-api-key'); input(b.document.querySelector('#acme_email'), 'admin@your-domain.com');
  await click(findButton(e.form.root, '保存来源设置')); const payload = b.posts.find(p => p.key === 'cert/config').body; assert.equal(payload.dynu_api_key, 'fake-api-key'); assert.equal(payload.acme_email, 'admin@your-domain.com');
});
await test('节点 Naive 固定域名，其余含落地优先 IP；复制和二维码使用完整原始 URI', async () => {
  const b = await boot(); await b.tab('node'); const root = b.document.querySelector('#content'), naive = root.querySelector('[data-fold="node.naive"]'), anytls = root.querySelector('[data-fold="node.anytls"]'), landing = root.querySelector('[data-fold="node.landing.1"]');
  assert.match(naive.textContent, /your-domain\.com/); assert.ok(!naive.textContent.includes('203.0.113.7')); assert.match(anytls.textContent, /203\.0\.113\.7/); assert.match(landing.textContent, /203\.0\.113\.7/);
  await click(findButton(naive, '复制 URI')); await click(findButton(naive, '二维码')); assert.equal(b.copies.at(-1), b.fixture.data.node.naive.uri); assert.equal(b.qr.at(-1), b.copies.at(-1));
});
await test('节点/落地/设置/证书/日志恶意字符串只作为文本与 value，不生成标签', async () => {
  const b = await boot(), hostile = '<img onerror="alert(1)" src=x>\'" `${alert(2)}` & <svg/onload=alert(3)>';
  b.fixture.data.node.landings[0].name = hostile; b.fixture.data.node.landings[0].uri = hostile; b.fixture.data.node.anytls.password = hostile;
  b.fixture.data.landings.landings[0].name = hostile; b.fixture.data.settings.panel_title = hostile; b.fixture.data['cert/config'].fullchain = hostile; b.fixture.data['cert/config'].host_fullchain = hostile; b.fixture.data.logs.logs = hostile;
  for (const tab of ['node', 'landing', 'set', 'cert', 'log']) {
    await b.tab(tab); if (tab === 'log') await click(findButton(b.document.querySelector('#content'), '刷新日志'));
    assert.equal(b.document.querySelector('#content').querySelectorAll('img').length, 0);
    assert.ok(b.document.querySelector('#content').textContent.includes(hostile) || b.document.querySelectorAll('input').some(n => n.value === hostile), tab + ' 完整保留特殊字符');
  }
  await b.tab('set'); assert.equal(b.document.querySelector('#s_panel_title').value, hostile);
});
await test('统一 api 识别 401 并回登录，重新登录恢复当前卡片草稿', async () => {
  const b = await boot(); await b.tab('landing'); const first = b.get('state.landings.get("1")'); input(first.inputs.name, '失效会话草稿');
  b.ctx.intercept = key => key === 'logs' ? { status: 401, body: { error: 'unauthorized' } } : null;
  await assert.rejects(b.ctx.api('api/logs'), /会话已过期/); assert.equal(b.document.querySelector('#login').hidden, false); assert.equal(b.document.querySelector('#app').hidden, true);
  b.ctx.intercept = null; await b.ctx.doLogin(); await settle(); assert.equal(b.document.querySelector('#app').hidden, false); assert.equal(first.inputs.name.value, '失效会话草稿'); assert.equal(first.root.isConnected, true);
});
await test('加载新页面时遇到 401，登录后重新加载目标页面，不停在加载占位', async () => {
  const b = await boot();
  b.ctx.intercept = key => key === 'node' ? { status: 401, body: { error: 'expired' } } : null;
  await b.ctx.showTab('node'); assert.equal(b.document.querySelector('#app').hidden, true);
  b.ctx.intercept = null; await b.ctx.doLogin(); await settle();
  assert.equal(b.get('state.tab'), 'node'); assert.ok(b.document.querySelector('[data-fold="node.anytls"]')); assert.equal(b.document.querySelector('#app').hidden, false);
});
await test('统一 api 识别 ok:false / errors / error+hint / 日志错误；请求均相对路径', async () => {
  const b = await boot();
  for (const body of [{ ok: false, errors: ['first', 'second'] }, { error: 'bad', hint: 'repair' }, { ok: false, msg: '签发失败', log: 'safe-log' }, { ok: false }]) {
    b.ctx.intercept = () => ({ status: 200, body }); await assert.rejects(b.ctx.api('api/service')); const text = b.document.querySelector('#toast').textContent; if (body.hint) assert.match(text, /bad\nrepair/); if (body.errors) assert.match(text, /first；second/);
  }
  assert.ok(b.requests.every(r => !r.key.startsWith('/')));
});
await test('旧页面慢响应不会覆盖新页面', async () => {
  const b = await boot(); let resolve;
  b.ctx.intercept = key => key === 'node' ? new Promise(r => resolve = r) : null;
  const pending = b.ctx.showTab('node', { force: true }); await settle(); await b.tab('system'); resolve({ status: 200, body: b.fixture.data.node }); await pending;
  assert.equal(b.get('state.tab'), 'system'); assert.match(b.document.querySelector('#content').textContent, /系统维护/); assert.equal(b.document.querySelector('[data-fold="node.anytls"]'), null);
});
await test('服务只提交变化的凭证/端口；未安装服务先保存编辑值再安装', async () => {
  const b = await boot(); await b.tab('mgmt'); let e = b.get('state.services.get("anytls")'); input(e.inputs.pass, 'edited-password'); await click(findButton(e.root, '保存修改'));
  assert.equal(b.posts.filter(p => p.key === 'port').length, 0); assert.equal(b.posts.find(p => p.key === 'key').body.pass, 'edited-password');
  e = b.get('state.services.get("socks")'); input(e.inputs.port, 24500); input(e.inputs.pass, 'before-install'); await click(findButton(e.root, '保存参数并安装'));
  const posts = b.posts.slice(1); assert.deepEqual(posts.map(p => p.key), ['port', 'key', 'svc-install']); assert.equal(posts[0].body.port, 24500); assert.equal(posts[1].body.pass, 'before-install');
});
await test('SS256 随机密钥为 32 字节；非法凭证在端口提交前拦截', async () => {
  const b = await boot(); await b.tab('mgmt'); const e = b.get('state.services.get("ss")');
  input(e.inputs.method, '2022-blake3-aes-256-gcm');
  const random = e.inputs.key.parentNode.querySelector('button'); await click(random);
  assert.equal(Buffer.from(e.inputs.key.value, 'base64').length, 32);
  const naive = b.get('state.services.get("naive")'); input(naive.inputs.port, 25000); input(naive.inputs.pass, 'invalid password');
  await click(findButton(naive.root, '保存修改')); assert.equal(b.posts.length, 0); assert.match(b.document.querySelector('#toast').textContent, /不能包含/);
});
await test('服务保存按钮 loading 去重，失败保留草稿并给出 hint', async () => {
  const b = await boot(); await b.tab('mgmt'); const e = b.get('state.services.get("anytls")'), btn = findButton(e.root, '保存修改'); input(e.inputs.pass, 'draft'); let finish;
  b.ctx.intercept = (key, method) => key === 'key' && method === 'POST' ? new Promise(resolve => finish = resolve) : null;
  btn.click(); btn.click(); await settle(); assert.equal(btn.disabled, true); assert.equal(btn.getAttribute('aria-busy'), 'true'); assert.equal(b.posts.filter(p => p.key === 'key').length, 1);
  finish({ status: 500, body: { ok: false, error: 'failed', hint: 'restore configuration' } }); await settle(); assert.equal(btn.disabled, false); assert.equal(e.inputs.pass.value, 'draft'); assert.equal(e.mark.hidden, false); assert.match(b.document.querySelector('#toast').textContent, /restore configuration/);
});
await test('设置只发变更字段，空 IP 不覆盖自动值；no-caddy 不提交隐藏字段', async () => {
  const b = await boot(); b.fixture.data.settings.server_ip = ''; b.fixture.data.settings.caddy_enable = 'false'; await b.tab('set'); input(b.document.querySelector('#s_panel_title'), 'New-title');
  await click(findButton(b.document.querySelector('#content'), '保存设置')); assert.deepEqual(b.posts.at(-1).body, { panel_title: 'New-title' });
  input(b.document.querySelector('#s_server_ip'), '203.0.113.8'); await click(findButton(b.document.querySelector('#content'), '保存设置')); assert.equal(b.posts.at(-1).body.server_ip, '203.0.113.8');
  input(b.document.querySelector('#s_server_ip'), ''); await click(findButton(b.document.querySelector('#content'), '保存设置')); assert.equal(b.posts.at(-1).body.server_ip, '');
});
await test('系统维护显示资源/占用/上限，策略保存与清理显示释放空间', async () => {
  const b = await boot(); await b.tab('system'); const root = b.document.querySelector('#content');
  for (const text of ['系统维护', '物理内存', 'Journal', '配置备份', '64M', '96M', '80M']) assert.ok(root.textContent.includes(text));
  input(b.document.querySelector('#backup_keep'), 7); await click(findButton(root, '保存策略')); assert.equal(b.posts.at(-1).key, 'settings'); assert.equal(b.posts.at(-1).body.backup_keep, 7);
  await click(findButton(root, '一键清理')); assert.match(root.textContent, /已释放 22\.0 MB/); await click(findButton(root, '检查更新')); assert.match(root.textContent, /发现新版本/);
});
await test('Docker 禁用自动/一键升级并显示宿主升级命令', async () => {
  const b = await boot({ docker: true }); await b.tab('system'); const root = b.document.querySelector('#content'); assert.equal(findButton(root, '一键升级').disabled, true); assert.equal(root.querySelector('select').disabled, true); assert.match(root.textContent, /curl -fsSL https:\/\/raw\.githubusercontent\.com\/6667084\/ANS-GO\/main\/deploy\/upgrade\.sh \| bash/);
});
await test('升级轮询在面板离线时重试，恢复后展示结果并刷新版本', async () => {
  const b = await boot(); await b.tab('system'); const start = findButton(b.document.querySelector('#content'), '一键升级'); await click(start); assert.equal(b.get('state.upgrading'), true); assert.equal(start.disabled, true); await click(start); assert.equal(b.posts.filter(p => p.key === 'system/upgrade').length, 1);
  b.ctx.intercept = key => key === 'system/upgrade-status' ? Promise.reject(new Error('offline')) : null; await b.ctx.pollUpgrade(); assert.match(b.document.querySelector('#upgradeMessage').textContent, /自动重连/);
  b.ctx.intercept = null; await b.ctx.pollUpgrade(); await b.ctx.pollUpgrade(); assert.equal(b.get('state.upgrading'), false); assert.match(b.document.querySelector('#upgradeMessage').textContent, /升级成功/); assert.match(b.document.querySelector('#upgradeLog').textContent, /面板已恢复/);
});
await test('启动新升级后忽略旧 success 残留，必须观察到新任务状态', async () => {
  const b = await boot(), stale = { running: false, result: 'success', log: 'old success' };
  b.fixture.data['system/upgrade-status'] = stale; await b.tab('system');
  let phase = 'stale';
  b.ctx.intercept = key => key === 'system/upgrade-status' ? { status: 200, body: phase === 'stale' ? stale : phase === 'running' ? { running: true, result: '', log: 'new task' } : { running: false, result: 'success', log: 'new success' } } : null;
  await click(findButton(b.document.querySelector('#content'), '一键升级'));
  assert.equal(b.get('state.upgrading'), true); assert.match(b.document.querySelector('#upgradeMessage').textContent, /等待/);
  phase = 'running'; await b.ctx.pollUpgrade(); phase = 'success'; await b.ctx.pollUpgrade(); assert.equal(b.get('state.upgrading'), false);
});
await test('删除最后落地再创建时正确切换空态，不积累旧提示', async () => {
  const b = await boot(); await b.tab('landing');
  await click(findButton(b.get('state.landings.get("1").root'), '删除')); await click(findButton(b.get('state.landings.get("2").root'), '删除'));
  const empty = b.document.querySelector('#landingList').nextElementSibling; assert.equal(empty.hidden, false);
  const form = b.document.querySelector('[data-fold="landing.create"]'), inputs = form.querySelectorAll('input'); input(inputs[0], 'new'); input(inputs[1], 24500);
  await click(findButton(form, '创建落地')); assert.equal(empty.hidden, true); assert.equal(b.document.querySelector('#content').querySelectorAll('.empty').length, 1);
});
await test('折叠栏目/主题/侧栏本地记忆；服务和高级栏目默认折叠', async () => {
  const b = await boot(); await b.tab('mgmt'); const e = b.get('state.services.get("ss")'); assert.equal(e.root.open, false);
  await click(findButton(b.document.querySelector('#content'), '全部展开')); assert.equal(e.root.open, true); assert.equal(b.storage.get('ansgo_fold:service.ss'), 'open'); await b.tab('node'); await b.tab('mgmt'); assert.equal(b.get('state.services.get("ss").root.open'), true);
  b.ctx.toggleTheme(); assert.equal(b.storage.get('ansgo_theme'), 'light'); b.document.querySelector('#collapseBtn').click(); assert.equal(b.storage.get('ansgo_sidebar'), 'collapsed');
});
console.log(`\nPASS=${passed} FAIL=0`);
