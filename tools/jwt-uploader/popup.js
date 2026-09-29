/* Popup view. All real work lives in background.js; this file only asks for
   state, renders it, and reacts to storage changes so a run that finishes
   after the popup was closed still shows up when it is reopened. */
'use strict';

var el = {
  chip: document.getElementById('chip'),
  server: document.getElementById('server'),
  save: document.getElementById('save'),
  auto: document.getElementById('auto'),
  dash: document.getElementById('dash'),
  upload: document.getElementById('upload'),
  probe: document.getElementById('probe'),
  token: document.getElementById('token'),
  send: document.getElementById('send'),
  status: document.getElementById('status'),
  log: document.getElementById('log')
};

var editingServer = false;
var editingAuto = false;
var pollTimer = null;

function send_(msg) {
  return new Promise(function (resolve) {
    try {
      chrome.runtime.sendMessage(msg, function (out) {
        if (chrome.runtime.lastError) {
          resolve({ ok: false, error: chrome.runtime.lastError.message });
          return;
        }
        resolve(out || {});
      });
    } catch (e) {
      resolve({ ok: false, error: String(e) });
    }
  });
}

function hhmm(ts) {
  var d = new Date(ts || Date.now());
  return d.toTimeString().slice(0, 5);
}

function ago(ts) {
  if (!ts) return 'never';
  var s = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (s < 60) return s + 's ago';
  if (s < 3600) return Math.round(s / 60) + ' min ago';
  if (s < 86400) return Math.round(s / 3600) + ' h ago';
  return Math.round(s / 86400) + ' d ago';
}

