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
    const d = Date.now() - new Date(iso).getTime();
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
    eventSource.addEventListener('retitle_progress', e => {
      try {
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
      list.appendChild(el('div', {class:'list-row cache', style:'font-size:13px;'},
        el('span', {class:'truncate'}, `${c.artist} - ${c.song}`),
        el('span', {}, c.source),
        el('span', {}, c.synced ? 'sync' : ''),
        el('span', {class:'mono'}, fmt(c.lines)),
        el('span', {}, c.time_ago),
        el('span', {class:'truncate mono'}, c.video_id?.slice(0,6) || ''),
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
    if (t.ok) return el('span', {class:'pill pill-ok'}, el('span', {class:'dot'}), 'ok');
    if (t.live) return el('span', {class:'pill pill-warn'}, el('span', {class:'dot'}), 'unverified');
    return el('span', {class:'pill pill-mute'}, 'empty');
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
  const pingLoop = async (progress, stage, pingEl, closeBtn) => {
    let attempt = 0;
    const tick = 1600;
    while (true) {
      attempt++;
      if (progress) { progress.indeterminate = false; progress.value = Math.min(0.95, 0.15 + attempt*0.06); }
      if (pingEl) pingEl.innerHTML = `<span class="live-dot"></span> Waiting for server (attempt ${attempt})`;
      await new Promise(res => setTimeout(res, tick));
      try {
        const r = await fetch('/api/admin/self_update/check');
        if (r.ok) {
          const data = await r.json();
          if (progress) { progress.indeterminate=false; progress.value=1; }
          if (stage) stage.textContent = `Updated -- now at ${shortSha(data.local_sha)}`;
          if (pingEl) pingEl.innerHTML = 'Server is back';
          if (closeBtn) closeBtn.disabled = false;
          setTimeout(()=>{ try{$('#updateDialog').open=false;}catch{} loadUpdate(); }, 1600);
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
      } catch {}
      if (status.state === 'running') startRebaseFastPoll(); else stopRebaseFastPoll();
      if (retitleStatus.state === 'running') startRetitleFastPoll(); else stopRetitleFastPoll();
    } catch {}
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
      if (!items.length) return;
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
      const row = el('div', {class:'list-row', style:'grid-template-columns: 1fr auto auto;'},
        el('span', {class:'truncate'}, `${item.song || ''} - ${item.artist || ''} (${item.video_id || ''})`)
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

  /* ---- lyrics preview ---- */
  let prevData = null;
  let prevPlaying = false;
  let prevPlayhead = 0;
  let prevRafId = null;
  let prevStartTime = 0;
  let prevBaseTime = 0;
  let prevLastAutoIndex = -1;
  let prevScrubbing = false;
  let prevMaxTime = 100;
  const stopPreviewPlayback = () => {
    prevPlaying = false;
    if (prevRafId) { cancelAnimationFrame(prevRafId); prevRafId = null; }
  };
  const openPreview = async (videoId, lang) => {
    stopPreviewPlayback();
    const dlg = $('#preview-dialog');
    if (!dlg) return;
    try {
      const data = await json(`/api/admin/cache/preview?v=${encodeURIComponent(videoId)}&lang=${encodeURIComponent(lang)}`);
      prevData = data;
      prevPlayhead = 0;
      prevLastAutoIndex = -1;
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
          seek.addEventListener('change', () => { prevScrubbing = false; });
        }
      }
      renderPrevLyrics();
      updatePrevTime();
      const playBtn = $('#prev-play');
      if (playBtn) playBtn.setAttribute('icon', 'play_arrow');
      dlg.open = true;
    } catch (e) { mdui.snackbar({message:'Preview failed: '+e.message}); }
  };
  const renderPrevLyrics = () => {
    const container = $('#prev-lyrics');
    if (!container || !prevData) return;
    container.innerHTML = '';
    const lines = prevData.lyrics || [];
    lines.forEach(line => {
      const div = el('div', {class:'prev-line'});
      if (line.parts && line.parts.length) {
        line.parts.forEach((part, i) => {
          if (i > 0) div.appendChild(document.createTextNode(' '));
          div.appendChild(el('span', {class:'prev-word', 'data-start': (part.startTimeMs || 0) / 1000, 'data-dur': (part.durationMs || 0) / 1000}, (part.words != null ? part.words : part.text) || ''));
        });
      } else {
        div.appendChild(document.createTextNode(line.text || ''));
      }
      if (line.translated) div.appendChild(el('div', {class:'trans'}, line.translated));
      container.appendChild(div);
    });
  };
  const updatePrevTime = () => {
    const t = Math.max(0, Math.floor(prevPlayhead));
    const m = Math.floor(t / 60);
    const s = t % 60;
    const label = $('#prev-time');
    if (label) label.textContent = `${m}:${s.toString().padStart(2,'0')}`;
  };
  const updatePrevHighlight = () => {
    const container = $('#prev-lyrics');
    if (!container || !prevData) return;
    const lines = prevData.lyrics || [];
    const lineEls = container.querySelectorAll('.prev-line');
    const starts = lines.map(l => (l.time != null ? l.time : (l.startTimeMs != null ? l.startTimeMs / 1000 : 0)));
    const ends = lines.map((l, i) => {
      const d = (l.durationMs != null ? l.durationMs / 1000 : (l.duration != null ? l.duration : 0)) || 0;
      if (d > 0) return starts[i] + d;
      let next = Infinity;
      starts.forEach((s, j) => { if (j !== i && s > starts[i] && s < next) next = s; });
      return next;
    });
    let activeIdx = -1;
    let activeStart = -Infinity;
    for (let i = 0; i < lines.length; i++) {
      if (prevPlayhead >= starts[i] && prevPlayhead < ends[i] && starts[i] >= activeStart) { activeIdx = i; activeStart = starts[i]; }
    }
    if (activeIdx < 0) {
      for (let i = 0; i < lines.length; i++) {
        if (prevPlayhead >= starts[i] && starts[i] >= activeStart) { activeIdx = i; activeStart = starts[i]; }
      }
    }
    lineEls.forEach((lineEl, i) => {
      lineEl.classList.toggle('prev-active', i === activeIdx);
      const words = lineEl.querySelectorAll('.prev-word');
      words.forEach(w => {
        const start = parseFloat(w.dataset.start) || 0;
        const dur = Math.max(parseFloat(w.dataset.dur) || 0, 0.15);
        const active = i === activeIdx && prevPlayhead >= start && prevPlayhead < (start + dur);
        w.classList.toggle('prev-word-active', active);
      });
    });
    if (activeIdx >= 0 && activeIdx !== prevLastAutoIndex && lineEls[activeIdx]) {
      prevLastAutoIndex = activeIdx;
      const activeEl = lineEls[activeIdx];
      const target = activeEl.offsetTop - (container.clientHeight / 2) + (activeEl.offsetHeight / 2);
      container.scrollTop = Math.max(0, target);
    }
    const seek = $('#prev-seek');
    if (seek && !prevScrubbing) seek.value = Math.min(prevPlayhead, prevMaxTime);
    updatePrevTime();
  };
  const prevTick = () => {
    if (!prevPlaying) return;
    const elapsed = (performance.now() - prevStartTime) / 1000;
    prevPlayhead = prevBaseTime + elapsed;
    if (prevPlayhead >= prevMaxTime) {
      prevPlayhead = prevMaxTime;
      updatePrevHighlight();
      stopPreviewPlayback();
      const btn = $('#prev-play');
      if (btn) btn.setAttribute('icon', 'play_arrow');
      return;
    }
    updatePrevHighlight();
    prevRafId = requestAnimationFrame(prevTick);
  };
  const togglePreviewPlay = () => {
    if (!prevData) return;
    const btn = $('#prev-play');
    if (prevPlaying) {
      stopPreviewPlayback();
      if (btn) btn.setAttribute('icon', 'play_arrow');
    } else {
      if (prevPlayhead >= prevMaxTime) { prevPlayhead = 0; prevBaseTime = 0; prevLastAutoIndex = -1; }
      prevPlaying = true;
      prevStartTime = performance.now();
      prevBaseTime = prevPlayhead;
      if (btn) btn.setAttribute('icon', 'pause');
      prevRafId = requestAnimationFrame(prevTick);
    }
  };
  const prevSeek = e => {
    prevPlayhead = Math.min(Math.max(parseFloat(e.target.value) || 0, 0), prevMaxTime);
    prevBaseTime = prevPlayhead;
    if (prevPlaying) prevStartTime = performance.now();
    prevLastAutoIndex = -1;
    updatePrevHighlight();
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
    const prevSeekEl = $('#prev-seek');
    if (prevSeekEl) prevSeekEl.addEventListener('input', prevSeek);
    const prevDialog = $('#preview-dialog');
    if (prevDialog) prevDialog.addEventListener('closed', stopPreviewPlayback);
  };

  document.addEventListener('DOMContentLoaded', init);
})();
