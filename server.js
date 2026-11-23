#!/usr/bin/env node
'use strict';
// Firebase Events Live: local server. No dependencies, needs only `adb` and Node 18+.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile, spawn } = require('child_process');
const { parseLine, createBatchParser } = require('./parser');

const PORT = process.env.PORT || 4455;
const LOCAL_ADB = path.join(__dirname, 'runtime', 'platform-tools', process.platform === 'win32' ? 'adb.exe' : 'adb');
const ADB = process.env.ADB || (fs.existsSync(LOCAL_ADB) ? LOCAL_ADB : 'adb');
const SESSIONS = process.env.SESSIONS_DIR || path.join(process.cwd(), 'sessions');
const clients = new Set();
let logcat = null, session = null, seq = 0, msgs = [];
let allEvents = [], pendingIds = [];

const adb = (args, opts = {}) => new Promise((res, rej) =>
  execFile(ADB, args, { maxBuffer: 64 * 1024 * 1024, encoding: opts.binary ? 'buffer' : 'utf8', timeout: opts.timeout || 15000 },
    (e, out, err) => e ? rej(new Error((err && err.toString().trim()) || e.message)) : res(out)));

const emit = (obj, keep) => { if (keep) msgs.push(obj); const s = `data: ${JSON.stringify(obj)}\n\n`; for (const c of clients) c.write(s); };
const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const readBody = (req) => new Promise((r) => { const b = []; req.on('data', d => b.push(d)); req.on('end', () => r(Buffer.concat(b))); });
const body = async (req) => { try { return JSON.parse((await readBody(req)).toString() || '{}'); } catch { return {}; } };

