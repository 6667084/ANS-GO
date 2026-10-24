#!/usr/bin/env node
// 零依赖本地假后端；仅使用保留 IP、示例域名与假凭证。也供 VM 回归测试复用。
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
export function createFixture({ docker = false, certMode = 'acme', dynu = 'apikey' } = {}) {
  const domain = 'your-domain.com', ip = '203.0.113.7', password = 'fake-password', ssKey = 'AAAAAAAAAAAAAAAAAAAAAA==';
  const cert = { subject: domain, issuer: "Let's Encrypt", issuer_org: "Let's Encrypt", not_before: '2026-10-01', not_after: '2026-12-30', days_left: 67 };
  const landings = [
    { id: '1', name: '远端出口', enabled: true, port: 23461, has_keys: true, password, uuid: 'fake-uuid', remote_enabled: true, remote_type: 'ss', remote_ss: { host: '203.0.113.20', port: 8388, method: '2022-blake3-aes-128-gcm', password: ssKey }, remote_socks: { host: '203.0.113.21', port: 1080, user: 'fake-user', password: 'fake-socks-password' }, remote_via: 'ss-landing' },
    { id: '2', name: '备用线路', enabled: false, port: 23462, has_keys: true, password, uuid: 'fake-uuid-2', remote_enabled: false, remote_type: 'socks', remote_ss: {}, remote_socks: {}, remote_via: 'direct' },
  ];
  const data = {
    auth: { authed: true, user: 'admin', version: '1.6.0-dev' },
    dashboard: {
      services: { anytls: 'active', naive: 'active', ss: 'active', socks: 'inactive', panel: 'active', caddy: 'active', 'sing-box': 'active' },
      svc_enabled: { anytls: true, naive: true, ss: true, socks: false },
      ports: { anytls: 23458, naive: 23460, ss: 23457, socks: 23459, panel: 23456 },
      mem: { total: 262144, used: 82432, avail: 179712 }, load: [0.12, 0.08, 0.05], uptime: 72.5, tcp: 18, domain, cert, landings_enabled: 1,
    },
    node: {
      domain, server_ip: ip, server_ip_hint: '',
      anytls: { enabled: true, host: ip, port: 23458, sni: domain, password, uri: `anytls://${password}@${ip}:23458/?sni=${domain}#Demo-AT` },
      naive: { enabled: true, host: domain, port: 23460, user: 'fake-user', pass: password, password, sni: domain, uri: `naive+https://fake-user:${password}@${domain}:23460#Demo-NV` },
      ss: { enabled: true, host: ip, port: 23457, password: ssKey, method: '2022-blake3-aes-128-gcm', uri: `ss://${Buffer.from('2022-blake3-aes-128-gcm:' + ssKey).toString('base64url')}@${ip}:23457#Demo-SS` },
      socks: { enabled: false, host: ip, port: 23459, user: 'fake-user', pass: password, password, uri: '' }, landings: [],
    },
    settings: { domain, panel_title: 'Demo', url_path: '/fixture01/', admin_user: 'admin', session_hours: 8, panel_port: 23456, login_lock_threshold: 5, login_lock_minutes: 10, server_ip: ip, server_ip_resolved: ip, server_ip_hint: '', caddy_enable: 'true', disguise_panel: 'page', disguise_naive: 'proxy:https://your-domain.com', anytls_port: 23458, naive_port: 23460, ss_port: 23457, socks_port: 23459, backup_keep: 5 },
    landings: { landings }, cert,
    'cert/config': { mode: certMode, docker_mode: docker, domain, fullchain: '/etc/ssl/ansgo/fullchain.pem', privkey: '/etc/ssl/ansgo/privkey.pem', host_fullchain: '/etc/letsencrypt/live/your-domain.com/fullchain.pem', host_privkey: '/etc/letsencrypt/live/your-domain.com/privkey.pem', runtime_fullchain: '/etc/ssl/ansgo/fullchain.pem', runtime_privkey: '/etc/ssl/ansgo/privkey.pem', cert_info: cert, dynu: { has_api_key: ['apikey', 'both'].includes(dynu), has_oauth: ['oauth', 'both'].includes(dynu) }, acme_email: 'admin@your-domain.com' },
    'detect-public-ip': { ok: true, ip, source: 'fixture' },
    logs: { logs: 'Oct 24 12:00:01 ansgo-panel: 面板已启动（本地假数据）\nOct 24 12:00:02 sing-box: AnyTLS inbound ready\nOct 24 12:00:03 caddy: TLS certificate loaded' },
    'system/info': { version: 'v1.6.0-dev', deploy_mode: docker ? 'docker' : 'metal', arch: 'amd64', auto_upgrade: false, auto_upgrade_supported: !docker, upgrade_supported: !docker, mem_total_kb: 262144, disk: { total: 4 * 1024 ** 3, used: 1.2 * 1024 ** 3, avail: 2.8 * 1024 ** 3 }, usage: { backups_bytes: 42 * 1024 ** 2, backups_count: 5, journal_bytes: 8 * 1024 ** 2, logs_bytes: 128 * 1024, probe_tmp_bytes: 0 }, limits: { panel_mem_max: '64M', singbox_mem_max: '96M', caddy_mem_max: '80M' } },
    'system/upgrade-status': { running: false, result: '', log: '' },
  };
  let nextId = 3, upgradeStep = -1;
  function syncNodes() {
    for (const key of ['ss', 'anytls', 'socks', 'naive']) {
      const n = data.node[key], host = key === 'naive' ? domain : ip;
      n.host = host;
      if (!n.enabled) { n.uri = ''; continue; }
      const secret = encodeURIComponent(n.password), user = encodeURIComponent(n.user || '');
      if (key === 'ss') n.uri = `ss://${Buffer.from(n.method + ':' + n.password).toString('base64url')}@${host}:${n.port}#Demo-SS`;
      else if (key === 'anytls') n.uri = `anytls://${secret}@${host}:${n.port}/?sni=${domain}#Demo-AT`;
      else n.uri = `${key === 'socks' ? 'socks5' : 'naive+https'}://${user}:${secret}@${host}:${n.port}#Demo-${key === 'socks' ? 'SK' : 'NV'}`;
    }
    for (const l of landings) l.remote_via = l.remote_enabled ? (l.remote_type === 'ss' ? 'ss-landing' : 'socks5-landing') : 'direct';
    data.node.landings = landings.filter(l => l.enabled).map(l => ({ ...l, host: ip, sni: domain, via: l.remote_enabled ? (l.remote_type === 'ss' ? 'ss-landing' : 'socks5-landing') : 'direct', uri: `anytls://${l.password}@${ip}:${l.port}/?sni=${domain}#Demo-LD-${encodeURIComponent(l.name)}` }));
  }
  syncNodes();
  const response = (body, status = 200) => ({ status, body: structuredClone(body) });
  function request(key, method = 'GET', body = {}) {
    key = key.split('?')[0];
    if (method === 'GET') {
      if (key === 'system/upgrade-status' && upgradeStep >= 0) {
        upgradeStep++;
        data[key] = { running: upgradeStep < 3, result: upgradeStep < 3 ? '' : 'success', log: '[fixture] 下载与校验完成\n[fixture] 备份完成\n' + (upgradeStep < 3 ? '正在重新启动面板…' : '升级成功，面板已恢复') };
      }
      return data[key] ? response(data[key]) : response({ error: '未知夹具接口' }, 404);
    }
    switch (key) {
      case 'login': data.auth.authed = true; return response({ ok: true });
      case 'logout': data.auth.authed = false; return response({ ok: true });
      case 'settings': Object.assign(data.settings, body); break;
      case 'cert/config': {
        const { dynu_api_key, ...fields } = body;
        Object.assign(data[key], fields);
        if (dynu_api_key) data[key].dynu.has_api_key = true;
        break;
      }
      case 'cert/issue': case 'cert/renew': case 'cert/reload': return response({ ok: true, cert, log: 'fixture：证书操作完成（假数据）' });
      case 'landings': {
        const l = { ...structuredClone(landings[0]), ...body, id: String(nextId++), password: 'fake-new-password', remote_enabled: false };
        landings.push(l); syncNodes(); return response({ ok: true, landing: l });
      }
      case 'landings/update': case 'landings/regen': case 'landings/delete': {
        const index = landings.findIndex(l => l.id === String(body.id));
        if (index < 0) return response({ error: '落地不存在' }, 404);
        if (key.endsWith('delete')) landings.splice(index, 1);
        else if (key.endsWith('regen')) landings[index].password = 'fake-regenerated-password';
        else Object.assign(landings[index], body);
        syncNodes(); return response({ ok: true, landing: landings[index] });
      }
      case 'port': data.dashboard.ports[body.target] = body.port; if (data.node[body.target]) data.node[body.target].port = body.port; break;
      case 'key': {
        const n = data.node[body.target]; if (!n) return response({ error: '未知服务' }, 400);
        Object.assign(n, { ...body, password: body.key || body.pass || n.password }); break;
      }
      case 'service': data.dashboard.services[body.target] = body.action === 'stop' ? 'inactive' : 'active'; break;
      case 'svc-install': data.dashboard.svc_enabled[body.service] = body.action === 'install'; data.dashboard.services[body.service] = body.action === 'install' ? 'active' : 'inactive'; data.node[body.service].enabled = body.action === 'install'; break;
      case 'regen': data.node[body.target].password = 'fake-regenerated-password'; break;
      case 'repair': return response({ ok: true, results: { 'sing-box': { ok: true, active: 'active' }, caddy: { ok: true, active: 'active' } } });
      case 'health': return response({ ok: true, target: body.target, unit: body.target === 'naive' ? 'caddy' : 'sing-box', enabled: true, active: 'active', port: '23458', port_listening: 'yes', tcp_connect: 'yes', tcp_ms: 3, landing_remote: body.target.startsWith('landing-') ? 'skip' : '', time_diag: { now_local: '2026-10-24 12:00:00', now_utc: '2026-10-24 04:00:00', timezone: 'Asia/Singapore', offset: '+08:00', ntp_synchronized: docker ? 'host' : 'yes' }, summary: '假数据：入口与 TCP 握手正常' });
      case 'system/check-update': return response({ ok: true, current: 'v1.6.0-dev', latest: 'v1.6.0', has_update: true, url: '' });
      case 'system/upgrade': if (docker) return response({ ok: false, error: 'Docker 请在宿主升级', hint: '使用宿主升级命令' }); upgradeStep = 0; return response({ ok: true, started: true });
      case 'system/auto-upgrade': if (docker) return response({ ok: false, error: 'Docker 不支持自动升级' }); data['system/info'].auto_upgrade = body.enabled; return response({ ok: true, enabled: body.enabled });
      case 'system/cleanup': data['system/info'].usage.backups_bytes = 20 * 1024 ** 2; return response({ ok: true, freed_bytes: 22 * 1024 ** 2, log: 'fixture：清理旧备份和过期日志完成' });
      default: return response({ error: '未知夹具接口' }, 404);
    }
    syncNodes();
    return response({ ok: true });
  }
  return { data, request };
}