function esc(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function tagClass(msg) {
  var m = /^\[([A-Z]+)\]/.exec(msg);
  if (!m) return '';
  var tag = m[1].toLowerCase();
  if (tag === 'ok') return 'ok';
  if (tag === 'fail' || tag === 'warn') return 'fail';
  if (tag === 'req') return 'req';
  if (tag === 'music') return 'music';
  return '';
}

function renderLog(lines) {
  if (!lines || !lines.length) {
    el.log.textContent = 'no activity yet';
    return;
  }
  el.log.innerHTML = lines.map(function (line) {
    return '<span class="t">' + esc(hhmm(line.t)) + '</span> ' +
      '<span class="' + tagClass(line.msg) + '">' + esc(line.msg) + '</span>';
  }).join('\n');
  el.log.scrollTop = el.log.scrollHeight;
}

function phaseText(job) {
  if (!job) return { text: 'idle', cls: '' };
  if (job.busy) {
    if (job.phase === 'challenge') return { text: 'waiting for the Turnstile token...', cls: 'busy' };
    if (job.phase === 'verify') return { text: 'exchanging the token for a JWT...', cls: 'busy' };
    if (job.phase === 'upload') return { text: 'uploading to ' + (job.server || 'the server') + '...', cls: 'busy' };
    return { text: 'working...', cls: 'busy' };
  }
  if (job.phase === 'error') return { text: job.error || 'failed', cls: 'fail' };
  if (job.phase === 'done') {
    var extra = (job.num_pool === null || job.num_pool === undefined) ? '' : (' pool=' + job.num_pool);
    return { text: 'uploaded' + (job.id ? ' ' + job.id : '') + extra + ' (' + ago(job.at) + ')', cls: 'ok' };
  }
  return { text: 'idle', cls: '' };
}

function render(state) {
  if (!state || !state.ok) {
    el.status.textContent = (state && state.error) || 'worker asleep, try again';
    el.status.className = 'status fail';
    return;
  }
  var cfg = state.cfg || {};
  if (!editingServer) el.server.value = cfg.server || '';
  if (!editingAuto) el.auto.value = String(cfg.autoMinutes || 0);

  var pool = state.pool;
  if (pool && pool.ok) {
    el.chip.textContent = 'pool ' + pool.count;
    el.chip.className = 'chip ' + (pool.count > 0 ? 'ok' : 'empty');
    el.chip.title = 'read via ' + pool.via + ', ' + ago(pool.at);
  } else if (pool && pool.auth) {
    el.chip.textContent = 'no session';
    el.chip.className = 'chip empty';
    el.chip.title = 'log into the dashboard in a tab once';
  } else if (pool && pool.error) {
    el.chip.textContent = 'offline';
    el.chip.className = 'chip empty';
    el.chip.title = pool.error;
  }

  var ph = phaseText(state.job);
  el.status.textContent = ph.text;
  el.status.className = 'status ' + ph.cls;

  var busy = !!(state.job && state.job.busy);
  el.upload.dataset.busy = busy ? '1' : '0';
  el.upload.disabled = false;
  el.upload.textContent = busy ? 'cancel' : 'Get JWT + upload';
  el.send.disabled = busy;
  el.probe.disabled = busy;

  renderLog(state.log);

  if (busy && !pollTimer) pollTimer = setInterval(refresh, 1500);
  if (!busy && pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function refresh() {
  send_({ type: 'state' }).then(render);
}

function say(text, cls) {
  el.status.textContent = text;
  el.status.className = 'status ' + (cls || '');
}

// ---------- wiring ----------

el.server.addEventListener('focus', function () { editingServer = true; });
el.server.addEventListener('blur', function () { editingServer = false; });
el.auto.addEventListener('change', function () { editingAuto = true; });
el.auto.addEventListener('blur', function () { editingAuto = false; });

el.save.addEventListener('click', function () {
  send_({ type: 'save', server: el.server.value, autoMinutes: Number(el.auto.value) || 0 }).then(function (r) {
    editingServer = false;
    if (r.ok) {
      say('saved: ' + r.cfg.server + (r.cfg.autoMinutes ? ', auto every ' + r.cfg.autoMinutes + ' min' : ''), 'ok');
      send_({ type: 'refresh' });
    } else {
      say(r.error || 'could not save', 'fail');
    }
    refresh();
  });
});

el.dash.addEventListener('click', function () {
  var base = el.server.value.trim();
  send_({ type: 'state' }).then(function (st) {
    var url = (st.cfg && st.cfg.server) || base;
    if (url) chrome.tabs.create({ url: url + '/' });
  });
});

el.upload.addEventListener('click', function () {
  if (el.upload.dataset.busy === '1') {
    say('cancelling...', 'busy');
    send_({ type: 'cancel' }).then(function () { refresh(); });
    return;
  }
  say('opening the Cubey challenge...', 'busy');
  el.upload.disabled = true;
  send_({ type: 'upload' }).then(function (r) {
    if (!r.ok) {
      el.upload.disabled = false;
      say(r.error || 'could not start', 'fail');
    }
    refresh();
  });
});

el.probe.addEventListener('click', function () {
  el.probe.disabled = true;
  say('probing the pool...', 'busy');
  send_({ type: 'probe' }).then(function (r) {
    if (r.ok) say('probe: ' + r.dead + ' dead, ' + r.unknown + ' unknown, ' + r.total + ' total', 'ok');
    else say(r.error || 'probe failed', 'fail');
    send_({ type: 'refresh' });
    refresh();
  });
});

el.send.addEventListener('click', function () {
  var token = el.token.value.trim();
  if (!token) {
    say('nothing to send', 'fail');
    return;
  }
  el.send.disabled = true;
  say('uploading...', 'busy');
  send_({ type: 'paste', token: token }).then(function (r) {
    el.send.disabled = false;
    if (r.ok) {
      el.token.value = '';
      say('uploaded' + (r.num_pool === undefined ? '' : ' pool=' + r.num_pool), 'ok');
    } else {
      say(r.error || 'upload failed', 'fail');
    }
    refresh();
  });
});

el.token.addEventListener('keydown', function (e) {
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    el.send.click();
  }
});

// The worker writes job/log/pool to storage; reflect that live.
chrome.storage.onChanged.addListener(function (changes, area) {
  if (area !== 'local') return;
  if (changes.job || changes.log || changes.pool || changes.lastUpload) refresh();
});

refresh();
send_({ type: 'refresh' });
