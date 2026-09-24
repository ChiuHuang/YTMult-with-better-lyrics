(() => {
  const API = async (path, opts = {}) => {
    const r = await fetch(path, opts);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r;
  };
  const json = async (path, opts) => (await API(path, opts)).json();

  let activePage = 'overview';
  let eventSource = null;
  let logPaused = false;
  const logLines = [];
  const LOG_MAX = 300;
  const POLL = { overview: 8000, logs: null, caches: 10000, library: 6000, nodes: 6000, jwt: 8000, update: 15000, files: 10000, crashes: 10000 };
  const timers = {};

  const $ = s => document.querySelector(s);
  const $$ = s => [...document.querySelectorAll(s)];
  const el = (tag, attrs, ...kids) => {
    const e = document.createElement(tag);
    if (attrs) Object.entries(attrs).forEach(([k, v]) => {
      if (k === 'class') e.className = v;
      else if (k === 'html') e.innerHTML = v;
      else e.setAttribute(k, v);
    });
    kids.forEach(c => { if (c != null) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return e;
  };
  const esc = s => { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; };
  const fmt = n => n == null ? '--' : String(n);
  const shortSha = s => s ? s.slice(0, 8) : '--';
  const ago = iso => {
    if (!iso) return '--';
    let d = Date.now() - new Date(iso).getTime();
    if (!Number.isFinite(d)) return '--';
    if (d < 0) d = 0;
    if (d < 60000) return Math.round(d/1000)+'s';
    if (d < 3600000) return Math.round(d/60000)+'m';
    if (d < 86400000) return Math.round(d/3600000)+'h';
    return Math.round(d/86400000)+'d';
  };

  /* ---- theme ---- */
  const THEMES = ['auto', 'dark', 'light'];
  let themeIdx = parseInt(localStorage.getItem('ymtu-theme-idx'), 10);
  if (!Number.isFinite(themeIdx) || themeIdx < 0) themeIdx = 0;
  const applyTheme = () => {
    const t = THEMES[themeIdx];
    if (mdui.setTheme) mdui.setTheme(t);
    else { document.documentElement.classList.remove('mdui-theme-light','mdui-theme-dark','mdui-theme-auto'); document.documentElement.classList.add('mdui-theme-'+t); }
    const btn = $('#theme-btn');
    if (btn) btn.setAttribute('icon', t === 'light' ? 'light_mode' : t === 'dark' ? 'dark_mode' : 'brightness_auto');
  };

  /* ---- stat helpers ---- */
  let lastStat = {};
  const setVal = (id, v) => {
    const e = $(id);
    if (!e) return;
    if (e.textContent === v) return;
    e.textContent = v;
    e.classList.remove('pulse');
    void e.offsetWidth;
    e.classList.add('pulse');
  };

  /* ---- uptime (per-digit flip clock) ---- */
  let startIso = null;
  let uptimeClockBuilt = false;
  const flipUptimeDigit = (digit, ch) => {
    const old = digit.querySelector('.old');
    const nw = digit.querySelector('.new');
    if (!old || !nw || old.textContent === ch) return;
    nw.textContent = ch;
    digit.classList.add('flip');
    clearTimeout(digit._flipT);
    digit._flipT = setTimeout(() => {
      old.textContent = ch;
      digit.classList.remove('flip');
      nw.textContent = ch;
    }, 300);
  };
  const tickUptime = () => {
    if (!startIso) return;
    const s = Math.max(0, Math.floor((Date.now() - new Date(startIso).getTime()) / 1000));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const str = `${String(h).padStart(2,'0')}h ${String(m).padStart(2,'0')}m ${String(sec).padStart(2,'0')}s`;
    const root = $('#stat-uptime');
    if (!root) return;
    if (!uptimeClockBuilt) {
      root.innerHTML = '';
      [...str].forEach(ch => {
        if (/\d/.test(ch)) {
          const d = el('span', {class:'digit'});
          d.appendChild(el('span', {class:'old'}, ch));
          d.appendChild(el('span', {class:'new'}, ch));
          root.appendChild(d);
        } else {
          root.appendChild(el('span', {class:'up-char'}, ch));
        }
      });
      uptimeClockBuilt = true;
      return;
    }
    const digits = [...root.querySelectorAll('.digit')];
    let di = 0;
    [...str].forEach(ch => {
      if (/\d/.test(ch)) {
        const d = digits[di++];
        if (d) flipUptimeDigit(d, ch);
      }
    });
  };

  /* ---- overview ---- */
  const loadOverview = async () => {
    try {
      const info = await json('/api/admin/server_info');
      startIso = info.start_time;
      tickUptime();
      setVal('#stat-logs', fmt(info.structured_logs));
      setVal('#stat-req', fmt(info.recent_requests?.length));
      setVal('#stat-crash', fmt(info.crash_logs));
      setVal('#stat-lyrics', fmt(info.lyrics_count));
      const kv = $('#server-kv');
      if (kv) {
        kv.innerHTML = '';
        const pairs = [
          ['Instance', `<span class="mono">${esc(info.instance_id)}</span>`],
          ['Start time', esc(info.start_time)],
          ['Uptime', esc(info.uptime_human)],
          ['Recent requests', fmt(info.recent_requests?.length)],
          ['Log files', `${(info.log_files||[]).length} file(s)`],
        ];
        pairs.forEach(([k, v]) => {
          kv.appendChild(el('div', {class:'k'}, k));
          kv.appendChild(el('div', {class:'v mono', html: v}));
        });
      }
      const chip = $('#instance-chip');
      if (chip && info.instance_id) chip.innerHTML = `<mdui-icon name="memory"></mdui-icon> ${esc(info.instance_id.slice(0,8))}`;
      const rr = $('#recent-reqs');
      if (rr) {
        rr.innerHTML = '';
        const reqs = (info.recent_requests||[]).slice().reverse().slice(0,12);
        if (!reqs.length) rr.appendChild(el('div', {class:'list-row'}, 'No recent requests'));
        else {
          reqs.forEach(r => {
            rr.appendChild(el('div', {class:'list-row rq', style:'font-size:12px;'},
              el('span', {class:'truncate'}, r.v || ''),
              el('span', {}, r.mode || ''),
              el('span', {class:'mono'}, r.ip || ''),
              el('span', {class:'truncate mono'}, r.ts ? r.ts.replace('T',' ').slice(0,19) : ''),
              el('span', {class:'mono'}, r.id ? r.id.slice(0,6) : ''),
            ));
          });
        }
      }
    } catch (e) {
      console.warn('overview load failed', e);
    }
  };

  /* ---- logs ---- */
  const renderLogRow = entry => {
    const cls = `log-row lv-${entry.level||'info'}`;
    return el('div', {class: cls},
      el('span', {class:'log-time'}, entry.ts || ''),
      el('span', {class:'log-msg'}, entry.msg || ''),
    );
  };
  const connectSSE = () => {
    if (eventSource) return;
    eventSource = new EventSource('/api/admin/events');
    eventSource.addEventListener('snapshot', e => {
      try {
        const data = JSON.parse(e.data);
        const container = $('#log-list');
        if (!container) return;
        container.innerHTML = '';
        (data.logs||[]).forEach(entry => {
          const row = renderLogRow(entry);
          container.appendChild(row);
          logLines.push(row);
        });
        while (logLines.length > LOG_MAX) {
          const old = logLines.shift();
          if (old.parentNode) old.parentNode.removeChild(old);
        }
      } catch {}
    });
    eventSource.addEventListener('log', e => {
      try {
        const entry = JSON.parse(e.data);
        const container = $('#log-list');
        if (!container || logPaused) return;
        const row = renderLogRow(entry);
        container.appendChild(row);
        logLines.push(row);
        while (logLines.length > LOG_MAX) {
          const old = logLines.shift();
          if (old.parentNode) old.parentNode.removeChild(old);
        }
        if (logLines.length > 10) container.scrollTop = container.scrollHeight;
        throttledRefresh();
      } catch {}
    });
    eventSource.addEventListener('node', () => throttledRefresh());
    eventSource.addEventListener('cache', () => throttledRefresh());
    eventSource.addEventListener('crash', () => throttledRefresh());
    eventSource.addEventListener('rebase_progress', e => {
      try {
        const d = JSON.parse(e.data);
        const results = $('#rebase-results');
        if (!results) return;
        const cls = d.status === 'upgraded' ? 'rb-upgraded'
          : d.status === 'same' ? 'rb-same'
          : (d.status === 'failed' || d.status === 'error') ? 'rb-failed'
          : d.status === 'trying' ? 'rb-already'
          : 'rb-already';
        const text = d.status === 'trying'
          ? `${d.song || '?'} - ${d.artist || '?'} | trying... | ${d.message || ''}`
          : `${d.song || '?'} - ${d.artist || '?'} | tier: ${d.from_tier || '?'} -> ${d.to_tier || '?'} | ${d.source || ''}`;
        results.appendChild(el('div', {class: `rebase-row ${cls}`}, text));
        const summary = $('#rebase-summary');
        if (summary && d.total) summary.textContent = `${d.done}/${d.total} upgraded=${d.upgraded||0} same=${d.same||0} failed=${d.failed||0}`;
        results.scrollTop = results.scrollHeight;
      } catch {}
    });
    eventSource.addEventListener('probe_progress', e => {
      try {
        const d = JSON.parse(e.data);
        // Servers older than the run_id echo send no run_id; accept those
        // rather than dropping every line silently (empty #refetch-live).
        if (d.run_id && d.run_id !== probeRunId) return;
        probeLiveLine(d.provider || '?', d.status || '', d.detail || '');
      } catch {}
    });
    eventSource.addEventListener('retitle_progress', e => {      try {
        const d = JSON.parse(e.data);
        const results = $('#retitle-results');
        if (!results) return;
        const isOk = d.status === 'retitled_and_cached';
        const cls = isOk ? 'rb-upgraded' : d.status === 'retitled_no_lyrics' ? 'rb-failed' : d.status === 'retitling' || d.status === 'fetching' ? 'rb-already' : 'rb-same';
        const oldText = `${d.song || '?'} - ${d.artist || '?'}`;
        const newText = d.new_title ? `${d.new_title} - ${d.new_artist || '?'}` : '';
        let text;
        if (d.status === 'retitling' || d.status === 'fetching') {
          text = `${oldText} | ${d.message || d.status}...`;
        } else {
          text = `old: ${oldText}`;
          if (newText) text += `\nnew: ${newText}`;
          text += `\n${d.status} | ${d.source || ''}`;
        }
        const row = el('div', {class: `rebase-row ${cls}`, style: (d.status !== 'retitling' && d.status !== 'fetching') ? 'display:flex; flex-direction:column; gap:2px;' : ''},
          d.status !== 'retitling' && d.status !== 'fetching'
            ? [el('span', {style:'font-size:11px; opacity:.6;'}, `old: ${oldText}`), el('span', {style:'font-weight:600;'}, newText ? `new: ${newText}` : ''), el('span', {style:'font-size:11px; opacity:.6;'}, `${d.status} | ${d.source || ''}`)]
            : text
        );
        results.appendChild(row);
        const summary = $('#retitle-summary');
        if (summary && d.total) summary.textContent = `${d.done}/${d.total}`;
        results.scrollTop = results.scrollHeight;
      } catch {}
    });
    eventSource.addEventListener('rebase', e => { if (activePage === 'library') loadLibrary(); });
    eventSource.addEventListener('retitle', e => { if (activePage === 'library') loadLibrary(); });
    eventSource.addEventListener('open', () => {
      const dot = $('#log-conn');
      if (dot) { dot.innerHTML = '<span class="live-dot"></span> connected'; dot.className = 'pill pill-ok'; }
    });
    eventSource.addEventListener('error', () => {
      const dot = $('#log-conn');
      if (dot) { dot.innerHTML = 'reconnecting...'; dot.className = 'pill pill-warn'; }
    });
  };
  const throttledRefresh = mdui.throttle(() => {
    if (activePage === 'caches') loadCaches();
    if (activePage === 'library') loadLibrary();
    if (activePage === 'nodes') loadNodes();
    if (activePage === 'crashes') loadCrashes();
  }, 2000);

  const downloadLogs = () => { window.open('/api/admin/logs/download', '_blank'); };
  const clearLogs = async () => {
    await mdui.confirm({ headline: 'Clear logs', description: 'Clear all structured logs from memory?', cancelText: 'Cancel', confirmText: 'Clear', onConfirm: async () => { await API('/api/admin/logs/clear', {method:'POST'}); $('#log-list').innerHTML = ''; logLines.length = 0; } });
  };

  /* ---- caches ---- */
  let cachesData = [];
  const loadCaches = async () => {
    try {
      cachesData = await json('/api/admin/caches');
      renderCaches();
    } catch {}
  };
  const renderCaches = (filter='') => {
    const list = $('#cache-list'); if (!list) return;
    list.innerHTML = '';
    const q = filter.toLowerCase();
    const items = q ? cachesData.filter(c => `${c.song} ${c.artist} ${c.video_id}`.toLowerCase().includes(q)) : cachesData;
    if (!items.length) { list.appendChild(el('div', {class:'list-row'}, 'No cached entries')); return; }
    items.forEach(c => {
      const lang = c.lang || 'zh-TW';
      const pvBtn = el('mdui-button-icon', {icon:'visibility', variant:'tonal', 'data-video-id': c.video_id || '', 'data-lang': lang});
      pvBtn.addEventListener('click', () => openPreview(c.video_id, lang));
      const rnBtn = el('mdui-button-icon', {icon:'edit', variant:'text'});
      rnBtn.title = c.rename ? 'Edit saved rename' : 'Rename to improve fetching';
      rnBtn.addEventListener('click', () => openRenameDialog({video_id: c.video_id, song: c.song, artist: c.artist, rename: c.rename}));
      list.appendChild(el('div', {class:'list-row cache', style:'font-size:13px;'},
        el('span', {class:'truncate'}, `${c.artist} - ${c.song}`,
          c.rename ? el('span', {class:'rename-tag'}, ` renamed: ${c.rename.title || ''} - ${c.rename.artist || ''}`) : null),
        el('span', {}, c.source),
        el('span', {}, c.synced ? 'sync' : ''),
        el('span', {class:'mono'}, fmt(c.lines)),
        el('span', {}, c.time_ago),
        el('span', {class:'truncate mono'}, c.video_id?.slice(0,6) || ''),
        rnBtn,
        pvBtn,
      ));
    });
  };
  const clearEmptyCaches = async () => {
    await mdui.confirm({ headline: 'Clear empty caches', description: 'Remove not-found cache entries?', cancelText: 'Cancel', confirmText: 'Clear', onConfirm: async () => { const r = await API('/api/admin/caches/clear_empty', {method:'POST'}); const d = await r.json(); mdui.snackbar({message:`Cleared ${d.cleared} entry(ies)`}); loadCaches(); } });
  };

  /* ---- nodes ---- */
  const loadNodes = async () => {
    try {
      const data = await json('/api/admin/nodes');
      renderNodes(data.nodes||[]);
    } catch {}
  };
  const renderNodes = nodes => {
    const list = $('#node-list'); if (!list) return;
    list.innerHTML = '';
    if (!nodes.length) { list.appendChild(el('div', {class:'list-row'}, 'No nodes')); return; }
    nodes.forEach(n => {
      const row = el('div', {class:'list-row node', style:'font-size:13.5px;'},
        el('span', {}, n.label || '(unnamed)'),
        el('span', {class:'mono truncate'}, n.node_id || ''),
        el('span', {}, n.last_seen ? ago(n.last_seen)+' ago' : ''),
        el('span', {}, el('span', {class: n.online ? 'pill pill-ok' : 'pill pill-mute'}, el('span', {class:'dot'}), n.online ? 'online' : 'offline')),
        el('mdui-button-icon', {icon: 'delete', variant: 'text', style:'justify-self:end; color:rgb(var(--mdui-color-error));'})
      );
      const revokeBtn = row.lastElementChild;
      revokeBtn.addEventListener('click', async () => {
        await mdui.confirm({headline:'Revoke node', description:`Remove node ${n.node_id||''}? It will be disconnected and its key invalidated.`, cancelText:'Cancel', confirmText:'Revoke', onConfirm: async () => {
          try {
            await API(`/api/admin/nodes/${encodeURIComponent(n.node_id)}/revoke`, {method:'POST'});
            mdui.snackbar({message:'Node revoked'});
            loadNodes();
          } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        }});
      });
      list.appendChild(row);
    });
  };
  const generateNode = async () => {
    await mdui.prompt({
      headline: 'Generate node',
      description: 'Enter a label for the new node.',
      confirmText: 'Generate',
      onConfirm: async (label) => {
        if (!label?.trim()) { mdui.snackbar({message:'Label required'}); return false; }
        const r = await API('/api/admin/nodes/generate', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({label: label.trim()}) });
        const data = await r.json();
        const d = $('#gen-dialog'); if (!d) return;
        $('#gen-node-id').textContent = data.node_id || '';
        $('#gen-node-key').textContent = data.node_key || '';
        const code = $('#gen-code-block'); if (code) code.querySelector('pre').textContent = data.deploy_one_liner || '';
        d.open = true;
      }
    });
  };
  const copyGenCode = () => {
    const pre = $('#gen-code-block pre'); if (!pre) return;
    navigator.clipboard.writeText(pre.textContent).then(()=>mdui.snackbar({message:'Copied to clipboard'}));
  };

  /* ---- jwt ---- */
  const jwtStatus = t => {
    // !live = hash-only record reloaded from disk after a restart: the raw
    // token is gone, so pick_jwt() skips it even when the persisted ok flag
    // is stale-true. Never render those green or the pool looks usable while
    // probes report "no JWT in pool". They revive on device re-contribute.
    if (!t.live) return el('span', {class:'pill pill-mute'}, 'stale');
    if (t.ok) return el('span', {class:'pill pill-ok'}, el('span', {class:'dot'}), 'ok');
    return el('span', {class:'pill pill-warn'}, el('span', {class:'dot'}), 'unverified');
  };
  const renderJwt = tokens => {
    const list = $('#jwt-list'); if (!list) return;
    list.innerHTML = '';
    if (!tokens.length) { list.appendChild(el('div', {class:'list-row'}, 'No pooled tokens')); return; }
    tokens.forEach(t => {
      const row = el('div', {class:'list-row jwt', style:'font-size:13px;'},
        el('span', {class:'mono truncate'}, t.id || '--'),
        el('span', {class:'truncate'}, t.node_id ? `${t.node_id.slice(0,10)}` : '--'),
        el('span', {}, t.added ? ago(t.added)+' ago' : '--'),
        el('span', {}, t.last_checked ? ago(t.last_checked)+' ago' : '--'),
        jwtStatus(t),
        el('mdui-button-icon', {icon: 'close', variant: 'text', style:'justify-self:end; color:rgb(var(--mdui-color-error));'})
      );
      const rmBtn = row.lastElementChild;
      rmBtn.addEventListener('click', async () => {
        rmBtn.loading = true;
        try {
          await API('/api/admin/jwt/remove', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id: t.id})});
          mdui.snackbar({message:'Removed from pool'});
          loadJwt();
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        rmBtn.loading = false;
      });
      list.appendChild(row);
    });
  };
  const loadJwt = async () => {
    try {
      const data = await json('/api/admin/jwt/list');
      setVal('#jwt-count', fmt(data.count));
      renderJwt(data.jwt || []);
    } catch {}
  };
  const checkJwt = async (btn) => {
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/jwt/check', {method:'POST'});
      const d = await r.json();
      mdui.snackbar({message:`Check done: ${d.dead||0} dead, ${d.unknown||0} unknown, ${d.total||0} total`});
      loadJwt();
    } catch (e) { mdui.snackbar({message:'Check failed: '+e.message}); }
    if (btn) btn.loading = false;
  };
  const contributeJwt = async () => {
    await mdui.prompt({
      headline: 'Contribute JWT',
      description: 'Paste a Cubey JWT token.',
      confirmText: 'Submit',
      onConfirm: async (token) => {
        if (!token?.trim()) { mdui.snackbar({message:'Token required'}); return false; }
        const r = await API('/api/admin/jwt/contribute', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({token: token.trim()})});
        const d = await r.json();
        mdui.snackbar({message: d.ok ? 'JWT contributed' : (d.error || 'Failed')});
        loadJwt();
      }
    });
  };

  /* ---- self-update ---- */
  const loadUpdate = async () => {
    try {
      const data = await json('/api/admin/self_update/check');
      const kv = $('#update-kv'); if (!kv) return;
      kv.innerHTML = '';
      const rows = [
        ['Repository', `<span class="mono">${esc(data.repo||'')}</span>`],
        ['Branch', `<span class="mono">${esc(data.branch||'')}</span>`],
        ['Local SHA', `<span class="mono">${esc(shortSha(data.local_sha))}</span>`],
        ['Remote SHA', `<span class="mono">${esc(shortSha(data.remote_sha))}</span>`],
        ['Parent SHA', `<span class="mono">${esc(shortSha(data.parent_sha))}</span>`],
        ['Local file hash', `<span class="mono">${esc(data.local_file_hash||'')}</span>`],
        ['Remote file hash', `<span class="mono">${esc(data.remote_file_hash||'')}</span>`],
      ];
      rows.forEach(([k,v]) => { kv.appendChild(el('div',{class:'k'},k)); kv.appendChild(el('div',{class:'v',html:v})); });
      const chip = $('#update-status'); if (chip) {
        if (data.up_to_date === true) { chip.className='pill pill-ok'; chip.textContent='Up to date'; }
        else if (data.update_available) { chip.className='pill pill-warn'; chip.textContent='Update available'; }
        else { chip.className='pill pill-mute'; chip.textContent='Unknown'; }
      }
    } catch {}
  };
  const performUpdate = async () => {
    const d = $('#updateDialog'); if (!d) return;
    const progress = $('#update-progress');
    const stage = $('#updateStageLine');
    const pingEl = $('#pingStatus');
    const closeBtn = $('#update-close-btn');
    if (progress) { progress.removeAttribute('value'); progress.indeterminate = true; }
    if (stage) stage.textContent = 'Fetching update...';
    if (pingEl) pingEl.innerHTML = '';
    if (closeBtn) closeBtn.disabled = true;
    d.open = true;
    try {
      const r = await fetch('/api/admin/self_update/perform', {method:'POST'});
      const data = await r.json();
      if (!data.ok) { if (stage) stage.textContent = data.error || 'Update failed'; if (progress) { progress.indeterminate=false; progress.value=0; } if (closeBtn) closeBtn.disabled=false; return; }
      if (!data.restarting) { if (stage) stage.textContent = data.message || 'Already up to date'; if (progress) { progress.indeterminate=false; progress.value=1; } if (closeBtn) closeBtn.disabled=false; return; }
      if (stage) stage.textContent = 'Server restarting -- waiting for it to come back...';
      if (pingEl) pingEl.innerHTML = '<span class="live-dot"></span> Pinging...';
      await pingLoop(progress, stage, pingEl, closeBtn);
    } catch (e) {
      if (stage) stage.textContent = 'Update failed: '+e.message;
      if (progress) { progress.indeterminate=false; progress.value=0; }
      if (closeBtn) closeBtn.disabled=false;
    }
  };
  const PING_HISTORY_KEY = 'ymtu-update-ping-history';
  const getPingHistory = () => {
    try { return JSON.parse(localStorage.getItem(PING_HISTORY_KEY)) || []; } catch { return []; }
  };
  const savePingHistory = count => {
    const hist = getPingHistory();
    hist.push(count);
    if (hist.length > 20) hist.shift();
    try { localStorage.setItem(PING_HISTORY_KEY, JSON.stringify(hist)); } catch {}
  };
  const pingLoop = async (progress, stage, pingEl, closeBtn) => {
    let attempt = 0;
    const tick = 1600;
    const hist = getPingHistory();
    const avg = hist.length > 0 ? Math.round(hist.reduce((a, b) => a + b, 0) / hist.length) : 8;
    const maxEst = avg + 1;
    while (true) {
      attempt++;
      if (progress) { progress.indeterminate = false; progress.value = Math.min(0.95, 0.15 + (attempt / maxEst) * 0.8); }
      if (pingEl) pingEl.innerHTML = `<span class="live-dot"></span> Waiting for server (${attempt}/${maxEst} est)`;
      await new Promise(res => setTimeout(res, tick));
      try {
        const r = await fetch('/api/admin/self_update/check');
        if (r.ok) {
          const data = await r.json();
          savePingHistory(attempt);
          if (progress) { progress.indeterminate=false; progress.value=1; }
          if (stage) stage.textContent = `Updated -- now at ${shortSha(data.local_sha)}`;
          if (pingEl) pingEl.innerHTML = 'Server is back -- reloading...';
          if (closeBtn) closeBtn.disabled = false;
          setTimeout(()=>{ window.location.reload(); }, 1600);
          return;
        }
      } catch {}
    }
  };

  /* ---- files ---- */
  const loadFiles = async () => {
    try {
      const data = await json('/api/admin/files');
      const list = $('#file-list'); if (!list) return;
      list.innerHTML = '';
      const files = (data.files||[]).slice(0,80);
      if (!files.length) { list.appendChild(el('div', {class:'list-row'}, 'No log files')); return; }
      files.forEach(f => {
        const row = el('div', {class:'list-row file', style:'font-size:13px;'},
          el('span', {class:'truncate'}, f.name),
          el('span', {class:'mono'}, f.size_human),
          el('span', {}, f.modified ? new Date(f.modified).toLocaleString() : ''),
        );
        const dl = el('mdui-button-icon', {icon:'download', variant:'tonal', style:'justify-self:end;'});
        dl.addEventListener('click', ()=> window.open(`/api/admin/files/download?file=${encodeURIComponent(f.name)}`, '_blank'));
        row.appendChild(dl);
        list.appendChild(row);
      });
      const cc = $('#cache-counts'); if (cc && data.cache) cc.textContent = `Lyrics: ${data.cache.lyrics_count||0} | Translate: ${data.cache.translate_count||0}`;
    } catch {}
  };

  /* ---- crashes ---- */
  const loadCrashes = async () => {
    try {
      const data = await json('/api/admin/crash_logs');
      const list = $('#crash-list'); if (!list) return;
      list.innerHTML = '';
      const logs = (data.logs||[]).slice().reverse();
      if (!logs.length) { list.appendChild(el('div', {class:'list-row'}, 'No crash logs')); return; }
      logs.forEach(c => {
        const details = el('details', {style:'font-size:12px;'},
          el('summary', {style:'cursor:pointer; padding:4px 0;'}, `${c.ts||''} ${c.type||''}: ${(c.msg||'').slice(0,120)}`),
          el('pre', {style:'white-space:pre-wrap; word-break:break-word; font-size:11.5px; margin:4px 0 0 0; max-height:250px; overflow:auto; background:rgba(var(--mdui-color-surface-variant),.25); padding:8px; border-radius:6px;'}, c.trace||'')
        );
        const row = el('div', {class:'list-row', style:'display:block;'}, details);
        list.appendChild(row);
      });
    } catch {}
  };
  const clearCrashes = async () => {
    await mdui.confirm({headline:'Clear crashes', description:'Remove all crash logs from memory?', cancelText:'Cancel', confirmText:'Clear', onConfirm: async ()=>{ await API('/api/admin/crash_logs/clear',{method:'POST'}); loadCrashes(); mdui.snackbar({message:'Crashes cleared'}); }});
  };
  const downloadLogsBundle = () => { window.open('/api/admin/logs/download', '_blank'); };

  /* ---- update config (set main_file) ---- */
  const setMainFile = async () => {
    await mdui.prompt({
      headline: 'Set main file',
      description: 'Enter the main server filename (e.g. proxy_server.py). Leave blank to reset.',
      confirmText: 'Save',
      onConfirm: async (val) => {
        const r = await API('/api/admin/self_update/config', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({main_file: (val||'').trim()})});
        const d = await r.json();
        mdui.snackbar({message: d.ok ? 'Saved' : (d.error||'Failed')});
        loadUpdate();
      }
    });
  };

  /* ---- library ---- */
  let rebaseFastTimer = null;
  let rebaseMode = 'cached';
  let retitleFastTimer = null;
  const loadLibrary = async () => {
    try {
      const [scan, status, retitleStatus] = await Promise.all([
        json('/api/admin/library/scan'),
        json('/api/admin/library/rebase/status'),
        json('/api/admin/library/retitle/status').catch(() => ({state:'idle'})),
      ]);
      setVal('#stat-wbw', fmt(scan.buckets?.wbw));
      setVal('#stat-line', fmt(scan.buckets?.line));
      setVal('#stat-plain', fmt(scan.buckets?.plain));
      setVal('#stat-none', fmt(scan.buckets?.none));
      renderRebaseStatus(status);
      renderRetitleStatus(retitleStatus);
      try {
        const unlyriced = await json('/api/admin/library/unlyriced');
        renderUnlyriced(unlyriced.items || []);
      } catch (e) { renderUnlyriced([]); }
      if (status.state === 'running') startRebaseFastPoll(); else stopRebaseFastPoll();
      if (retitleStatus.state === 'running') startRetitleFastPoll(); else stopRetitleFastPoll();
    } catch (e) {
      console.error('[library] load failed:', e);
      const results = $('#rebase-results');
      if (results && !results.children.length) results.innerHTML = '<div style="font-size:12.5px;color:rgb(var(--mdui-color-error));padding:8px 0;">Failed to load library data</div>';
    }
  };
  const renderRebaseStatus = status => {
    const startBtn = $('#rebase-start');
    const stopBtn = $('#rebase-stop');
    const progress = $('#rebase-progress');
    const summary = $('#rebase-summary');
    const results = $('#rebase-results');
    const running = status.state === 'running';
    if (startBtn) startBtn.disabled = running;
    if (stopBtn) stopBtn.style.display = running ? '' : 'none';
    if (progress) {
      if (running && status.total > 0) progress.value = Math.min(1, status.done / status.total);
      else if (status.state === 'done') progress.value = 1;
      else progress.value = 0;
    }
    if (summary) {
      summary.textContent = (status.total > 0 || status.state === 'done')
        ? `${fmt(status.done)}/${fmt(status.total)} upgraded=${fmt(status.upgraded)} same=${fmt(status.same)} failed=${fmt(status.failed)}`
        : '';
    }
    if (results) {
      results.innerHTML = '';
      const items = status.results || [];
      if (!items.length) {
        const empty = el('div', {style:'font-size:12.5px; color:rgb(var(--mdui-color-outline)); padding:8px 0;'},
          status.state === 'running' ? 'Processing...' : 'No rebase results yet. Click "Rebase" to start.');
        results.appendChild(empty);
        return;
      }
      items.forEach(r => {
        const cls = r.status === 'upgraded' ? 'rb-upgraded'
          : r.status === 'same' ? 'rb-same'
          : (r.status === 'failed' || r.status === 'error') ? 'rb-failed'
          : 'rb-already';
        results.appendChild(el('div', {class: `rebase-row ${cls}`},
          `${r.song || '?'} - ${r.artist || '?'} | tier: ${r.from || '?'} -> ${r.to || '?'} | ${r.source || ''}`
        ));
      });
    }
  };
  const renderUnlyriced = items => {
    const list = $('#unlyricedList');
    if (!list) return;
    list.innerHTML = '';
    if (!items.length) { list.appendChild(el('div', {class:'list-row'}, 'No unlyriced songs')); return; }
    items.forEach(item => {
      const row = el('div', {class:'list-row', style:'grid-template-columns: 1fr auto auto auto;'},
        el('span', {class:'truncate'}, `${item.song || ''} - ${item.artist || ''} (${item.video_id || ''})`,
          item.rename ? el('span', {class:'rename-tag'}, ` renamed: ${item.rename.title || ''} - ${item.rename.artist || ''}`) : null)
      );
      const rebaseBtn = el('mdui-button', {variant:'tonal', icon:'cached'});
      rebaseBtn.textContent = 'Rebase';
      rebaseBtn.addEventListener('click', async () => {
        rebaseBtn.loading = true;
        try {
          await API('/api/admin/library/rebase/start', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'unlyriced', video_id: item.video_id})});
          mdui.snackbar({message:`Rebase started for ${item.song || item.video_id}`});
          loadLibrary();
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        rebaseBtn.loading = false;
      });
      row.appendChild(rebaseBtn);
      const renameBtn = el('mdui-button', {variant:'tonal', icon:'edit'});
      renameBtn.textContent = 'Rename';
      renameBtn.addEventListener('click', () => openRenameDialog(item));
      row.appendChild(renameBtn);
      const retitleBtn = el('mdui-button', {variant:'text', icon:'edit'});
      retitleBtn.textContent = 'Retitle (LLM)';
      retitleBtn.addEventListener('click', async () => {
        retitleBtn.loading = true;
        try {
          const r = await API('/api/admin/library/retitle', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({video_id: item.video_id})});
          const d = await r.json();
          if (d.ok) { mdui.snackbar({message:'Retitle started'}); openRetitleDialog(); }
          else mdui.snackbar({message: d.error || 'Failed'});
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        retitleBtn.loading = false;
      });
      row.appendChild(retitleBtn);
      list.appendChild(row);
    });
  };
  const startRebase = async () => {
    const startBtn = $('#rebase-start');
    if (startBtn) startBtn.loading = true;
    try {
      await API('/api/admin/library/rebase/start', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode: rebaseMode})});
      mdui.snackbar({message:'Rebase started'});
      loadLibrary();
    } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
    if (startBtn) startBtn.loading = false;
  };
  const stopRebase = async () => {
    try {
      await API('/api/admin/library/rebase/stop', {method:'POST'});
      mdui.snackbar({message:'Rebase stopped'});
      loadLibrary();
    } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
  };

  /* ---- retitle (background job + dialog) ---- */
  const openRetitleDialog = () => {
    const d = $('#retitle-dialog');
    if (d) d.open = true;
  };
  const renderRetitleStatus = status => {
    const progress = $('#retitle-progress');
    const summary = $('#retitle-summary');
    const results = $('#retitle-results');
    const running = status.state === 'running';
    if (progress) {
      if (running && status.total > 0) progress.value = Math.min(1, status.done / status.total);
      else if (status.state === 'done') progress.value = 1;
      else progress.value = 0;
    }
    if (summary) {
      summary.textContent = (status.total > 0 || status.state === 'done')
        ? `${fmt(status.done)}/${fmt(status.total)}`
        : '';
    }
    if (results) {
      results.innerHTML = '';
      const items = status.results || [];
      if (!items.length && status.state === 'idle') return;
      if (!items.length) { results.appendChild(el('div', {style:'font-size:13px; color:rgb(var(--mdui-color-on-surface-variant)); padding:8px 0;'}, 'No results yet...')); return; }
      items.forEach(r => {
        const isOk = r.status === 'retitled_and_cached';
        const cls = isOk ? 'rb-upgraded' : r.status === 'retitled_no_lyrics' ? 'rb-failed' : 'rb-same';
        const oldText = `${r.old?.title || '?'} - ${r.old?.artist || '?'}`;
        const newText = `${r.new?.title || '?'} - ${r.new?.artist || '?'}`;
        const row = el('div', {class: `rebase-row ${cls}`, style:'display:flex; flex-direction:column; gap:2px;'},
          el('span', {style:'font-size:11px; opacity:.6;'}, `old: ${oldText}`),
          el('span', {style:'font-weight:600;'}, `new: ${newText}`),
          el('span', {style:'font-size:11px; opacity:.6;'}, `${r.status} | ${r.source || ''}`),
        );
        results.appendChild(row);
      });
    }
  };
  const retitleAll = async () => {
    await mdui.confirm({
      headline: 'Retitle all unlyriced',
      description: 'Send all unlyriced songs through LLM retitle?',
      cancelText: 'Cancel',
      confirmText: 'Retitle all',
      onConfirm: async () => {
        try {
          const r = await API('/api/admin/library/retitle', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({})});
          const d = await r.json();
          if (d.ok) { mdui.snackbar({message:'Retitle started'}); openRetitleDialog(); }
          else mdui.snackbar({message: d.error || 'Failed'});
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
      }
    });
  };
  const startRebaseFastPoll = () => {
    if (rebaseFastTimer) return;
    rebaseFastTimer = setInterval(() => { if (activePage === 'library') loadLibrary(); }, 2000);
  };
  const stopRebaseFastPoll = () => {
    if (rebaseFastTimer) { clearInterval(rebaseFastTimer); rebaseFastTimer = null; }
  };
  const startRetitleFastPoll = () => {
    if (retitleFastTimer) return;
    retitleFastTimer = setInterval(() => { if (activePage === 'library') loadLibrary(); }, 2000);
  };
  const stopRetitleFastPoll = () => {
    if (retitleFastTimer) { clearInterval(retitleFastTimer); retitleFastTimer = null; }
  };

  /* ---- lyrics preview (braccato renderer + hidden YT clock) ---- */
  let prevData = null;
  let prevPlayhead = 0;
  let prevScrubbing = false;
  let prevMaxTime = 100;
  let ytPlayer = null;
  let prevRafId = null;
  let ytPendingVideoId = null;
  let ytPendingAutoplay = false;
  let prevLastShownSecond = -1;
  let prevYtPlaying = false;

  const braccatoView = () => document.getElementById('braccato-view');

  const toBraccatoLyrics = (lines, lang) => {
    const starts = lines.map(l => (l.time != null ? l.time : (l.startTimeMs != null ? l.startTimeMs / 1000 : 0)));
    return lines.map((l, i) => {
      const startMs = Math.round(starts[i] * 1000);
      let durMs = l.durationMs != null ? l.durationMs : (l.duration != null ? Math.round(l.duration * 1000) : 0);
      if (!durMs || durMs <= 0) {
        let next = Infinity;
        starts.forEach((s, j) => { if (j !== i && s * 1000 > startMs && s * 1000 < next) next = s * 1000; });
        durMs = next === Infinity ? 3000 : Math.max(Math.round(next - startMs), 500);
      }
      const parts = (l.parts || []).map(p => ({
        startTimeMs: p.startTimeMs || 0,
        durationMs: p.durationMs || 0,
        words: (p.words != null ? p.words : p.text) || '',
      }));
      const out = {
        startTimeMs: startMs,
        durationMs: durMs,
        words: l.text || parts.map(p => p.words).join(''),
      };
      if (parts.length > 1 && new Set(parts.map(p => p.startTimeMs)).size > 1) out.parts = parts;
      if (l.translated) out.translation = { text: l.translated, lang: lang || 'zh-TW' };
      if (l.isInstrumental) out.isInstrumental = true;
      return out;
    });
  };

  window.onYouTubeIframeAPIReady = () => {
    if (ytPendingVideoId) {
      const vid = ytPendingVideoId;
      const auto = ytPendingAutoplay;
      ytPendingVideoId = null;
      createYtPlayer(vid, auto);
    }
  };

  const stopPrevLoop = () => {
    if (prevRafId) { cancelAnimationFrame(prevRafId); prevRafId = null; }
  };

  const destroyYtPlayer = () => {
    stopPrevLoop();
    ytPendingVideoId = null;
    if (ytPlayer && typeof ytPlayer.destroy === 'function') {
      try { ytPlayer.destroy(); } catch {}
    } else if (ytPlayer && typeof ytPlayer.stopVideo === 'function') {
      try { ytPlayer.stopVideo(); } catch {}
    }
    ytPlayer = null;
    const holder = document.getElementById('yt-player-hidden');
    if (holder) holder.innerHTML = '';
  };

  const createYtPlayer = (videoId, autoplay) => {
    destroyYtPlayer();
    const thumb = document.getElementById('prev-thumb');
    if (thumb) { thumb.src = `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`; thumb.alt = videoId; }
    if (!window.YT || !YT.Player) { ytPendingVideoId = videoId; ytPendingAutoplay = autoplay; return; }
    const holder = document.getElementById('yt-player-hidden');
    if (!holder) return;
    holder.innerHTML = '<div id="yt-player"></div>';
    try {
      ytPlayer = new YT.Player('yt-player', {
        height: '2', width: '2', videoId,
        playerVars: { autoplay: autoplay ? 1 : 0, controls: 0, modestbranding: 1, showinfo: 0, rel: 0, fs: 0, iv_load_policy: 3, playsinline: 1 },
        events: {
          onReady: () => { if (autoplay && ytPlayer) { try { ytPlayer.playVideo(); } catch {} } startPrevLoop(); },
          onStateChange: (e) => {
            const btn = $('#prev-play');
            if (!window.YT) return;
            if (e.data === YT.PlayerState.PLAYING) { prevYtPlaying = true; if (btn) btn.setAttribute('icon', 'pause'); startPrevLoop(); }
            else if (e.data === YT.PlayerState.PAUSED || e.data === YT.PlayerState.ENDED) { prevYtPlaying = false; if (btn) btn.setAttribute('icon', 'play_arrow'); }
          }
        }
      });
      startPrevLoop();
    } catch { ytPlayer = null; }
  };

  const startPrevLoop = () => {
    stopPrevLoop();
    prevRafId = requestAnimationFrame(prevLoop);
  };

  const prevLoop = () => {
    if (ytPlayer && typeof ytPlayer.getCurrentTime === 'function') {
      try { prevPlayhead = ytPlayer.getCurrentTime() || 0; } catch {}
    }
    const view = braccatoView();
    if (view) {
      try { view.currentTime = prevPlayhead; view.playing = prevYtPlaying; } catch {}
    }
    const seek = $('#prev-seek');
    if (seek && !prevScrubbing) seek.value = Math.min(prevPlayhead, prevMaxTime);
    const wholeSec = Math.floor(prevPlayhead);
    if (wholeSec !== prevLastShownSecond) { prevLastShownSecond = wholeSec; updatePrevTime(); }
    prevRafId = requestAnimationFrame(prevLoop);
  };

  const stopPreviewPlayback = () => {
    if (ytPlayer && typeof ytPlayer.pauseVideo === 'function') {
      try { ytPlayer.pauseVideo(); } catch {}
    }
    stopPrevLoop();
    const btn = $('#prev-play');
    if (btn) btn.setAttribute('icon', 'play_arrow');
  };
  const openPreview = async (videoId, lang, inlineData) => {
    destroyYtPlayer();
    const dlg = $('#preview-dialog');
    if (!dlg) return;
    try {
      const data = inlineData || await json(`/api/admin/cache/preview?v=${encodeURIComponent(videoId)}&lang=${encodeURIComponent(lang)}`);
      prevData = data;
      prevPlayhead = 0;
      prevYtPlaying = false;
      prevLastShownSecond = -1;
      const lines = data.lyrics || [];
      const lineStart = l => (l.time != null ? l.time : (l.startTimeMs != null ? l.startTimeMs / 1000 : 0));
      const lineDur = l => (l.durationMs != null ? l.durationMs / 1000 : (l.duration != null ? l.duration : 0)) || 0;
      let wbwLines = 0;
      let interpLines = 0;
      lines.forEach(l => {
        const parts = l.parts || [];
        if (parts.length > 1 && new Set(parts.map(p => p.startTimeMs)).size > 1) {
          if (l.wordSynced) wbwLines++;
          else interpLines++;
        }
      });
      const tier = wbwLines > 0 ? 'wbw' : (data.synced ? 'line' : 'plain');
      const syncBits = [`synced:${data.synced ? 1 : 0}`, `wordSynced:${(data.wordSynced || wbwLines > 0) ? 1 : 0}`, `tier:${tier}`];
      if (interpLines > 0 && wbwLines === 0) syncBits.push(`interp:${interpLines}`);
      const meta = $('#prev-meta');
      if (meta) meta.textContent = `${data.song || '?'} - ${data.artist || '?'} | ${data.source || ''} | ${syncBits.join(' ')}`;
      const seek = $('#prev-seek');
      let maxTime = 100;
      if (lines.length) {
        let lastEnd = 0;
        lines.forEach(l => {
          const t = lineStart(l);
          lastEnd = Math.max(lastEnd, t + lineDur(l));
          (l.parts || []).forEach(p => {
            lastEnd = Math.max(lastEnd, (p.startTimeMs || 0) / 1000 + (p.durationMs || 0) / 1000);
          });
        });
        maxTime = lastEnd + 5;
      }
      prevMaxTime = maxTime;
      if (seek) {
        seek.max = maxTime; seek.value = 0;
        if (!seek.dataset.prevWired) {
          seek.dataset.prevWired = '1';
          seek.addEventListener('pointerdown', () => { prevScrubbing = true; });
          seek.addEventListener('pointerup', () => { prevScrubbing = false; });
          seek.addEventListener('change', () => {
            prevScrubbing = false;
            const t = parseFloat(seek.value) || 0;
            if (ytPlayer && typeof ytPlayer.seekTo === 'function') ytPlayer.seekTo(t, true);
            prevPlayhead = t;
            const view = braccatoView();
            if (view) { try { view.currentTime = t; } catch {} }
            prevLastShownSecond = -1;
            updatePrevTime();
          });
        }
      }
      const view = braccatoView();
      if (view) {
        if (!view.dataset.seekWired) {
          view.dataset.seekWired = '1';
          view.addEventListener('braccato:line-click', e => {
            const t = (e.detail && e.detail.timeS) || 0;
            if (ytPlayer && typeof ytPlayer.seekTo === 'function') { ytPlayer.seekTo(t, true); ytPlayer.playVideo(); }
            prevPlayhead = t;
          });
        }
        try {
          view.currentTime = 0; view.playing = false;
          const mapped = toBraccatoLyrics(lines, lang);
          if (window.customElements && !customElements.get('braccato-lyrics')) {
            customElements.whenDefined('braccato-lyrics').then(() => { try { view.lyrics = mapped; } catch {} });
          } else {
            view.lyrics = mapped;
          }
        } catch {}
      }
      updatePrevTime();
      dlg.open = true;
      if (videoId) createYtPlayer(videoId, false);
    } catch (e) { mdui.snackbar({message:'Preview failed: '+e.message}); }
  };
  const updatePrevTime = () => {
    const t = Math.max(0, Math.floor(prevPlayhead));
    const m = Math.floor(t / 60);
    const s = t % 60;
    const label = $('#prev-time');
    if (label) label.textContent = `${m}:${s.toString().padStart(2,'0')}`;
  };
  const togglePreviewPlay = () => {
    if (!ytPlayer) return;
    try {
      const state = ytPlayer.getPlayerState();
      if (state === YT.PlayerState.PLAYING) ytPlayer.pauseVideo();
      else ytPlayer.playVideo();
    } catch {}
  };

  /* ---- refetch from URL / per-provider pick + custom rename ---- */
  let probeRunId = null;
  const probeLiveLine = (provider, status, detail) => {
    const live = $('#refetch-live');
    if (!live) return;
    const tag = status === 'found' ? 'OK' : status === 'missed' ? '--'
      : status === 'error' ? 'FAIL' : status === 'skipped' ? 'SKIP' : '...';
    const cls = status === 'found' ? 'pl-ok' : status === 'missed' ? 'pl-miss'
      : status === 'error' ? 'pl-fail' : status === 'skipped' ? 'pl-miss' : 'pl-run';
    live.appendChild(el('div', {},
      el('span', {class: cls}, `[${tag}] `),
      document.createTextNode(`${provider}${detail ? ' ' + detail : ''}`)));
    live.classList.add('has-lines');
    while (live.children.length > 200) live.removeChild(live.firstChild);
    live.scrollTop = live.scrollHeight;
  };
  const tierPill = t => {
    const cls = t === 'wbw' ? 'pill-ok' : t === 'line' ? 'pill-warn' : 'pill-mute';
    return el('span', {class:`pill ${cls}`}, t);
  };
  const renderProbeCandidates = (d) => {
    const meta = $('#refetch-meta');
    const list = $('#refetch-candidates');
    if (!list) return;
    list.innerHTML = '';
    if (!d || !d.candidates || !d.candidates.length) {
      meta.textContent = (d && d.error) ? `Probe error: ${d.error}` : 'No lyrics found from any provider for this video.';
      return;
    }
    const renamed = d.renamed ? ' (saved rename applied)' : '';
    const notes = (d.notes && d.notes.length) ? ' | ' + d.notes.join('; ') : '';
    meta.textContent = `${d.song || '?'} - ${d.artist || '?'} | ${d.duration || 0}s | ${d.candidates.length} candidate(s)${renamed}${notes}`;
    d.candidates.forEach((c, i) => {
      const rowCls = i === 0 ? 'rb-upgraded' : 'rb-same';
      const previewBtn = el('mdui-button', {variant:'tonal', icon:'visibility'}, 'Preview');
      previewBtn.addEventListener('click', () => openPreview(d.video_id, d.lang, c.data));
      const saveBtn = el('mdui-button', {variant:'filled', icon:'save'}, 'Save');
      saveBtn.addEventListener('click', async () => {
        saveBtn.loading = true;
        try {
          const r = await API('/api/admin/library/probe/apply', {method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
              video_id: d.video_id, lang: d.lang, source: c.source,
              data: c.data,
            })});
          const applied = await r.json();
          if (!applied.ok) throw new Error(applied.error || 'apply failed');
          mdui.snackbar({message:`Saved ${applied.song} (${applied.source}, ${applied.tier})`});
          loadCaches();
          loadLibrary();
          openPreview(applied.video_id, applied.lang, applied.data);
        } catch (e) { mdui.snackbar({message:'Apply failed: '+e.message}); }
        saveBtn.loading = false;
      });
      const row = el('div', {class:`rebase-row ${rowCls} probe-row`},
        el('span', {class:'probe-name'}, `${i === 0 ? 'best: ' : ''}${c.provider || '?'}`),
        el('span', {class:'probe-source'}, `${c.source || ''} | ${c.lines} lines | score ${c.score}`),
        tierPill(c.tier),
        el('span', {class:'probe-actions'}, previewBtn, saveBtn)
      );
      list.appendChild(row);
    });
  };
  const probeRefetch = async (opts={}) => {    const probeBtn = $('#refetch-probe');
    const status = $('#refetch-status');
    const url = (opts.url || ($('#refetch-url') && $('#refetch-url').value) || '').trim();
    if (!url) { mdui.snackbar({message:'Enter a YouTube URL or video ID'}); return; }
    probeRunId = 'p' + Date.now().toString(36);
    const live = $('#refetch-live');
    if (live) { live.innerHTML = ''; live.classList.remove('has-lines'); }
    if (probeBtn) probeBtn.loading = true;
    if (status) status.textContent = 'probing...';
    try {
      const r = await API('/api/admin/library/probe', {method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          url,
          lang: ($('#refetch-lang') && $('#refetch-lang').value || 'zh-TW').trim(),
          title: opts.title || undefined,
          artist: opts.artist || undefined,
          run_id: probeRunId,
        })});
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || 'probe failed');
      renderProbeCandidates(d);
      if (status) status.textContent = 'done';
    } catch (e) {
      if (status) status.textContent = 'error';
      mdui.snackbar({message:'Probe failed: '+e.message});
      const list = $('#refetch-candidates');
      if (list) list.innerHTML = '';
    }
    if (probeBtn) probeBtn.loading = false;
  };

  /* ---- manual rename (unlyriced / caches rows) ---- */
  let renameCtx = null;
  const openRenameDialog = (item) => {
    const dlg = $('#rename-dialog');
    if (!dlg) return;
    renameCtx = {video_id: item.video_id, song: item.song, artist: item.artist};
    try { dlg.setAttribute('headline', `Rename ${item.song || item.video_id || ''}`); } catch {}
    const sub = $('#rename-sub');
    if (sub) sub.textContent = `Fix the title/artist used when fetching lyrics for ${item.video_id || ''}. The saved rename applies to rebase, playlist sync and future checks. Clear both fields to remove it.`;
    const cur = item.rename || {};
    const t = $('#rename-title'); if (t) t.value = cur.title || item.song || '';
    const a = $('#rename-artist'); if (a) a.value = cur.artist || item.artist || '';
    dlg.open = true;
  };
  const saveRename = async (andCheck) => {
    if (!renameCtx) return;
    const btn = andCheck ? $('#rename-save-check') : $('#rename-save');
    const title = ($('#rename-title') && $('#rename-title').value || '').trim();
    const artist = ($('#rename-artist') && $('#rename-artist').value || '').trim();
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/library/rename', {method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({video_id: renameCtx.video_id, title, artist})});
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || 'rename failed');
      mdui.snackbar({message: d.renamed ? 'Rename saved' : 'Rename cleared'});
      try { $('#rename-dialog').open = false; } catch {}
      loadCaches();
      loadLibrary();
      if (andCheck) {
        const urlField = $('#refetch-url');
        if (urlField) urlField.value = renameCtx.video_id;
        await probeRefetch({url: renameCtx.video_id,
          title: title || undefined, artist: artist || undefined});
        const panel = $('#refetch-probe');
        if (panel) panel.scrollIntoView({behavior:'smooth', block:'center'});
      }
    } catch (e) { mdui.snackbar({message:'Rename failed: '+e.message}); }
    if (btn) btn.loading = false;
  };

  /* ---- playlist refetch (web) ---- */
  let plPollTimer = null;
  let plJobId = null;
  const renderPlSync = st => {
    const progress = $('#plsync-progress');
    const summary = $('#plsync-summary');
    const status = $('#plsync-status');
    const list = $('#plsync-results');
    const running = st && (st.state === 'running' || st.state === 'queued');
    if (status) status.textContent = (st && st.state) || 'idle';
    const stopBtn = $('#plsync-stop');
    if (stopBtn) stopBtn.style.display = running ? '' : 'none';
    if (progress) progress.value = (st && st.total > 0) ? Math.min(1, st.done / st.total) : 0;
    if (summary) summary.textContent = st && st.total > 0
      ? `${st.done}/${st.total} found=${st.found} unlyriced=${st.unlyriced || 0} errors=${st.error_count || 0}${st.current ? '  ' + st.current : ''}`
      : '';
    if (list) {
      list.innerHTML = '';
      const tracks = (st && st.tracks) || [];
      if (!tracks.length) {
        if (running) list.appendChild(el('div', {style:'font-size:12.5px; color:rgb(var(--mdui-color-outline)); padding:8px 0;'}, 'Fetching playlist...'));
        else list.appendChild(el('div', {style:'font-size:12.5px; color:rgb(var(--mdui-color-outline)); padding:8px 0;'}, 'No playlist sync yet.'));
        return;
      }
      tracks.forEach(t => {
        const tag = t.tag || t.status || '';
        const cls = tag === 'found' ? 'rb-upgraded' : tag === 'unlyriced' ? 'rb-failed' : tag === 'error' ? 'rb-error' : 'rb-already';
        const pv = tag === 'found'
          ? el('button', {class:'pl-sync-preview', style:'background:none;border:none;color:rgb(var(--mdui-color-primary));cursor:pointer;padding:0;font-size:12px;'}, 'preview')
          : null;
        if (pv) pv.addEventListener('click', () => openPreview(t.video_id, ($('#plsync-lang') && $('#plsync-lang').value) || 'zh-TW'));
        const row = el('div', {class:`rebase-row ${cls}`});
        row.appendChild(document.createTextNode(`${t.title || t.song || t.video_id || '?'}${t.artist ? ' - ' + t.artist : ''} | ${tag}${t.source ? ' | ' + t.source : ''}`));
        if (pv) row.appendChild(document.createTextNode('  '));
        if (pv) row.appendChild(pv);
        list.appendChild(row);
      });
    }
  };
  const stopPlaylistSyncWeb = async () => {
    if (!plJobId) return;
    try { await API(`/api/playlist/sync/stop/${encodeURIComponent(plJobId)}`, {method:'POST'}); } catch {}
    if (plPollTimer) { clearInterval(plPollTimer); plPollTimer = null; }
    renderPlSync({state:'stopped'});
  };
  const startPlaylistSyncWeb = async () => {
    const url = ($('#plsync-url') && $('#plsync-url').value || '').trim();
    if (!url) { mdui.snackbar({message:'Enter a playlist URL or ID'}); return; }
    const startBtn = $('#plsync-start');
    if (startBtn) startBtn.loading = true;
    if (plPollTimer) { clearInterval(plPollTimer); plPollTimer = null; }
    try {
      const r = await API('/api/playlist/sync', {method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({playlist_id: url, lang: ($('#plsync-lang') && $('#plsync-lang').value || 'zh-TW').trim()})});
      const d = await r.json();
      plJobId = d.job_id;
      renderPlSync({state:'queued', total: 0, done: 0});
      plPollTimer = setInterval(async () => {
        try {
          const sr = await fetch(`/api/playlist/sync/status/${encodeURIComponent(plJobId)}`);
          const st = await sr.json();
          renderPlSync(st);
          if (st.state === 'complete' || st.state === 'stopped' || st.state === 'failed') {
            if (plPollTimer) { clearInterval(plPollTimer); plPollTimer = null; }
            loadCaches();
            loadLibrary();
          }
        } catch {}
      }, 2000);
    } catch (e) { mdui.snackbar({message:'Playlist sync failed: '+e.message}); }
    if (startBtn) startBtn.loading = false;
  };

    /* ---- bulk refetch-all (admin options, threads + processes, queued translate) ---- */
  const segInit = (id) => {
    document.querySelectorAll(`#${id} mdui-segmented-button-item`).forEach(item => {
      item.addEventListener('click', () => {
        document.querySelectorAll(`#${id} mdui-segmented-button-item`).forEach(o => {
          if (o === item) o.setAttribute('selected', '');
          else o.removeAttribute('selected');
        });
      });
    });
  };
  const segVal = (id, dflt) => {
    const sel = document.querySelector(`#${id} mdui-segmented-button-item[selected]`);
    return (sel && sel.getAttribute('value')) || dflt;
  };
  let bulkTimer = null;
  let bulkJobId = null;
  const renderBulk = st => {
    const progress = $('#bulk-progress');
    const summary = $('#bulk-summary');
    const status = $('#bulk-status');
    const list = $('#bulk-results');
    const running = st && (st.state === 'running');
    if (status) status.textContent = (st && st.state) || 'idle';
    const stopBtn = $('#bulk-stop');
    if (stopBtn) stopBtn.style.display = running ? '' : 'none';
    if (progress) progress.value = (st && st.total > 0) ? Math.min(1, st.done / st.total) : 0;
    if (summary) summary.textContent = st && st.total > 0
      ? `${st.done}/${st.total} up=${st.upgraded || 0} kept=${st.kept || 0} failed=${st.failed || 0} err=${st.errors || 0} tr=${st.tq_done || 0}/${st.tq_queued || 0}${st.current ? '  ' + (st.current.song || st.current.video_id) : ''}`
      : '';
    if (list) {
      list.innerHTML = '';
      const rows = (st && st.results) || [];
      if (!rows.length) {
        list.appendChild(el('div', {style:'font-size:12.5px; color:rgb(var(--mdui-color-outline)); padding:8px 0;'},
          running ? 'Fetching...' : 'No bulk refetch yet. Pick a scope/mode and Start.'));
        return;
      }
      rows.slice(-100).reverse().forEach(t => {
        const cls = t.status === 'upgraded' ? 'rb-upgraded' : t.status === 'kept' ? 'rb-same' : (t.status === 'failed' || t.status === 'error') ? 'rb-failed' : 'rb-already';
        const row = el('div', {class:`rebase-row ${cls}`});
        row.appendChild(document.createTextNode(`${t.song || '?'} - ${t.artist || ''} | ${t.from || '?'}->${t.to || '?'} | ${t.status}${t.source ? ' | ' + t.source : ''}`));
        if (t.status === 'upgraded' && t.video_id) {
          row.appendChild(document.createTextNode('  '));
          const pv = el('button', {class:'pl-sync-preview', style:'background:none;border:none;color:rgb(var(--mdui-color-primary));cursor:pointer;padding:0;font-size:12px;'}, 'preview');
          pv.addEventListener('click', () => openPreview(t.video_id, t.lang || 'zh-TW'));
          row.appendChild(pv);
        }
        list.appendChild(row);
      });
    }
  };
  const stopBulk = async () => {
    try { await API('/api/admin/library/refetch/stop', {method:'POST'}); } catch {}
    if (bulkTimer) { clearInterval(bulkTimer); bulkTimer = null; }
  };
  const startBulk = async () => {
    const startBtn = $('#bulk-start');
    if (startBtn) startBtn.loading = true;
    if (bulkTimer) { clearInterval(bulkTimer); bulkTimer = null; }
    const num = (id, dflt, lo, hi) => {
      const v = parseInt(($('#' + id) && $('#' + id).value) || dflt, 10);
      return Math.max(lo, Math.min(hi, isNaN(v) ? dflt : v));
    };
    try {
      const r = await API('/api/admin/library/refetch/start', {method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          scope: segVal('bulk-scope', 'non-wbw'),
          mode: segVal('bulk-mode', 'fresh'),
          lang: (($('#bulk-lang') && $('#bulk-lang').value) || 'zh-TW').trim(),
          workers: num('bulk-workers', 8, 1, 32),
          cpu_workers: num('bulk-cpu', 2, 1, 64),
          translate: !!(($('#bulk-translate') && $('#bulk-translate').checked)),
        })});
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || 'start failed');
      bulkJobId = d.job_id;
      renderBulk({state:'running', total: d.total || 0, done: 0});
      bulkTimer = setInterval(async () => {
        try {
          const sr = await fetch(`/api/admin/library/refetch/status/${encodeURIComponent(bulkJobId)}`);
          const st = await sr.json();
          renderBulk(st);
          if (st.state === 'done' || st.state === 'stopped') {
            if (bulkTimer) { clearInterval(bulkTimer); bulkTimer = null; }
            loadCaches();
            loadLibrary();
          }
        } catch {}
      }, 2000);
    } catch (e) { mdui.snackbar({message:'Bulk refetch failed: '+e.message}); }
    if (startBtn) startBtn.loading = false;
  };

  /* ---- nav ---- */
  const pages = ['overview','logs','caches','library','nodes','jwt','update','files','crashes'];
  const switchPage = p => {
    if (!pages.includes(p)) return;
    activePage = p;
    $$('.page').forEach(sec => sec.classList.toggle('active', sec.id === `page-${p}`));
    $$('#nav-list mdui-list-item').forEach(item => { item.active = (item.dataset.page === p); });
    if (p==='overview') loadOverview();
    else if (p==='logs') connectSSE();
    else if (p==='caches') loadCaches();
    else if (p==='library') loadLibrary();
    else if (p==='nodes') loadNodes();
    else if (p==='jwt') loadJwt();
    else if (p==='update') loadUpdate();
    else if (p==='files') loadFiles();
    else if (p==='crashes') loadCrashes();
  };
  const initNav = () => {
    $$('#nav-list mdui-list-item').forEach(item => {
      item.addEventListener('click', () => { switchPage(item.dataset.page); });
    });
  };

  /* ---- polling ---- */
  const startPolls = () => {
    Object.entries(POLL).forEach(([page, ms]) => {
      if (!ms) return;
      timers[page] = setInterval(() => { if (activePage===page) { if (page==='overview') loadOverview(); else if (page==='caches') loadCaches(); else if (page==='library') loadLibrary(); else if (page==='nodes') loadNodes(); else if (page==='jwt') loadJwt(); else if (page==='update') loadUpdate(); else if (page==='files') loadFiles(); else if (page==='crashes') loadCrashes(); } }, ms);
    });
  };

  /* ---- init ---- */
  const init = () => {
    applyTheme();
    initNav();
    startPolls();
    connectSSE();
    switchPage('overview');
    setInterval(tickUptime, 1000);

    const drawerBtn = $('#nav-drawer-btn');
    if (drawerBtn) drawerBtn.addEventListener('click', () => { try{$('#drawer').open = !$('#drawer').open;}catch{} });

    const themeBtn = $('#theme-btn');
    if (themeBtn) themeBtn.addEventListener('click', () => { themeIdx = (themeIdx+1) % THEMES.length; localStorage.setItem('ymtu-theme-idx', themeIdx); applyTheme(); mdui.snackbar({message:'Theme: '+THEMES[themeIdx], autoCloseDelay:1200}); });

    const logoutBtn = $('#logout-btn');
    if (logoutBtn) logoutBtn.addEventListener('click', async () => { await mdui.confirm({headline:'Sign out',description:'End admin session?',cancelText:'Cancel',confirmText:'Sign out',onConfirm:async()=>{await API('/logout',{method:'POST'}); window.location='/login';}}); });

    const logPauseBtn = $('#log-pause');
    if (logPauseBtn) logPauseBtn.addEventListener('click', () => { logPaused = !logPaused; logPauseBtn.setAttribute('icon', logPaused ? 'play_arrow' : 'pause'); logPauseBtn.textContent = logPaused ? 'Resume' : 'Pause'; });
    const logDownloadBtn = $('#log-download');
    if (logDownloadBtn) logDownloadBtn.addEventListener('click', downloadLogs);
    const logClearBtn = $('#log-clear');
    if (logClearBtn) logClearBtn.addEventListener('click', clearLogs);

    const cacheSearch = $('#cache-search');
    if (cacheSearch) cacheSearch.addEventListener('input', () => renderCaches(cacheSearch.value));
    const cacheClearBtn = $('#cache-clear-empty');
    if (cacheClearBtn) cacheClearBtn.addEventListener('click', clearEmptyCaches);

    const nodeGenBtn = $('#node-generate');
    if (nodeGenBtn) nodeGenBtn.addEventListener('click', generateNode);
    const genCopyBtn = $('#gen-copy-btn');
    if (genCopyBtn) genCopyBtn.addEventListener('click', copyGenCode);
    const genCloseBtn = $('#gen-close');
    if (genCloseBtn) genCloseBtn.addEventListener('click', () => { try{$('#gen-dialog').open=false;}catch{} });

    const jwtCheckBtn = $('#jwt-check');
    if (jwtCheckBtn) jwtCheckBtn.addEventListener('click', () => checkJwt(jwtCheckBtn));
    const jwtContribBtn = $('#jwt-contribute');
    if (jwtContribBtn) jwtContribBtn.addEventListener('click', contributeJwt);

    const updateCheckBtn = $('#update-check');
    if (updateCheckBtn) updateCheckBtn.addEventListener('click', async ()=>{ updateCheckBtn.loading=true; try{await loadUpdate(); mdui.snackbar({message:'Update state refreshed'});}catch{} updateCheckBtn.loading=false; });
    const updatePerformBtn = $('#update-perform');
    if (updatePerformBtn) updatePerformBtn.addEventListener('click', performUpdate);
    const updateConfigBtn = $('#update-config');
    if (updateConfigBtn) updateConfigBtn.addEventListener('click', setMainFile);
    const updateCloseBtn = $('#update-close-btn');
    if (updateCloseBtn) updateCloseBtn.addEventListener('click', ()=>{ try{$('#updateDialog').open=false;}catch{} });

    const fileRefreshBtn = $('#files-refresh');
    if (fileRefreshBtn) fileRefreshBtn.addEventListener('click', loadFiles);
    const crashClearBtn = $('#crash-clear');
    if (crashClearBtn) crashClearBtn.addEventListener('click', clearCrashes);
    const crashDownloadBtn = $('#crash-download');
    if (crashDownloadBtn) crashDownloadBtn.addEventListener('click', downloadLogsBundle);

    const infoRefreshBtn = $('#info-refresh');
    if (infoRefreshBtn) infoRefreshBtn.addEventListener('click', loadOverview);

    const rebaseStartBtn = $('#rebase-start');
    if (rebaseStartBtn) rebaseStartBtn.addEventListener('click', startRebase);
    const rebaseStopBtn = $('#rebase-stop');
    if (rebaseStopBtn) rebaseStopBtn.addEventListener('click', stopRebase);
    const retitleAllBtn = $('#unlyriced-retitle-all');
    if (retitleAllBtn) retitleAllBtn.addEventListener('click', retitleAll);
    const retitleCloseBtn = $('#retitle-close');
    if (retitleCloseBtn) retitleCloseBtn.addEventListener('click', () => { try{$('#retitle-dialog').open=false;}catch{} });
    const renameCancelBtn = $('#rename-cancel');
    if (renameCancelBtn) renameCancelBtn.addEventListener('click', () => { try{$('#rename-dialog').open=false;}catch{} });
    const renameSaveBtn = $('#rename-save');
    if (renameSaveBtn) renameSaveBtn.addEventListener('click', () => saveRename(false));
    const renameSaveCheckBtn = $('#rename-save-check');
    if (renameSaveCheckBtn) renameSaveCheckBtn.addEventListener('click', () => saveRename(true));
    const refetchProbeBtn = $('#refetch-probe');
    if (refetchProbeBtn) refetchProbeBtn.addEventListener('click', probeRefetch);
    const refetchUrl = $('#refetch-url');
    if (refetchUrl) refetchUrl.addEventListener('keydown', e => { if (e.key === 'Enter') probeRefetch(); });
    const plSyncStartBtn = $('#plsync-start');
    if (plSyncStartBtn) plSyncStartBtn.addEventListener('click', startPlaylistSyncWeb);
    const plSyncStopBtn = $('#plsync-stop');
    if (plSyncStopBtn) plSyncStopBtn.addEventListener('click', stopPlaylistSyncWeb);
    const plSyncUrl = $('#plsync-url');
    if (plSyncUrl) plSyncUrl.addEventListener('keydown', e => { if (e.key === 'Enter') startPlaylistSyncWeb(); });
    segInit('bulk-scope');
    segInit('bulk-mode');
    const bulkStartBtn = $('#bulk-start');
    if (bulkStartBtn) bulkStartBtn.addEventListener('click', startBulk);
    const bulkStopBtn = $('#bulk-stop');
    if (bulkStopBtn) bulkStopBtn.addEventListener('click', stopBulk);
    document.querySelectorAll('#rebase-mode mdui-segmented-button-item').forEach(item => {
      item.addEventListener('click', () => {
        rebaseMode = item.getAttribute('value') || 'cached';
        document.querySelectorAll('#rebase-mode mdui-segmented-button-item').forEach(other => {
          if (other === item) other.setAttribute('selected', '');
          else other.removeAttribute('selected');
        });
      });
    });
    const prevPlayBtn = $('#prev-play');
    if (prevPlayBtn) prevPlayBtn.addEventListener('click', togglePreviewPlay);
    const prevDialog = $('#preview-dialog');
    if (prevDialog) prevDialog.addEventListener('closed', () => { destroyYtPlayer(); prevYtPlaying = false; const v = braccatoView(); if (v) { try { v.playing = false; v.lyrics = []; } catch {} } });
  };

  document.addEventListener('DOMContentLoaded', init);
})();
