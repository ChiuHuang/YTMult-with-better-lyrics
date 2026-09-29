/* YTMU JWT Uploader -- service worker.
 *
 * What it does, in one line: get a Cubey JWT in a hidden tab and push it into
 * the server pool (POST /api/admin/jwt/contribute) whenever you ask.
 *
 * The JWT itself never touches disk. Only a length, the first 8 characters and
 * the exp claim are kept, for the log line.
 *
 * Auth: every server call is behind the dashboard session cookie. The call is
 * first made from the extension (host_permissions bypass CORS). If that comes
 * back as the login page -- which is what a SameSite=Lax session cookie does to
 * a cross-origin POST -- the same call is re-run inside a tab that is already
 * on the server, where it is an ordinary same-origin request. That tab path
 * always works as long as the browser has a dashboard session, so one manual
 * login in a normal tab is all the setup there is.
 */
'use strict';

var CUBEY_ORIGIN = 'https://lyrics.api.dacubeking.com';
var CHALLENGE_URL = CUBEY_ORIGIN + '/challenge';
var VERIFY_URL = CUBEY_ORIGIN + '/verify-turnstile';
var DEFAULT_SERVER = 'http://localhost:20016';
var SOURCE = 'chrome-ext';
var FLOW_TIMEOUT_MS = 90000;
var LOG_MAX = 60;
var LOG_VIEW = 14;

var K_CFG = 'cfg';
var K_JOB = 'job';
var K_LOG = 'log';
var K_POOL = 'pool';
var K_LAST = 'lastUpload';

var ALARM_FLOW = 'ytmu-flow-timeout';
var ALARM_AUTO = 'ytmu-auto';

// ---------- small helpers ----------

function sleep(ms) {
  return new Promise(function (r) { setTimeout(r, ms); });
}

function clip(value, n) {
  if (value === null || value === undefined) return '';
  return String(value).replace(/\s+/g, ' ').trim().slice(0, n || 140);
}

function errText(e) {
  return String((e && e.message) || e || 'error');
}