// Bounds of the target app window (to crop status / nav bars), null if not in foreground.
async function appBounds(serial, pkg) {
  let out = '';
  try { out = await adb(['-s', serial, 'shell', "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp|Window #|mFrame='"]); } catch { return null; }
  if (!out.includes(pkg)) return null;
  let inT = false;
  for (const line of out.split(/\r?\n/)) {
    if (line.includes('Window #') && line.includes(pkg)) inT = true;
    else if (line.includes('Window #')) inT = false;
    else if (inT) {
      const m = line.match(/mFrame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
      if (m) { const [x, y, r, b] = m.slice(1).map(Number); if (r - x > 200 && b - y > 200) return { x, y, w: r - x, h: b - y }; }
    }
  }
  return { full: true };
}

function writeCsv() {
  if (!session || !allEvents.length) return;
  const keys = [...new Set(allEvents.flatMap(e => Object.keys(e.params)))].sort();
  const q = (s) => '"' + String(s ?? '').replace(/"/g, '""') + '"';
  const head = ['Time', 'EventName', 'Screenshot', 'AnnotatedScreenshot', ...keys, 'FullObject'];
  const rows = allEvents.map(e => [e.time, e.name, e.shot || '', e.annotated || '', ...keys.map(k => e.params[k]), e.full || ''].map(q).join(';'));
  fs.writeFileSync(path.join(session.dir, 'firebase_report.csv'), '﻿' + [head.map(q).join(';'), ...rows].join('\r\n'));
}

async function onBatchEnd(time) {
  const ids = pendingIds; pendingIds = [];
  if (!ids.length || !session) return;
  const evs = allEvents.filter(e => ids.includes(e.id));
  const base = `${time.replace(/[:.]/g, '-')}_batch_${evs.length}events`;
  const batch = { type: 'batch', id: base, time, eventIds: ids, shot: null, bounds: null };
  emit({ ...batch }, false);   // immediate: client shows the batch, screenshot follows
  try {
    const bounds = await appBounds(session.serial, session.pkg);
    if (bounds) {
      const png = await adb(['-s', session.serial, 'exec-out', 'screencap', '-p'], { binary: true, timeout: 8000 });
      const rel = `screenshots/${base}.png`;
      fs.writeFileSync(path.join(session.dir, rel), png);
      batch.shot = rel; batch.bounds = bounds;
      evs.forEach(e => { e.shot = rel; e.annotated = `screenshots/${base}_sidebyside.png`; });
    } else evs.forEach(e => { e.shot = 'SKIPPED (not in foreground)'; e.annotated = e.shot; });
  } catch { /* screenshot is best-effort */ }
  msgs.push(batch); emit({ type: 'batch-update', batch }, false);
  writeCsv();
}

async function stop() {
  if (logcat) { const l = logcat; logcat = null; l.kill(); }
  if (session) {
    writeCsv();
    await adb(['-s', session.serial, 'shell', 'setprop', 'debug.firebase.analytics.app', '.none.']).catch(() => {});
    const dir = session.dir; session = null;
    emit({ type: 'status', running: false, dir }, false);
  } else emit({ type: 'status', running: false }, false);
}

async function start(serial, pkg, mode) {
  await stop();
  if (!/^[\w.]+$/.test(pkg)) throw new Error('Invalid package name');
  const sh = (...a) => adb(['-s', serial, 'shell', ...a]);
  await sh('setprop', 'debug.firebase.analytics.app', pkg);
  await sh('setprop', 'log.tag.FA', 'VERBOSE');
  await sh('setprop', 'log.tag.FA-SVC', 'VERBOSE');
  const stamp = new Date().toISOString().replace(/T/, '_').replace(/:/g, '-').slice(0, 19);
  const dir = path.join(SESSIONS, `QA_Run_${stamp}`);
  fs.mkdirSync(path.join(dir, 'screenshots'), { recursive: true });
  session = { serial, pkg, mode, dir };
  msgs = []; allEvents = []; pendingIds = [];
  const parser = createBatchParser();
  const tags = mode === 'instant' ? ['FA:V', 'FA-SVC:S'] : ['FA-SVC:V'];
  logcat = spawn(ADB, ['-s', serial, 'logcat', '-v', 'time', '-T', '1', '-s', ...tags]);
  let buf = '';
  const push = (ev) => { ev.id = ++seq; allEvents.push(ev); if (mode !== 'instant') pendingIds.push(ev.id); emit({ type: 'event', event: ev }, true); };
  logcat.stdout.on('data', (d) => {
    buf += d; const lines = buf.split(/\r?\n/); buf = lines.pop();
    for (const l of lines) {
      if (mode === 'instant') { const ev = parseLine(l); if (ev) push(ev); continue; }
      for (const r of parser.feed(l)) { if (r.type === 'event') push(r.event); else onBatchEnd(r.time); }
    }
  });
  logcat.on('exit', () => { if (logcat) { logcat = null; writeCsv(); session = null; emit({ type: 'status', running: false, error: 'logcat stopped (device disconnected?)' }, false); } });
  emit({ type: 'status', running: true, serial, pkg, mode, dir }, false);
}

const MIME = { '.html': 'text/html', '.png': 'image/png', '.csv': 'text/csv', '.js': 'text/javascript', '.css': 'text/css' };
const safeJoin = (root, rel) => { const f = path.join(root, path.normalize(rel)); return f.startsWith(root + path.sep) ? f : null; };
const serveFile = (res, f) => {
  if (!f || !fs.existsSync(f) || !fs.statSync(f).isFile()) { res.writeHead(404); return res.end('Not found'); }
  res.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream', 'cache-control': 'no-store' });
  fs.createReadStream(f).pipe(res);
};

const routes = {
  'GET /api/devices': async () => {
    const out = await adb(['devices', '-l']);
    return out.split('\n').slice(1).filter(l => l.trim()).map(l => {
      const [serial, state, ...rest] = l.trim().split(/\s+/);
      return { serial, state, model: (rest.find(x => x.startsWith('model:')) || '').slice(6) };
    });
  },
  'POST /api/pair': async (req) => { const b = await body(req); return { out: await adb(['pair', b.addr, b.code]) }; },
  'POST /api/connect': async (req) => { const b = await body(req); return { out: await adb(['connect', b.addr]) }; },
  'GET /api/packages': async (req, url) => {
    const out = await adb(['-s', url.searchParams.get('serial'), 'shell', 'pm', 'list', 'packages', '-3']);
    return out.split('\n').map(l => l.replace('package:', '').trim()).filter(Boolean).sort();
  },
  'POST /api/start': async (req) => { const b = await body(req); await start(b.serial, b.pkg, b.mode === 'instant' ? 'instant' : 'batch'); return { ok: true, dir: session.dir }; },
  'POST /api/stop': async () => { await stop(); return { ok: true }; },
  'POST /api/clear': async () => { msgs = []; allEvents = []; pendingIds = []; return { ok: true }; },
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'GET' && url.pathname === '/api/stream') {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      clients.add(res);
      res.write(`data: ${JSON.stringify({ type: 'status', running: !!session, ...(session || {}) })}\n\n`);
      for (const m of msgs) res.write(`data: ${JSON.stringify(m)}\n\n`);
      req.on('close', () => clients.delete(res));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/screen') {
      const png = await adb(['-s', url.searchParams.get('serial'), 'exec-out', 'screencap', '-p'], { binary: true, timeout: 8000 });
      res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'no-store' });
      return res.end(png);
    }
    // Client uploads cropped / side-by-side PNGs so they land in the session folder.
    if (req.method === 'POST' && url.pathname === '/api/save') {
      if (!session) return json(res, 400, { error: 'No session' });
      const name = (url.searchParams.get('name') || '').replace(/[^\w.-]/g, '');
      if (!name.endsWith('.png')) return json(res, 400, { error: 'bad name' });
      fs.writeFileSync(path.join(session.dir, 'screenshots', name), await readBody(req));
      return json(res, 200, { ok: true });
    }
    if (req.method === 'GET' && url.pathname === '/api/csv') {
      writeCsv();
      return serveFile(res, session && path.join(session.dir, 'firebase_report.csv'));
    }
    if (req.method === 'GET' && url.pathname.startsWith('/shots/') && session)
      return serveFile(res, safeJoin(session.dir, url.pathname.slice(7)));
    const h = routes[`${req.method} ${url.pathname}`];
    if (h) return json(res, 200, await h(req, url));
    const pub = path.join(__dirname, 'public');
    return serveFile(res, safeJoin(pub, url.pathname === '/' ? 'index.html' : url.pathname.slice(1)));
  } catch (e) {
    json(res, 500, { error: e.message });
  }
});

process.on('SIGINT', async () => { await stop(); process.exit(0); });
server.listen(PORT, '127.0.0.1', () => console.log(`Firebase Events Live: http://localhost:${PORT}\nSessions saved in: ${SESSIONS}`));