export function startFixture(port = Number(process.env.PORT || 8788)) {
  const fixture = createFixture({ docker: process.env.ANSGO_FIXTURE_DOCKER === '1', certMode: process.env.ANSGO_FIXTURE_CERT_MODE || 'acme', dynu: process.env.ANSGO_FIXTURE_DYNU || 'apikey' });
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let path = url.pathname.replace(/^\/fixture01(?=\/)/, '');
    const send = (status, body, type = 'application/json; charset=utf-8') => { res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' }); res.end(typeof body === 'string' ? body : JSON.stringify(body)); };
    if (path === '/' || path === '/index.html') return send(200, readFileSync(join(ROOT, 'deploy/panel/web/index.html'), 'utf8'), 'text/html; charset=utf-8');
    if (path === '/static/qrcode.min.js') return send(200, readFileSync(join(ROOT, 'deploy/panel/web/qrcode.min.js'), 'utf8'), 'application/javascript');
    if (!path.startsWith('/api/')) return send(404, 'not found', 'text/plain');
    let body = '';
    req.on('data', c => { body += c; if (body.length > 65536) req.destroy(); });
    req.on('end', () => { try { const r = fixture.request(path.slice(5), req.method, body ? JSON.parse(body) : {}); send(r.status, r.body); } catch { send(400, { error: '无效 JSON' }); } });
  });
  server.listen(port, '127.0.0.1', () => console.log(`ANS-GO v1.6.0 UI 夹具（假数据） http://127.0.0.1:${port}/fixture01/`));
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) startFixture();