function normalizeServer(raw) {
  if (!raw) return '';
  var s = String(raw).trim();
  if (!s) return '';
  if (!/^https?:\/\//i.test(s)) s = 'http://' + s;
  try {
    var u = new URL(s);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    var path = (u.pathname || '/').replace(/\/+$/, '');
    return u.origin + path;
  } catch (e) {
    return '';
  }
}

function originOf(url) {
  try {
    var u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    return u.origin;
  } catch (e) {
    return '';
  }
}

function pathOf(url) {
  try {
    return new URL(url).pathname;
  } catch (e) {
    return '';
  }
}

function isHtml(text) {
  return /^\s*<(!doctype|html)/i.test(String(text || ''));
}

function decodeExp(jwt) {
  var parts = String(jwt || '').split('.');
  if (parts.length !== 3) return null;
  try {
    var b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    b64 += new Array(5 - (b64.length % 4)).join('=');
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    var obj = JSON.parse(new TextDecoder('utf-8').decode(bytes));
    return typeof obj.exp === 'number' ? obj.exp : null;
  } catch (e) {
    return null;
  }
}

/* Safe description of a token: never the token itself. */
function describeToken(jwt) {
  var text = String(jwt || '');
  var exp = decodeExp(text);
  var out = { len: text.length, head: text.slice(0, 8), exp: exp, expIn: null };
  if (exp) {
    out.expIn = Math.round((exp * 1000 - Date.now()) / 60000);
    out.expNote = out.expIn >= 0 ? ('exp in ' + out.expIn + ' min') : ('expired ' + (-out.expIn) + ' min ago');
  } else {
    out.expNote = 'no exp claim';
  }
  return out;
}

// ---------- storage ----------

async function getCfg() {
  var got = await chrome.storage.local.get(K_CFG);
  var c = got[K_CFG] || {};
  return {
    server: normalizeServer(c.server) || DEFAULT_SERVER,
    autoMinutes: Number(c.autoMinutes) || 0
  };
}

async function setCfg(patch) {
  var next = Object.assign(await getCfg(), patch || {});
  next.server = normalizeServer(next.server) || DEFAULT_SERVER;
  next.autoMinutes = Math.max(0, Number(next.autoMinutes) || 0);
  await chrome.storage.local.set({ [K_CFG]: next });
  await syncAutoAlarm(next.autoMinutes);
  await paintTitle();
  return next;
}

async function getJob() {
  var got = await chrome.storage.local.get(K_JOB);
  return got[K_JOB] || null;
}

async function setJob(job) {
  await chrome.storage.local.set({ [K_JOB]: job });
}

async function pushLog(msg) {
  var got = await chrome.storage.local.get(K_LOG);
  var log = got[K_LOG] || [];
  log.push({ t: Date.now(), msg: String(msg) });
  while (log.length > LOG_MAX) log.shift();
  await chrome.storage.local.set({ [K_LOG]: log });
}

async function paintTitle() {
  try {
    var c = await getCfg();
    await chrome.action.setTitle({ title: 'YTMU JWT Uploader -> ' + c.server });
  } catch (e) { /* action API unavailable */ }
}

async function setBadge(text, color) {
  try {
    await chrome.action.setBadgeText({ text: text || '' });
    if (color) await chrome.action.setBadgeBackgroundColor({ color: color });
  } catch (e) { /* action API unavailable */ }
}

async function notify(head, body) {
  try {
    await chrome.notifications.create('ytmu-' + Date.now() + '-' + Math.floor(Math.random() * 1000), {
      type: 'basic',
      title: 'YTMU JWT',
      message: head + ': ' + body
    });
  } catch (e) { /* notifications denied */ }
}

// ---------- server calls (direct, then same-origin tab) ----------

function shapeResponse(r) {
  var data = null;
  try { data = JSON.parse(r.text); } catch (e) { data = null; }
  var loginPage = (r.finalPath === '/login' || r.finalPath === '/setup') || isHtml(r.text);
  return {
    ok: !!(r.status >= 200 && r.status < 300),
    status: r.status || 0,
    redirected: !!r.redirected,
    loginPage: loginPage,
    data: data,
    text: clip(r.text, 300),
    error: null
  };
}

async function apiCall(base, path, opts) {
  opts = opts || {};
  var method = opts.method || 'GET';
  var body = opts.body || null;
  var direct;

  try {
    var init = { method: method, credentials: 'include', redirect: 'follow', headers: {} };
    if (body) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    var res = await fetch(base + path, init);
    direct = shapeResponse({
      status: res.status,
      ok: res.ok,
      redirected: !!res.redirected,
      finalPath: pathOf(res.url),
      text: await res.text()
    });
  } catch (e) {
    direct = { ok: false, status: 0, redirected: false, loginPage: false, data: null, text: '', error: errText(e) };
  }

  if (direct.status > 0 && !direct.loginPage) return direct;

  var via = await bridgeCall(base, path, method, body);
  if (via && !via.error) {
    via.viaTab = true;
    return via;
  }
  if (direct.status > 0) {
    direct.bridgeError = (via && via.error) || 'no tab';
    return direct;
  }
  if (via) return via;
  return { ok: false, status: 0, data: null, text: '', loginPage: false, error: 'server unreachable' };
}

async function bridgeCall(base, path, method, body) {
  var origin = originOf(base);
  if (!origin) return { error: 'bad server url: ' + clip(base, 60) };
  var tabId = await serverTab(origin, base);
  if (tabId === null) return { error: 'no tab available on ' + origin };
  for (var attempt = 0; attempt < 3; attempt++) {
    var res = await injectCall(tabId, path, method, body);
    if (res) return res;
    await sleep(600);
  }
  return { error: 'could not run the request in tab ' + tabId };
}

async function injectCall(tabId, path, method, body) {
  try {
    var out = await chrome.scripting.executeScript({
      target: { tabId: tabId },
      world: 'ISOLATED',
      func: inPageCall,
      args: [path, method || 'GET', body || null]
    });
    for (var i = 0; i < (out || []).length; i++) {
      if (out[i] && out[i].result) return out[i].result;
    }
  } catch (e) {
    // Tab is mid-navigation, or is a page we cannot script. The caller retries.
  }
  return null;
}

/* Runs inside the target page, so it must be self-contained: no reference to
   anything in this file. Same-origin fetch, so the dashboard session cookie is
   attached exactly like any other page request. */
async function inPageCall(path, method, body) {
  var out = { ok: false, status: 0, redirected: false, loginPage: false, data: null, text: '', error: null };
  try {
    var init = { method: method, credentials: 'same-origin', redirect: 'follow', headers: {} };
    if (body) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    var res = await fetch(path, init);
    var text = await res.text();
    var finalPath = '';
    try { finalPath = new URL(res.url).pathname; } catch (e) { finalPath = ''; }
    out.status = res.status;
    out.ok = res.ok;
    out.redirected = !!res.redirected;
    out.loginPage = (finalPath === '/login' || finalPath === '/setup') || /^\s*<(!doctype|html)/i.test(text);
    out.text = text.slice(0, 300);
    try { out.data = JSON.parse(text); } catch (e) { out.data = null; }
  } catch (e) {
    out.error = String((e && e.message) || e);
  }
  return out;
}

async function serverTab(origin, base) {
  var tabs = [];
  try { tabs = await chrome.tabs.query({}); } catch (e) { tabs = []; }
  var mine = tabs.filter(function (t) {
    return t && t.id !== undefined && t.id !== null && originOf(t.url || '') === origin;
  });
  var ready = mine.filter(function (t) {
    return t.status === 'complete' && !/\/(login|setup)(\?|#|$)/i.test(t.url || '');
  });
  if (ready.length) return ready[0].id;
  var complete = mine.filter(function (t) { return t.status === 'complete'; });
  if (complete.length) return complete[0].id;
  var created = null;
  try {
    created = await chrome.tabs.create({ url: base + '/', active: false });
  } catch (e) {
    return null;
  }
  if (!created || created.id === undefined || created.id === null) return null;
  await waitTabComplete(created.id, 20000);
  return created.id;
}

function waitTabComplete(tabId, timeoutMs) {
  return new Promise(function (resolve) {
    var done = false;
    function finish() {
      if (done) return;
      done = true;
      try { chrome.tabs.onUpdated.removeListener(onUpdated); } catch (e) { /* ignore */ }
      resolve();
    }
    function onUpdated(id, info) {
      if (id === tabId && info.status === 'complete') finish();
    }
    try { chrome.tabs.onUpdated.addListener(onUpdated); } catch (e) { /* ignore */ }
    setTimeout(finish, timeoutMs);
    chrome.tabs.get(tabId).then(function (t) {
      if (t && t.status === 'complete') finish();
    }).catch(function () { /* tab gone */ });
  });
}

// ---------- pool reads ----------

function rowView(e) {
  return {
    id: e.id || '',
    hash: String(e.token_hash || '').slice(0, 12),
    node_id: e.node_id || '-',
    added: e.added || '',
    ok: !!e.ok,
    live: !!e.live,
    verdict: e.verdict || 'unverified',
    successes: Number(e.successes) || 0,
    fails: Number(e.fails) || 0
  };
}

async function readPool() {
  var c = await getCfg();
  var r = await apiCall(c.server, '/api/admin/jwt/list', { method: 'GET' });
  if (r.error) return { ok: false, error: 'server unreachable: ' + r.error };
  if (r.loginPage) return { ok: false, auth: true, error: 'not logged in' };
  var d = r.data || {};
  var rows = Array.isArray(d.jwt) ? d.jwt : [];
  var snap = {
    ok: true,
    at: Date.now(),
    count: Number(d.count) || rows.length,
    via: r.viaTab ? 'tab' : 'extension',
    rows: rows.slice(0, 12).map(rowView)
  };
  await chrome.storage.local.set({ [K_POOL]: snap });
  return snap;
}

async function probePool() {
  var c = await getCfg();
  var r = await apiCall(c.server, '/api/admin/jwt/check', { method: 'POST' });
  if (r.error) return { ok: false, error: 'server unreachable: ' + r.error };
  if (r.loginPage) return { ok: false, auth: true, error: 'not logged in' };
  var d = r.data || {};
  return {
    ok: !!d.ok,
    dead: Number(d.dead) || 0,
    unknown: Number(d.unknown) || 0,
    total: Number(d.total) || 0
  };
}

async function uploadToken(jwt, server) {
  var c = await getCfg();
  var base = normalizeServer(server) || c.server;
  var r = await apiCall(base, '/api/admin/jwt/contribute', {
    method: 'POST',
    body: { token: jwt, node_id: SOURCE }
  });
  if (r.error) {
    return {
      ok: false,
      error: 'server unreachable: ' + r.error + (r.bridgeError ? ' (tab: ' + r.bridgeError + ')' : '')
    };
  }
  if (r.loginPage) {
    return {
      ok: false,
      auth: true,
      error: 'not logged in: open ' + base + ' in a tab and log in once, then upload again'
    };
  }
  var d = r.data || {};
  if (d.ok) {
    return { ok: true, id: d.id || '', num_pool: d.num_pool, via: r.viaTab ? 'tab' : 'extension' };
  }
  return { ok: false, error: String(d.error || ('HTTP ' + r.status)) };
}

// ---------- the run ----------

async function busyJob() {
  var j = await getJob();
  if (j && j.busy && Date.now() - (j.at || 0) < FLOW_TIMEOUT_MS + 20000) return j;
  return null;
}

async function startUpload(reason) {
  var running = await busyJob();
  if (running) {
    await pushLog('[WARN] a run is already in progress (phase=' + (running.phase || '?') + ')');
    return { ok: false, error: 'already running' };
  }
  var c = await getCfg();
  var job = {
    busy: true,
    phase: 'challenge',
    reason: reason || 'manual',
    at: Date.now(),
    server: c.server,
    tabId: null,
    created: false
  };
  await setJob(job);
  await setBadge('..', '#2f6f4f');
  await pushLog('[REQ] run=' + job.reason + ' server=' + c.server + ' : opening the Cubey challenge');
  await armFlowTimeout();
  var created = null;
  try {
    created = await chrome.tabs.create({ url: CHALLENGE_URL, active: false });
  } catch (e) {
    await finishJob({ ok: false, error: 'could not open the challenge tab: ' + errText(e) });
    return { ok: false, error: 'could not open the challenge tab' };
  }
  job.tabId = created.id;
  job.created = true;
  await setJob(job);
  return { ok: true, started: true };
}

async function armFlowTimeout() {
  try {
    await chrome.alarms.create(ALARM_FLOW, { when: Date.now() + FLOW_TIMEOUT_MS });
  } catch (e) { /* alarms unavailable */ }
}

async function onFlowTimeout() {
  var j = await getJob();
  if (!j || !j.busy) return;
  var left = (j.at || 0) + FLOW_TIMEOUT_MS - Date.now();
  if (left > 5000) {
    // Chrome may fire an alarm earlier than asked; re-arm for what's left.
    try { await chrome.alarms.create(ALARM_FLOW, { when: Date.now() + left }); } catch (e) { /* ignore */ }
    return;
  }
  await finishJob({
    ok: false,
    keepTab: true,
    error: 'timed out waiting for the Turnstile token (the challenge tab was left open -- solve it there and the token uploads on its own)'
  });
}

async function onTurnstileToken(token, how) {
  if (!token || String(token).length < 20) return;
  var j = await getJob();
  if (!j || !j.busy) {
    // Nothing of ours is pending, so a challenge the user solved by hand gets
    // uploaded too. That is the "anytime" path: no click needed.
    j = {
      busy: true,
      phase: 'challenge',
      reason: 'page',
      at: Date.now(),
      server: (await getCfg()).server,
      tabId: null,
      created: false
    };
    await setJob(j);
    await setBadge('..', '#2f6f4f');
    await armFlowTimeout();
    await pushLog('[REQ] run=page : picked up a token from an open challenge tab');
  }
  if (j.phase === 'verify' || j.phase === 'upload') {
    await pushLog('[WARN] a run is already using a token, this one was dropped');
    return;
  }
  j.phase = 'verify';
  await setJob(j);
  await pushLog('[MUSIC] turnstile token via ' + (how || 'message') + ' len=' + String(token).length);

  var jwt = await verifyTurnstile(token);
  if (!jwt) {
    await finishJob({ ok: false, error: 'verify-turnstile did not return a JWT' });
    return;
  }
  var info = describeToken(jwt);
  j.phase = 'upload';
  j.token = { head: info.head, len: info.len, expNote: info.expNote };
  await setJob(j);
  await pushLog('[MUSIC] jwt ' + info.head + '... len=' + info.len + ' ' + info.expNote);

  var res = await uploadToken(jwt, j.server);
  await finishJob(res);
}

async function verifyTurnstile(token) {
  try {
    var res = await fetch(VERIFY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token }),
      credentials: 'omit'
    });
    var text = await res.text();
    if (!res.ok) {
      await pushLog('[FAIL] verify-turnstile HTTP ' + res.status + ' ' + clip(text, 120));
      return null;
    }
    var data = null;
    try { data = JSON.parse(text); } catch (e) { data = null; }
    var jwt = (data && (data.jwt || data.jwtToken)) || '';
    if (jwt && String(jwt).length > 20) return jwt;
    var bare = clip(text, 400).replace(/\s+/g, '');
    if (!data && bare.length > 20 && !/[{}<>]/.test(bare)) {
      await pushLog('[WARN] verify-turnstile answered with a bare token, not JSON');
      return bare;
    }
    await pushLog('[FAIL] no jwt field in the verify-turnstile answer: ' + clip(text, 120));
    return null;
  } catch (e) {
    await pushLog('[FAIL] verify-turnstile request failed: ' + errText(e));
    return null;
  }
}

