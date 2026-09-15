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
  const POLL = { overview: 8000, logs: null, caches: 10000, nodes: 6000, jwt: 8000, update: 15000, files: 10000, crashes: 10000 };
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

  /* ---- uptime ---- */
  let startIso = null;
  const tickUptime = () => {
    if (!startIso) return;
    const s = Math.max(0, Math.floor((Date.now() - new Date(startIso).getTime()) / 1000));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    setVal('#stat-uptime', `${h}h ${m}m ${sec}s`);
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
      list.appendChild(el('div', {class:'list-row cache', style:'font-size:12.5px;'},
        el('span', {class:'truncate'}, `${c.artist} - ${c.song}`),
        el('span', {}, c.source),
        el('span', {}, c.synced ? 'sync' : ''),
        el('span', {class:'mono'}, fmt(c.lines)),
        el('span', {}, c.time_ago),
        el('span', {class:'truncate mono'}, c.video_id?.slice(0,6) || ''),
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
      list.appendChild(el('div', {class:'list-row node', style:'font-size:12.5px;'},
        el('span', {}, n.label || '(unnamed)'),
        el('span', {class:'mono truncate'}, n.node_id || ''),
        el('span', {}, n.last_seen ? ago(n.last_seen)+' ago' : ''),
        el('span', {}, el('span', {class: n.online ? 'pill pill-ok' : 'pill pill-mute'}, el('span', {class:'dot'}), n.online ? 'online' : 'offline')),
      ));
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
  const loadJwt = async () => {
    try {
      const data = await json('/api/admin/jwt/list');
      setVal('#jwt-count', fmt(data.count));
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
        const row = el('div', {class:'list-row file', style:'font-size:12.5px;'},
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

  /* ---- nav ---- */
  const pages = ['overview','logs','caches','nodes','jwt','update','files','crashes'];
  const switchPage = p => {
    if (!pages.includes(p)) return;
    activePage = p;
    $$('.page').forEach(sec => sec.classList.toggle('active', sec.id === `page-${p}`));
    $$('#nav-list mdui-list-item').forEach(item => { item.active = (item.dataset.page === p); });
    if (p==='overview') loadOverview();
    else if (p==='logs') connectSSE();
    else if (p==='caches') loadCaches();
    else if (p==='nodes') loadNodes();
    else if (p==='jwt') loadJwt();
    else if (p==='update') loadUpdate();
    else if (p==='files') loadFiles();
    else if (p==='crashes') loadCrashes();
  };
  const initNav = () => {
    $$('#nav-list mdui-list-item').forEach(item => {
      item.addEventListener('click', () => { switchPage(item.dataset.page); try{$('#drawer').open=false;}catch{} });
    });
  };

  /* ---- polling ---- */
  const startPolls = () => {
    Object.entries(POLL).forEach(([page, ms]) => {
      if (!ms) return;
      timers[page] = setInterval(() => { if (activePage===page) { if (page==='overview') loadOverview(); else if (page==='caches') loadCaches(); else if (page==='nodes') loadNodes(); else if (page==='jwt') loadJwt(); else if (page==='update') loadUpdate(); else if (page==='files') loadFiles(); else if (page==='crashes') loadCrashes(); } }, ms);
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
  };

  document.addEventListener('DOMContentLoaded', init);
})();