async function finishJob(res, quiet) {
  var j = (await getJob()) || {};
  try { await chrome.alarms.clear(ALARM_FLOW); } catch (e) { /* ignore */ }

  if (res.ok) {
    var last = {
      at: Date.now(),
      id: res.id || '',
      num_pool: (res.num_pool === undefined || res.num_pool === null) ? null : res.num_pool,
      via: res.via || '-',
      reason: (quiet ? 'paste' : (j.reason || 'manual'))
    };
    await chrome.storage.local.set({ [K_LAST]: last });
    await setBadge('OK', '#1f7a4d');
    await pushLog('[OK] uploaded' + (last.id ? ' ' + last.id : '') + ' pool=' +
      (last.num_pool === null ? '?' : last.num_pool) + ' via ' + last.via);
    await readPool();
    await notify('uploaded', 'pool=' + (last.num_pool === null ? '?' : last.num_pool) + ' via ' + last.via);
  } else {
    await setBadge('X', '#a12b2b');
    await pushLog('[FAIL] ' + (res.error || 'unknown error'));
    await notify('failed', String(res.error || 'unknown error'));
  }

  if (quiet) return;
  await setJob({
    busy: false,
    phase: res.ok ? 'done' : 'error',
    at: Date.now(),
    reason: j.reason || 'manual',
    error: res.error || null,
    id: res.id || null,
    num_pool: (res.num_pool === undefined || res.num_pool === null) ? null : res.num_pool,
    token: j.token || null
  });
  // Only a tab this extension opened gets closed, and a challenge that may
  // still need a click is left open for the user.
  if (j.created && !res.keepTab && j.tabId !== null && j.tabId !== undefined) {
    try { await chrome.tabs.remove(j.tabId); } catch (e) { /* already gone */ }
  }
}

async function syncAutoAlarm(minutes) {
  try { await chrome.alarms.clear(ALARM_AUTO); } catch (e) { /* ignore */ }
  if (minutes > 0) {
    try {
      await chrome.alarms.create(ALARM_AUTO, { periodInMinutes: minutes, delayInMinutes: minutes });
      await pushLog('[OK] auto upload every ' + minutes + ' min');
    } catch (e) { /* alarms unavailable */ }
  }
}

// ---------- messages ----------

async function handle(msg) {
  switch (msg.type) {
    case 'state': {
      var c = await getCfg();
      var j = await getJob();
      var got = await chrome.storage.local.get([K_POOL, K_LAST, K_LOG]);
      return {
        ok: true,
        cfg: c,
        job: j,
        pool: got[K_POOL] || null,
        last: got[K_LAST] || null,
        log: (got[K_LOG] || []).slice(-LOG_VIEW)
      };
    }
    case 'save':
      return { ok: true, cfg: await setCfg({ server: msg.server, autoMinutes: msg.autoMinutes }) };
    case 'refresh':
      return { ok: true, pool: await readPool() };
    case 'upload':
      return await startUpload('manual');
    case 'paste': {
      var token = String(msg.token || '').trim();
      if (token.length < 20) return { ok: false, error: 'too short to be a JWT' };
      var info = describeToken(token);
      await pushLog('[REQ] pasted token ' + info.head + '... len=' + info.len + ' ' + info.expNote);
      var res = await uploadToken(token, null);
      await finishJob(res, true);
      return res;
    }
    case 'probe': {
      var probe = await probePool();
      if (probe.ok) {
        await pushLog('[OK] probe: ' + probe.dead + ' dead, ' + probe.unknown + ' unknown, ' + probe.total + ' total');
      } else {
        await pushLog('[FAIL] probe: ' + probe.error);
      }
      return probe;
    }
    case 'cancel': {
      var running = await busyJob();
      if (running) await finishJob({ ok: false, error: 'cancelled' });
      return { ok: true };
    }
    case 'turnstile-token':
      await onTurnstileToken(String(msg.token || ''), msg.how);
      return { ok: true, accepted: true };
    case 'turnstile-error': {
      var note = String(msg.kind || 'challenge error');
      var j = await getJob();
      if (j && j.busy && j.phase === 'challenge') {
        await finishJob({ ok: false, keepTab: true, error: note });
      } else {
        await pushLog('[FAIL] ' + note);
      }
      return { ok: true };
    }
    case 'log': {
      var g = await chrome.storage.local.get(K_LOG);
      return { ok: true, log: g[K_LOG] || [] };
    }
    default:
      return { ok: false, error: 'unknown message: ' + clip(msg.type, 40) };
  }
}

chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
  if (!msg || typeof msg.type !== 'string') return false;
  handle(msg).then(
    function (out) { sendResponse(out || {}); },
    function (e) { sendResponse({ ok: false, error: errText(e) }); }
  );
  return true;
});

chrome.commands.onCommand.addListener(function (command) {
  if (command === 'upload-now') startUpload('hotkey');
});

chrome.alarms.onAlarm.addListener(function (alarm) {
  if (alarm.name === ALARM_FLOW) onFlowTimeout();
  else if (alarm.name === ALARM_AUTO) startUpload('auto');
});

chrome.runtime.onInstalled.addListener(function () {
  getCfg().then(function (c) {
    syncAutoAlarm(c.autoMinutes);
    paintTitle();
  });
  setBadge('', null);
  pushLog('[OK] extension ready -- open it, set the server url, hit Get JWT + upload');
});

chrome.runtime.onStartup.addListener(function () {
  getCfg().then(function (c) { syncAutoAlarm(c.autoMinutes); });
  paintTitle();
});

getCfg().then(function (c) { syncAutoAlarm(c.autoMinutes); paintTitle(); });
