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
  // Push cadence for the SSE heartbeat (?interval=); page data refreshes
  // server-driven on each ping instead of client-side polling.
  const SSE_INTERVAL = 15;

  const $ = s => document.querySelector(s);
  const $$ = s => [...document.querySelectorAll(s)];
  // Build an element. Coerces primitive children to text nodes and skips
  // null/undefined/false. Only objects are appended as nodes -- a bare number
  // reaches here constantly (a count, a percentile) and `appendChild(51)` is a
  // TypeError on a real DOM, so `typeof c === 'string'` would have let one tile
  // with a numeric value take the whole panel's render down with it. This is the
  // ONE el() for the dashboard, so the coercion has to live here.
  const el = (tag, attrs, ...kids) => {
    const e = document.createElement(tag);
    if (attrs) Object.entries(attrs).forEach(([k, v]) => {
      if (k === 'class') e.className = v;
      else if (k === 'html') e.innerHTML = v;
      else e.setAttribute(k, v);
    });
    // Primitive children become text nodes; only objects are appended as nodes.
    kids.forEach(c => {
      if (c == null || c === false) return;
      if (typeof c === 'object') e.appendChild(c);
      else e.appendChild(document.createTextNode(String(c)));
    });
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
      // Rides along on this same payload -- no extra request per refresh.
      if (info.latency) renderLatency(info.latency);
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

  /* ---- lyrics latency widget ----
     Percentiles, not averages: a fetch is bimodal (cache hit ~1ms, cold fetch
     seconds), so one mean describes neither end. Three cards for the numbers
     the operator asks about, then every metric the server keeps. Labels live
     here, not on the server, but the ORDER comes from the server's `order`
     key so a new metric shows up with its raw name instead of vanishing. */
  const LAT_CARDS = [
    {key: 'song', title: 'Time per song', icon: 'music_note'},
    {key: 'ttf_line', title: 'Time to line-sync', icon: 'view_headline'},
    {key: 'ttf_wbw', title: 'Time to word-by-word', icon: 'subtitles'},
  ];
  const LAT_LABELS = {
    song: 'Time per song',
    ttf_line: 'Time to line-sync',
    ttf_wbw: 'Time to word-by-word',
    song_fetch: 'Per song (providers only)',
    song_wbw: 'Per song, wbw winner',
    song_line: 'Per song, line winner',
    song_plain: 'Per song, plain winner',
    miss: 'Per song, nothing found',
    cache: 'Cache hit',
  };
  const fmtMs = ms => {
    if (ms == null || !isFinite(ms)) return '--';
    if (ms < 1000) return `${Math.round(ms)}ms`;
    if (ms < 60000) return `${(ms / 1000).toFixed(ms < 10000 ? 2 : 1)}s`;
    return `${Math.round(ms / 60000)}m`;
  };
  // Fixed thresholds, not relative to the row: a relative colour would make a
  // uniformly slow server paint green because every row is slow in the same
  // way. p95 of 3s is the point where a song feels slow to wait for.
  const latClass = ms => (ms == null ? '' : ms >= 10000 ? 'bad' : ms >= 3000 ? 'warn' : '');
  const renderLatency = data => {
    const metrics = (data && data.metrics) || {};
    const cards = $('#lat-cards');
    if (cards) {
      cards.innerHTML = '';
      LAT_CARDS.forEach(c => {
        const m = metrics[c.key] || null;
        const grid = el('div', {class: 'lat-grid3'});
        [['p50', 50], ['p95', 95], ['p99', 99]].forEach(([k, p]) => {
          const v = m ? m[k] : null;
          grid.appendChild(el('div', {class: 'k'}, `${p}%`));
          grid.appendChild(el('div', {class: `v lat-v ${latClass(v)}`}, fmtMs(v)));
        });
        cards.appendChild(el('div', {class: 'lat-card'},
          el('div', {class: 'lat-t'}, c.title),
          el('div', {class: 'lat-n'}, m ? `${m.n} sample(s), last ${fmtMs(m.last)}` : 'no samples yet'),
          grid,
        ));
      });
    }
    const rows = $('#lat-rows');
    if (rows) {
      rows.innerHTML = '';
      const order = (data && data.order) && data.order.length
        ? data.order
        : Object.keys(metrics);
      const keys = order.filter(k => k in metrics);
      if (!keys.length) rows.appendChild(el('div', {class: 'list-row'}, 'No latency samples yet.'));
      keys.forEach(k => {
        // A metric the server knows but has no samples for arrives as null, and
        // the row is still worth showing (an empty ttf_wbw is the interesting
        // case: nothing has ever reached word timing). Reading m.n straight off
        // a null is how this table dies on a fresh install.
        const m = metrics[k] || {};
        rows.appendChild(el('div', {class: 'list-row lat'},
          el('span', {}, LAT_LABELS[k] || k),
          el('span', {class: 'v'}, fmt(m.n)),
          el('span', {class: 'v lat-v ' + latClass(m.p50)}, fmtMs(m.p50)),
          el('span', {class: 'v lat-v ' + latClass(m.p95)}, fmtMs(m.p95)),
          el('span', {class: 'v lat-v ' + latClass(m.p99)}, fmtMs(m.p99)),
          el('span', {class: 'v'}, fmtMs(m.min)),
          el('span', {class: 'v'}, fmtMs(m.max)),
        ));
      });
    }
    const pill = $('#lat-updated');
    if (pill) {
      const at = (data && data.updated_at) || 0;
      // `updated_at` is the newest SAMPLE, not the newest render, and it is a
      // unix epoch rather than an ISO string -- the `ago()` helper takes ISO.
      pill.textContent = at
        ? `last sample ${ago(new Date(at * 1000).toISOString())} ago`
        : 'no samples yet';
    }
  };
  const loadLatency = async () => {
    try { renderLatency(await json('/api/admin/latency')); }
    catch (e) { console.warn('latency load failed', e); }
  };
  const clearLatency = async () => {
    await mdui.confirm({
      headline: 'Clear latency samples',
      description: 'Drop every latency percentile? Only fetches from now on will be recorded.',
      cancelText: 'Cancel', confirmText: 'Clear',
      onConfirm: async () => {
        const d = await (await API('/api/admin/latency/clear', {method: 'POST'})).json();
        renderLatency(d);
        mdui.snackbar({message: d.cleared ? 'Latency samples cleared' : 'There was nothing to clear'});
      },
    });
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
    eventSource = new EventSource(`/api/admin/events?interval=${SSE_INTERVAL}`);
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
        // rather than dropping every line silently (empty #refetch-live) --
        // but never render into an idle run with no active probe.
        if (d.run_id && d.run_id !== probeRunId) return;
        if (!d.run_id && !probeRunId) return;
        const final = !d.provider || d.provider === 'probe';
        if ((d.status === 'done' || d.status === 'complete') && final) { finishProbeRun(); return; }
        if (d.status === 'error' && final) { finishProbeRun(true); return; }
        if (d.status === 'found' && d.run_id) {
          probeFoundCount++;
          setProbeStatus(`probing... ${probeFoundCount}`, 'pill-warn');
        }
        probeLiveLine(d.provider || '?', d.status || '', d.detail || '');
      } catch {}
    });
    eventSource.addEventListener('retitle_phase', e => {
      try {
        const d = JSON.parse(e.data);
        const box = $('#retitle-results');
        if (!box) return;
        box.appendChild(el('div', {style:'font-size:11px; opacity:.5; padding:2px 0;'}, d.message || ''));
        box.scrollTop = box.scrollHeight;
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
    // The sweep and the retranslate job both broadcast exactly one terminal
    // event, so the panel refreshes itself without polling. loadLibrary()
    // would re-run three more scans for this; only the two panels change.
    eventSource.addEventListener('migrate', () => { if (activePage === 'library') loadDbVer(); });
    eventSource.addEventListener('retranslate', () => { if (activePage === 'library') scanRTrans(); });
    eventSource.addEventListener('retitle', e => { if (activePage === 'library') loadLibrary(); });
    eventSource.addEventListener('jwt', () => { if (activePage === 'jwt') loadJwt(); });
    eventSource.addEventListener('ping', () => {
      // Server-driven refresh cadence (see ?interval=): no client polling.
      throttledRefresh();
      if (activePage === 'overview') loadOverview();
      if (activePage === 'jwt') loadJwt();
    });
    eventSource.addEventListener('bulk_progress', e => {
      try {
        const d = JSON.parse(e.data);
        if (!d.job_id || d.job_id !== bulkJobId || !bulkState) return;
        if (d.type === 'start') {
          bulkState.current = {video_id: d.video_id, song: d.song, artist: d.artist};
          bulkState.stage = '';
        } else if (d.type === 'stage') {
          bulkState.stage = `${d.song || d.video_id || '?'} | trying ${d.provider || '?'}...`;
        } else if (d.type === 'batch' || d.type === 'batch_done') {
          if (d.batch != null) bulkState.batch_index = d.batch;
          if (d.batches != null) bulkState.batch_total = d.batches;
          if (d.size != null) bulkState.batch_size = d.size;
          if (d.queued != null) bulkState.queued = d.queued;
          if (d.upgraded != null) bulkState.upgraded = d.upgraded;
          if (d.kept != null) bulkState.kept = d.kept;
          if (d.failed != null) bulkState.failed = d.failed;
          if (d.errors != null) bulkState.errors = d.errors;
          if (d.done != null) bulkState.done = d.done;
        } else if (d.type === 'drain') {
          // Fetches are done, the job is now waiting on the translate queue.
          bulkState.state = 'translating';
          bulkState.stage = d.tq_pending
            ? `translating: ${d.tq_pending} waiting on Cohere`
            : 'translations drained';
          if (d.tq_pending != null) bulkState.tq_pending = d.tq_pending;
        } else if (d.type === 'tune') {
          if (d.workers != null) setBulkField('#bulk-workers', d.workers);
          if (d.cpu_workers != null) setBulkField('#bulk-cpu', d.cpu_workers);
          if (d.tq_workers != null) setBulkField('#bulk-tq', d.tq_workers);
          if (d.batch != null) setBulkField('#bulk-batch', d.batch);
          if (d.translate != null && $('#bulk-translate')) $('#bulk-translate').checked = !!d.translate;
        } else if (d.type === 'row' && d.row) {
          bulkState.results.push(d.row);
          while (bulkState.results.length > 300) bulkState.results.shift();
          bulkState.done = d.done != null ? d.done : bulkState.done;
          if (d.upgraded != null) bulkState.upgraded = d.upgraded;
          if (d.kept != null) bulkState.kept = d.kept;
          if (d.failed != null) bulkState.failed = d.failed;
          if (d.errors != null) bulkState.errors = d.errors;
          if (d.skipped != null) bulkState.skipped = d.skipped;
          if (d.tq_done != null) bulkState.tq_done = d.tq_done;
          if (d.tq_queued != null) bulkState.tq_queued = d.tq_queued;
          if (d.tq_pending != null) bulkState.tq_pending = d.tq_pending;
          if (d.tq_workers != null) bulkState.tq_workers = d.tq_workers;
          bulkState.stage = '';
        } else if (d.type === 'done') {
          bulkState.state = d.state || 'done';
          bulkState.current = null;
          bulkState.stage = '';
          if (d.skipped != null) bulkState.skipped = d.skipped;
          if (d.tq_pending != null) bulkState.tq_pending = d.tq_pending;
        }
        renderBulk(bulkState);
        if (d.type === 'done') { try { sessionStorage.removeItem('ymtu-bulk-job'); } catch {} loadCaches(); loadLibrary(); }
      } catch {}
    });
    eventSource.addEventListener('playlist_sync_progress', e => {
      try {
        const d = JSON.parse(e.data);
        if (!d.job_id || d.job_id !== plJobId || !plState) return;
        if (d.state === 'complete' || d.state === 'stopped' || d.state === 'failed') {
          plState.state = d.state;
          renderPlSync(plState);
          try { sessionStorage.removeItem('ymtu-playlist-job'); } catch {}
          loadCaches();
          loadLibrary();
          return;
        }
        if (d.video_id) {
          const t = {video_id: d.video_id, title: d.song, song: d.song, artist: d.artist,
                     tag: d.status, status: d.status, source: d.source || ''};
          const ix = plState.tracks.findIndex(x => x.video_id === d.video_id);
          if (ix >= 0) plState.tracks[ix] = t; else plState.tracks.push(t);
          plState.done = d.done != null ? d.done : plState.done;
          plState.total = d.total != null ? d.total : plState.total;
          plState.found = plState.tracks.filter(x => (x.tag || x.status) === 'found').length;
          plState.unlyriced = plState.tracks.filter(x => (x.tag || x.status) === 'unlyriced').length;
          plState.error_count = plState.tracks.filter(x => { const s = x.tag || x.status; return s === 'error' || s === 'invalid_id'; }).length;
          plState.current = `${d.song || d.video_id || ''} - ${d.artist || ''}`;
          renderPlSync(plState);
        }
      } catch {}
    });
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
      const jwtPill = el('span', {class: n.jwt_sync ? 'pill pill-ok' : 'pill pill-mute',
                                  style:'cursor:pointer; justify-self:end;'}, n.jwt_sync ? 'jwt on' : 'jwt off');
      jwtPill.title = n.jwt_sync ? 'Cubey JWT pool is pushed to this node. Click to stop.' : 'This node gets no JWT pool. Click to allow it.';
      jwtPill.addEventListener('click', async () => {
        try {
          await API(`/api/admin/nodes/${encodeURIComponent(n.node_id)}/jwt_sync`, {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({enabled: !n.jwt_sync})});
          mdui.snackbar({message: `JWT sync ${!n.jwt_sync ? 'enabled' : 'disabled'} for ${n.label || n.node_id}`});
          loadNodes();
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
      });
      const row = el('div', {class:'list-row node', style:'font-size:13.5px;'},
        el('span', {}, n.label || '(unnamed)'),
        el('span', {class:'mono truncate'}, n.node_id || ''),
        el('span', {}, n.last_seen ? ago(n.last_seen)+' ago' : ''),
        el('span', {}, el('span', {class: n.online ? 'pill pill-ok' : 'pill pill-mute'}, el('span', {class:'dot'}), n.online ? 'online' : 'offline')),
        jwtPill,
        el('mdui-button-icon', {icon: 'delete', variant: 'text', style:'color:rgb(var(--mdui-color-error));'})
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
  // The generate response is the ONLY moment the raw key and the rendered
  // script exist in the browser together -- the server keeps only key_hash, so
  // it can never hand this out again for an existing node. Stash the payload
  // for the download buttons instead of decoding it twice.
  let lastGenerated = null;
  const saveBlob = (blob, filename) => {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  const decodeScript = (g) => {
    const bin = atob(g.script_b64 || '');
    const bytes = Uint8Array.from(bin, c => c.charCodeAt(0));
    return new TextDecoder('utf-8').decode(bytes);
  };
  // UTF-8 BOM: without it a Windows host that opens the file in Notepad, or
  // runs it from a cp1252 console, can mangle the non-ASCII lines.
  const asFile = (text) => new Blob(['\uFEFF' + text], {type: 'text/x-python;charset=utf-8'});
  const downloadNodePy = (withRunner) => {
    const g = lastGenerated;
    if (!g?.script_b64) { mdui.snackbar({message: 'Generate a node first'}); return; }
    saveBlob(asFile(decodeScript(g)), g.filename || 'node.py');
    if (!withRunner) return;
    // A .cmd wrapper so a Windows host needs no shell knowledge: it makes a
    // venv, installs the two deps, and starts the node.
    const runner = [
      '@echo off',
      'REM YTMusicUltimate lyrics node -- Windows runner.',
      'REM Created by the server dashboard; safe to edit or delete.',
      'setlocal',
      'cd /d "%~dp0"',
      'where py >nul 2>&1 || (echo py launcher not found: install Python 3 from python.org & exit /b 1)',
      'if not exist ".venv\\Scripts\\python.exe" py -m venv .venv',
      '".venv\\Scripts\\python.exe" -m pip install -q --upgrade pip',
      '".venv\\Scripts\\python.exe" -m pip install -q websocket-client requests',
      'echo Starting node. Press Ctrl+C to stop.',
      '".venv\\Scripts\\python.exe" node.py',
      'pause',
      '',
    ].join('\r\n');
    saveBlob(new Blob([runner], {type: 'application/octet-stream'}), 'run.cmd');
    mdui.snackbar({message: 'node.py + run.cmd downloaded'});
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
        lastGenerated = data;
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
    // !live = record without a usable raw token (legacy hash-only file or
    // evicted): pick_jwt() skips it even when the persisted ok flag is
    // stale-true. Never render those green or the pool looks usable while
    // probes report "no JWT in pool". Live tokens revive on re-contribute.
    if (!t.live) return el('span', {class:'pill pill-mute'}, 'stale');
    if (t.ok) return el('span', {class:'pill pill-ok'}, el('span', {class:'dot'}), 'ok');
    return el('span', {class:'pill pill-warn'}, el('span', {class:'dot'}), 'unverified');
  };
  const jwtVerdict = v => {
    const cls = v === 'ok' ? 'pill-ok' : (v || '').startsWith('dead') ? 'pill-mute' : 'pill-warn';
    return el('span', {class:`pill ${cls}`}, v || 'unverified');
  };
  const renderJwt = tokens => {
    const list = $('#jwt-list'); if (!list) return;
    list.innerHTML = '';
    if (!tokens.length) { list.appendChild(el('div', {class:'list-row'}, 'No pooled tokens')); return; }
    tokens.forEach(t => {
      const okFail = `${t.successes || 0}/${t.fails || 0}`;
      const lastOk = t.last_ok ? `ok ${ago(t.last_ok)} ago` : 'never ok';
      const reqs = el('span', {class:'mono', title:`${t.requests || 0} request(s): ${t.req_ok || 0} ok, ${t.req_auth_fail || 0} auth, ${t.req_other_fail || 0} other`},
        `${t.requests || 0}`);
      if (!(t.requests || 0)) reqs.style.opacity = '.45';   // in the pool, never used
      const row = el('div', {class:'list-row jwt', style:'font-size:13px;'},
        el('span', {class:'mono truncate'}, t.id || '--'),
        el('span', {class:'truncate'}, t.node_id ? `${t.node_id.slice(0,10)}` : '--'),
        el('span', {}, t.added ? ago(t.added)+' ago' : '--'),
        el('span', {}, t.last_checked ? ago(t.last_checked)+' ago' : '--'),
        el('span', {class:'mono', title: lastOk}, okFail),
        jwtVerdict(t.verdict),
        reqs,
        jwtStatus(t),
        el('mdui-button-icon', {icon: 'close', variant: 'text', style:'justify-self:end; color:rgb(var(--mdui-color-error));'})
      );
      const rmBtn = row.lastElementChild;
      rmBtn.addEventListener('click', async () => {
        rmBtn.loading = true;
        try {
          await API('/api/admin/jwt/remove', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id: t.id, reason: 'removed'})});
          mdui.snackbar({message:'Removed from pool'});
          loadJwt();
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        rmBtn.loading = false;
      });
      list.appendChild(row);
    });
  };

  /* ---- jwt charts ---- */
  // Plain divs, because that is all a stacked column per hour needs. Shared
  // helpers so the live-token bars and the death histogram cannot drift apart.
  const hbars = (hostSel, rows, opt = {}) => {
    const host = $(hostSel);
    if (!host) return;
    host.innerHTML = '';
    if (!rows.length) {
      host.appendChild(el('div', {class:'chart-empty'}, opt.empty || 'Nothing recorded yet'));
      return;
    }
    const max = Math.max(1, ...rows.map(r => r.value));
    const wrap = el('div', {class:'hbars'});
    rows.forEach(r => {
      const fill = el('div', {class:`hb-fill ${r.cls || ''}`});
      fill.style.width = `${Math.max(1, (r.value / max) * 100)}%`;
      fill.title = r.title || '';
      wrap.appendChild(el('div', {class:'hbar'},
        el('span', {class:'hb-name', title:r.name}, r.name),
        el('div', {class:'hb-track'}, fill),
        el('span', {class:'hb-val'}, r.label != null ? r.label : fmt(r.value))));
    });
    host.appendChild(wrap);
  };

  const renderJwtHours = hourly => {
    const host = $('#jwt-chart-hours');
    if (!host) return;
    host.innerHTML = '';
    const rows = hourly || [];
    if (!rows.length || !rows.some(h => h.requests || h.contributed || h.retired)) {
      host.appendChild(el('div', {class:'chart-empty'}, 'No traffic recorded yet. Every Cubey request a token makes lands here.'));
      return;
    }
    const max = Math.max(1, ...rows.map(h => h.requests));
    const axis = el('div', {class:'chart-axis'});
    rows.forEach(h => {
      const col = el('div', {class:'col'});
      col.dataset.in = (h.contributed || h.retired) ? '1' : '0';
      col.title = `${h.hour.replace('T',' ').slice(5,16)}`
        + `\nrequests ${h.requests} (ok ${h.ok}, auth ${h.auth_fail}, other ${h.other_fail})`
        + `\nprobes ${h.probes}  added ${h.contributed}  left ${h.retired}`;
      // bottom-up: other, auth, ok -- so the reading is "green on top of red on
      // top of amber", and the tallest colour is the one that filled the hour.
      [['other', h.other_fail], ['auth', h.auth_fail], ['ok', h.ok]].forEach(([k, v]) => {
        if (!v) return;
        const seg = el('div', {class:`seg ${k}`});
        seg.style.height = `${(v / max) * 100}%`;
        col.appendChild(seg);
      });
      host.appendChild(col);
    });
    const first = rows[0], last = rows[rows.length - 1];
    axis.appendChild(el('span', {}, first ? first.hour.replace('T',' ').slice(5,16) : ''));
    axis.appendChild(el('span', {}, `${max} peak`));
    axis.appendChild(el('span', {}, last ? last.hour.replace('T',' ').slice(5,16) : ''));
    // The axis and the legend are siblings of the chart, not children: the chart
    // itself is a flex row of columns and an axis inside it would be laid out
    // as another column. Guarded, because a chart that throws because its host
    // was moved takes the whole JWT page's render with it.
    const parent = host.parentNode;
    if (!parent) return;
    parent.appendChild(axis);
    let legend = parent.querySelector('.chart-legend');
    if (!legend) {
      legend = el('div', {class:'chart-legend'});
      parent.appendChild(legend);
    }
    legend.innerHTML = '';
    const swatch = (color) => {
      // NOT Object.assign(el, {style}): that overwrites the element's style
      // OBJECT with a string, which leaves a real element unstyled -- an
      // invisible swatch and no error anywhere.
      const i = el('i');
      i.style.background = color;
      return i;
    };
    [['rgb(46,125,50)', 'answered'],
     ['rgb(198,40,40)', '401/403'],
     ['rgb(234,179,8)', '429 / 5xx / timeout'],
     ['rgb(var(--mdui-color-primary))', 'token added'],
     ['rgb(var(--mdui-color-outline))', 'token left']].forEach(([color, label]) => {
      const text = el('span', {}, label);
      text.style.color = color;
      legend.appendChild(swatch(color));
      legend.appendChild(text);
    });
  };

  const RETIRE_REASON = {
    dead_twice: 'died (2x 401/403)',
    removed: 'operator removed',
    pool_cap: 'pool cap (32)',
    ttl: 'past 7d TTL',
    unknown: 'unknown',
  };

  const renderJwtStats = d => {
    if (!d) return;
    const s = d.summary || {};

    // ---- tiles ----
    const tiles = $('#jwt-stats-tiles');
    if (tiles) {
      tiles.innerHTML = '';
      const tile = (label, value, sub) => {
        const c = el('mdui-card', {variant:'elevated', class:'stat-card'});
        c.appendChild(el('div', {},
          el('div', {class:'stat-label'}, label),
          el('div', {class:'stat-value mono'}, value),
          sub ? el('div', {class:'stat-label'}, sub) : null));
        tiles.appendChild(c);
      };
      tile('Requests served', fmt(s.requests_total || 0), `${fmt(s.requests_24h || 0)} in 24h`);
      tile('Live tokens', fmt((d.live || []).length), `${fmt(s.retired_total || 0)} retired all-time`);
      tile('Per token (median)', s.tokens_seen ? (s.death_requests_p50 ?? '--') : '--', 'requests before death');
      tile('Died in 24h', fmt(s.died_24h || 0), `${fmt(s.dead_total || 0)} all-time`);
      tile('Best token served', s.death_requests_max != null ? fmt(s.death_requests_max) : '--', 'requests');
      tile('Median lifetime', s.lifetime_s_p50 != null ? fmtDur(s.lifetime_s_p50) : '--', 'contribution to death');
    }

    const note = $('#jwt-stats-note');
    if (note) {
      note.textContent = s.requests_total
        ? `${fmt(s.requests_total)} requests, ${fmt(s.ok_total)} ok, ${fmt(s.auth_fail_total)} auth, ${fmt(s.other_fail_total)} other`
        : 'no history yet';
    }

    renderJwtHours(d.hourly || []);

    // ---- live tokens: who is doing the work ----
    const live = (d.live || []).slice().sort((a, b) => (b.requests || 0) - (a.requests || 0));
    hbars('#jwt-chart-live', live.map(t => ({
      name: `${(t.id || '').slice(0, 10)}${t.node_id ? ' ' + t.node_id.slice(0, 6) : ''}`,
      value: t.requests || 0,
      cls: (t.req_auth_fail || 0) > (t.req_ok || 0) ? 'auth' : 'ok',
      label: `${t.requests || 0}`,
      title: `${t.requests || 0} requests: ${t.req_ok || 0} ok, ${t.req_auth_fail || 0} auth, ${t.req_other_fail || 0} other\n`
        + `${t.probes || 0} probe(s), verdict ${t.verdict || 'unverified'}`,
    })), {empty: 'No live token has served a request yet.'});

    // ---- death histogram: the question that started this ----
    const hist = d.death_histogram || [];
    const deadTotal = hist.reduce((a, b) => a + (b.count || 0), 0);
    hbars('#jwt-chart-death', hist.map(b => ({
      name: b.label,
      value: b.count || 0,
      label: fmt(b.count || 0),
      title: `${b.count || 0} token(s) died after serving ${b.label} request(s)`,
    })), {empty: 'No token has died yet, so there is no distribution to show.'});
    const dnote = $('#jwt-death-note');
    if (dnote) {
      const parts = [];
      if (deadTotal) {
        parts.push(`${deadTotal} token(s) died`);
        if (s.death_requests_p50 != null) parts.push(`median ${s.death_requests_p50} request(s) each`);
        if (s.death_requests_max != null) parts.push(`best ${s.death_requests_max}`);
      }
      const others = (s.retire_reasons || {});
      const manual = Object.entries(others).filter(([k]) => k !== 'dead_twice');
      if (manual.length) {
        parts.push(`left for other reasons: ${manual.map(([k, v]) => `${v}x ${RETIRE_REASON[k] || k}`).join(', ')}`);
      }
      dnote.textContent = parts.join(' | ') || 'nothing retired yet';
    }

    // ---- retired table ----
    const rl = $('#jwt-retired');
    if (rl) {
      rl.innerHTML = '';
      const rows = (d.retired || []).slice().reverse();
      if (!rows.length) {
        rl.appendChild(el('div', {class:'list-row'}, 'No retired tokens recorded'));
      } else {
        rows.slice(0, 60).forEach(r => {
          const why = RETIRE_REASON[r.reason] || r.reason;
          rl.appendChild(el('div', {class:'list-row retired'},
            el('span', {class:'mono truncate'}, r.id || '--'),
            el('span', {class:'truncate'}, r.node_id ? r.node_id.slice(0,10) : '--'),
            el('span', {class: r.reason === 'dead_twice' ? 'why-dead' : 'why-manual'}, why),
            el('span', {class:'v'}, fmt(r.requests || 0)),
            el('span', {class:'v'}, `${r.req_ok || 0}/${r.req_auth_fail || 0}/${r.req_other_fail || 0}`),
            el('span', {class:'v'}, r.lifetime_s != null ? fmtDur(r.lifetime_s) : '--'),
            el('span', {}, r.retired_at ? ago(r.retired_at)+' ago' : '--')));
        });
      }
    }
  };

  const loadJwt = async () => {
    try {
      const [data, stats] = await Promise.all([
        json('/api/admin/jwt/list'),
        json('/api/admin/jwt/stats').catch(() => null),
      ]);
      setVal('#jwt-count', fmt(data.count));
      renderJwt(data.jwt || []);
      if (stats) renderJwtStats(stats);
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
        ['Tracked file', `<span class="mono">${esc(data.main_file_name||'')}</span>`],
      ];
      /* The hash pair is only sent when the tracked file IS the remote path;
         otherwise the two numbers were never comparable, so showing them reads
         as a mismatch that does not exist. */
      if (data.local_file_hash) rows.push(['Local file hash', `<span class="mono">${esc(data.local_file_hash)}</span>`]);
      if (data.remote_file_hash) rows.push(['Remote file hash', `<span class="mono">${esc(data.remote_file_hash)}</span>`]);
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
    let alive = true;
    const t0 = Date.now();
    const hist = getPingHistory();
    const avg = hist.length > 0 ? hist.reduce((a, b) => a + b, 0) / hist.length : 8;
    const estMs = Math.max(8000, (avg + 1) * 1600);
    if (progress) { progress.indeterminate = false; progress.value = 0.15; }
    if (stage) stage.textContent = 'Server restarting...';
    if (pingEl) pingEl.innerHTML = '<span class="live-dot"></span> Waiting for server...';
    const anim = () => {
      if (!alive || !progress) return;
      const k = Math.min(1, (Date.now() - t0) / estMs);
      progress.value = 0.15 + k * 0.8;
      if (k < 1) requestAnimationFrame(anim);
    };
    requestAnimationFrame(anim);
    while (true) {
      attempt++;
      await new Promise(res => setTimeout(res, 1600));
      try {
        const r = await fetch('/api/admin/self_update/check');
        if (r.ok) {
          const data = await r.json();
          savePingHistory(attempt);
          alive = false;
          if (progress) { progress.indeterminate=false; progress.value=1; }
          if (stage) stage.textContent = 'Updated.';
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

  /* ---- library (live rows + summaries stream over SSE; page state
      refreshes on navigation, job-done events, and the SSE heartbeat) ---- */
  let rebaseMode = 'cached';
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
      setVal('#stat-none', fmt(scan.buckets?.none) + (scan.unlyriced ? ` (+${fmt(scan.unlyriced)} unlyriced)` : ''));
      renderRebaseStatus(status);
      renderRetitleStatus(retitleStatus);
      // One small GET, no polling: it makes the bulk panel show a job that was
      // started elsewhere (or after this page was left open) instead of an idle
      // panel whose Start button can only 409.
      loadBulkStatus().catch(() => {});
      // The version/retranslate panels fetch their own (much bigger) scans, and
      // neither is needed to draw the library stats, so they are not in the
      // Promise.all above: a slow full-directory walk would otherwise hold up
      // the page every time it is opened.
      loadDbVer().catch(() => {});
      scanRTrans().catch(() => {});
      loadAI();
      try {
        const unlyriced = await json('/api/admin/library/unlyriced');
        renderUnlyriced(unlyriced.items || []);
      } catch (e) { renderUnlyriced([]); }
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
      const row = el('div', {class:'list-row', style:'grid-template-columns: auto 1fr auto auto auto;'},
        (() => { const c = document.createElement('mdui-checkbox'); c.value = item.video_id; c.className = 'retitle-check'; return c; })(),
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
  const retitleWorkers = () => {
    const v = parseInt($('#retitle-workers')?.value || '8', 10);
    return Math.max(1, Math.min(16, isNaN(v) ? 8 : v));
  };
  const retitleAll = async () => {
    await mdui.confirm({
      headline: 'Retitle all unlyriced',
      description: 'Send all unlyriced songs through LLM retitle?',
      cancelText: 'Cancel',
      confirmText: 'Retitle all',
      onConfirm: async () => {
        try {
          const r = await API('/api/admin/library/retitle', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({workers: retitleWorkers()})});
          const d = await r.json();
          if (d.ok) { mdui.snackbar({message:'Retitle started'}); openRetitleDialog(); }
          else mdui.snackbar({message: d.error || 'Failed'});
        } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
      }
    });
  };
  const retitleSelected = async () => {
    const checked = [...document.querySelectorAll('.retitle-check')].filter(c => c.checked).map(c => c.value);
    if (!checked.length) { mdui.snackbar({message:'Select at least one song'}); return; }
    try {
      const r = await API('/api/admin/library/retitle', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({video_ids: checked, workers: retitleWorkers()})});
      const d = await r.json();
      if (d.ok) { mdui.snackbar({message:`Retitle started (${checked.length})`}); openRetitleDialog(); }
      else mdui.snackbar({message: d.error || 'Failed'});
    } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
  };
  /* ---- AI providers (keys in gitignored config file, masked display) ---- */
  const renderAI = d => {
    const list = $('#ai-list');
    if (!list) return;
    list.innerHTML = '';
    const rows = [];
    (d.cohere || []).forEach(c => rows.push({label: `Cohere ${c.masked}`, tag: 'translate+retitle',
      del: () => API('/api/admin/ai/cohere', {method:'DELETE', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key: c.masked})})}));
    (d.chat || []).forEach(p => rows.push({label: `${p.name || '?'} ${p.masked} | ${p.model || ''}${p.from_env ? ' (env)' : ''}`, tag: (p.use_for || []).join('+'),
      del: p.from_env ? null : () => API('/api/admin/ai/chat', {method:'DELETE', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name: p.name})})}));
    if (!rows.length) { list.appendChild(el('div', {class:'list-row'}, 'No providers configured')); return; }
    rows.forEach(r => {
      const row = el('div', {class:'list-row', style:'grid-template-columns: 1fr auto auto;'},
        el('span', {class:'truncate mono'}, r.label),
        el('span', {class:'rename-tag'}, r.tag));
      if (r.del) {
        const b = el('mdui-button', {variant:'text', icon:'delete'});
        b.textContent = 'Remove';
        b.addEventListener('click', async () => {
          try { const res = await (await r.del()).json(); if (res.ok) renderAI(res); }
          catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        });
        row.appendChild(b);
      } else row.appendChild(el('span', {}));
      list.appendChild(row);
    });
  };
  const loadAI = async () => {
    try { renderAI(await json('/api/admin/ai/providers')); }
    catch (e) { const l = $('#ai-list'); if (l) l.innerHTML = ''; }
  };
  const aiInit = () => {
    const rf = $('#ai-refresh');
    if (rf) rf.addEventListener('click', loadAI);
    const addC = $('#ai-cohere-add');
    if (addC) addC.addEventListener('click', async () => {
      const v = ($('#ai-cohere-key') || {}).value || '';
      if (!v.trim()) { mdui.snackbar({message:'Paste a key first'}); return; }
      try {
        const r = await API('/api/admin/ai/cohere', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key: v.trim()})});
        const d = await r.json();
        if (d.ok) { renderAI(d); $('#ai-cohere-key').value = ''; mdui.snackbar({message:'Cohere key added'}); }
        else mdui.snackbar({message: d.error || 'Failed'});
      } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
    });
    const addH = $('#ai-chat-add');
    if (addH) addH.addEventListener('click', async () => {
      const val = id => ((($(id) || {}).value) || '').trim();
      const use = val('#ai-chat-use').split(',').map(s => s.trim()).filter(s => s === 'translate' || s === 'retitle');
      try {
        const r = await API('/api/admin/ai/chat', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({
          name: val('#ai-chat-name'), api_key: val('#ai-chat-key'),
          base_url: val('#ai-chat-url'), model: val('#ai-chat-model'),
          use_for: use.length ? use : ['translate', 'retitle']})});
        const d = await r.json();
        if (d.ok) { renderAI(d); $('#ai-chat-key').value = ''; mdui.snackbar({message:'Chat provider saved'}); }
        else mdui.snackbar({message: d.error || 'Failed'});
      } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
    });
  };
  /* ---- app settings (tweak remote config) ---- */
  /* ---- app settings ---- */
  // The panel is schema-driven: the server owns the list, the labels and the
  // descriptions (server/app_settings.py _SCHEMA), so a new remote key shows
  // up here without touching the dashboard. The raw key/value form survives
  // under "Advanced" for keys that are not in the schema.
  const MASTER_KEY = 'ui.remote_control';
  const appState = { schema: [], groups: [], extra: [], data: {},
                     groups_remote: [], groups_server: [] };

  const appPost = async (values) => {
    const r = await API('/api/admin/app/settings', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({values})});
    const d = await r.json();
    if (!d.ok) throw new Error(d.error || 'Failed');
    return d;
  };
  const appDelete = async (key) => {
    const r = await API('/api/admin/app/settings', {method:'DELETE', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key})});
    const d = await r.json();
    if (!d.ok) throw new Error(d.error || 'Failed');
    return d;
  };
  const applyApp = (d) => {
    appState.schema = d.schema || [];
    appState.groups = d.groups || [];
    appState.extra = d.extra || [];
    appState.groups_remote = d.groups_remote || [];
    appState.groups_server = d.groups_server || [];
    renderApp();
    renderServerSettings();
    seedBulkDefaults();
  };

  // A row is: label + description on the left, a typed control and a state
  // pill on the right. The pill says whether the value is the server default
  // or an operator override -- the flat map could never show that, which is
  // why "Reset" per row used to be invisible until you clicked it.
  const appRow = (e) => {
    const row = el('div', {class:'list-row app-row'});
    const text = el('div', {class:'app-text'},
      el('div', {class:'app-label'}, e.label || e.key),
      el('div', {class:'app-desc', title:e.desc || ''}, e.desc || e.key));
    row.appendChild(text);

    // bool -> a switch, int/float -> a number field. The type comes from the
    // schema, so a new key never renders as the wrong control: a boolean stored
    // as a number (or a number rendered as a switch) is a setting that reads
    // wrong on the one screen that is supposed to describe it.
    const isNum = e.type === 'int' || e.type === 'float';
    const sw = isNum ? null : el('mdui-switch', {'aria-label': e.label || e.key});
    const num = isNum ? el('mdui-text-field', {type:'number', variant:'outlined',
      'aria-label': e.label || e.key}) : null;
    if (sw) sw.checked = e.value !== false;
    if (num) {
      num.value = String(e.value != null ? e.value : '');
      // Only promise a step on a whole-number field: step=1 on a float key
      // would make the arrow keys jump 0.8 -> 1.8.
      if (e.type === 'int') num.step = '1';
      else num.step = '0.1';
      num.min = e.min != null ? String(e.min) : '';
      num.max = e.max != null ? String(e.max) : '';
      num.style.width = '110px';
      num.dataset.key = e.key;
    }
    row.appendChild(sw || num);

    const pill = el('span', {class: e.is_override ? 'pill pill-warn' : 'pill pill-mute'},
      e.is_override ? 'override' : 'default');
    row.appendChild(pill);
    return {row, sw, num, pill, entry: e};
  };

  // One pass, one host, one group filter -- the App page and the server
  // Settings page render the SAME rows from the SAME schema, only the group
  // list differs. Two renderers would drift, and they did: the wbw second pass
  // is a server switch and used to be rendered inside the page framed as
  // remote config for devices.
  const renderSettingGroups = (hostSel, groupIds, snackPrefix) => {
    const host = $(hostSel);
    if (!host) return;
    host.innerHTML = '';
    const seen = new Set();
    (groupIds || []).forEach(gid => {
      const gname = (appState.groups.find(g => g[0] === gid) || [gid, gid])[1];
      const entries = appState.schema.filter(e => e.group === gid);
      if (!entries.length) return;
      seen.add(gid);
      const wrap = el('div', {class:'app-group'});
      wrap.appendChild(el('div', {class:'app-group-title'}, gname));
      const grid = el('div', {class:'list-grid'});
      entries.forEach(e => {
        if (e.key === MASTER_KEY) return;   // the App page's master card
        const {row, sw, num, pill} = appRow(e);
        const save = async (value) => {
          const old = num ? num.value : sw.checked;
          if (num) num.disabled = true; else sw.disabled = true;
          try {
            const d = await appPost({[e.key]: value});
            applyApp(d);
            mdui.snackbar({message: `${e.label || e.key}: saved${snackPrefix || ''}`});
          } catch (err) {
            // never leave a control showing something the server refused
            if (num) num.value = old; else sw.checked = !sw.checked;
            mdui.snackbar({message: 'Failed: '+err.message});
          } finally { if (num) num.disabled = false; else sw.disabled = false; }
        };
        if (sw) sw.addEventListener('change', () => save(sw.checked));
        if (num) {
          // `change` (blur/enter), not `input`: a number field fires input per
          // keystroke and "1" then "16" would save 1 then 16.
          num.addEventListener('change', () => {
            const raw = String(num.value).trim();
            const v = e.type === 'int' ? parseInt(raw, 10) : parseFloat(raw);
            if (isNaN(v)) { num.value = String(e.value); return; }
            save(v);
          });
        }
        grid.appendChild(row);
      });
      if (grid.children.length) wrap.appendChild(grid);
      if (wrap.children.length) host.appendChild(wrap);
    });
    // A key whose group NEITHER page claims must still be reachable, or it becomes
    // invisible the moment a group is renamed. Deliberately not "not in my
    // groups": that would pull the other page's keys in as orphans, which is
    // how the wbw retry ended up under "Other" on the page for device switches.
    const claimed = new Set([...(appState.groups_remote || []), ...(appState.groups_server || [])]);
    const orphans = appState.schema.filter(e => !claimed.has(e.group));
    if (orphans.length) {
      const wrap = el('div', {class:'app-group'});
      wrap.appendChild(el('div', {class:'app-group-title'}, 'Other (group not on any page)'));
      const grid = el('div', {class:'list-grid'});
      orphans.forEach(e => {
        const {row} = appRow(e);
        grid.appendChild(row);
      });
      wrap.appendChild(grid);
      host.appendChild(wrap);
    }
  };

  const renderAppMaster = () => {
    const sw = $('#app-master'); if (!sw) return;
    const e = appState.schema.find(x => x.key === MASTER_KEY);
    if (!e) return;
    const lbl = $('#app-master-label'), desc = $('#app-master-desc');
    if (lbl) lbl.textContent = e.label;
    if (desc) desc.textContent = e.desc;
    sw.checked = e.value !== false;
    const card = sw.closest('.app-master');
    if (card) card.dataset.off = sw.checked ? 'no' : 'yes';
  };

  const renderApp = () => {
    const host = $('#app-groups');
    renderAppMaster();
    // Remote groups only: the server's own switches moved to the Settings page,
    // where a switch that never reaches a device cannot be mistaken for one
    // that does.
    if (host) renderSettingGroups('#app-groups', appState.groups_remote, ' on every device');

    // Advanced: unrecognised overrides, plus the raw form target.
    const list = $('#app-list');
    if (!list) return;
    list.innerHTML = '';
    const extras = appState.extra || [];
    if (!extras.length) {
      list.appendChild(el('div', {class:'list-row'}, 'No keys outside the schema'));
    } else {
      extras.forEach(x => {
        const row = el('div', {class:'list-row', style:'grid-template-columns: 1fr auto auto;'},
          el('span', {class:'truncate mono', title:x.key}, `${x.key} = ${JSON.stringify(x.value)}`));
        const edit = el('mdui-button', {variant:'text', icon:'edit'});
        edit.textContent = 'Edit';
        edit.addEventListener('click', () => {
          const cur = $('#app-key'); const cv = $('#app-value');
          if (cur) cur.value = x.key;
          if (cv) cv.value = (typeof x.value === 'string') ? x.value : JSON.stringify(x.value);
        });
        row.appendChild(edit);
        const del = el('mdui-button', {variant:'text', icon:'delete'});
        del.textContent = 'Delete';
        del.addEventListener('click', async () => {
          try { applyApp(await appDelete(x.key)); mdui.snackbar({message: 'Deleted'}); }
          catch (err) { mdui.snackbar({message: 'Failed: '+err.message}); }
        });
        row.appendChild(del);
        list.appendChild(row);
      });
    }
  };

  const loadApp = async () => {
    try { applyApp(await json('/api/admin/app/settings')); }
    catch (e) { const g = $('#app-groups'); if (g) g.innerHTML = ''; }
  };

  const renderServerSettings = () => {
    renderSettingGroups('#srv-groups', appState.groups_server, ' on this server');
    const note = $('#srv-raw-note');
    if (note) {
      const extras = appState.extra || [];
      note.textContent = extras.length
        ? `${extras.length} override(s) outside the schema: ${extras.map(x => x.key).join(', ')}`
        : 'No overrides outside the schema.';
    }
  };

  // The bulk panel's fields are DEFAULTS for a new job; whatever the panel last
  // held is what it sends. Seed them from the server so the panel opens showing
  // what the server would actually do, but never over a field the operator has
  // already typed into.
  const seedBulkDefaults = () => {
    const map = {workers: 'bulk.workers', cpu_workers: 'bulk.cpu_workers',
                 tq_workers: 'bulk.tq_workers', batch: 'bulk.batch'};
    Object.entries(map).forEach(([field, key]) => {
      const e = appState.schema.find(x => x.key === key);
      if (!e) return;
      const input = $(field === 'workers' ? '#bulk-workers'
                    : field === 'cpu_workers' ? '#bulk-cpu'
                    : field === 'tq_workers' ? '#bulk-tq' : '#bulk-batch');
      if (!input) return;
      const cur = parseInt(input.value, 10);
      if (isNaN(cur) || cur === e.default) input.value = String(e.value);
    });
  };

  const appInit = () => {
    const master = $('#app-master');
    if (master) master.addEventListener('change', async () => {
      master.disabled = true;
      try {
        applyApp(await appPost({[MASTER_KEY]: master.checked}));
        mdui.snackbar({message: master.checked
          ? 'Remote control ON: the server can disable features again'
          : 'Remote control OFF: the server can no longer disable anything'});
      } catch (e) {
        master.checked = !master.checked;
        mdui.snackbar({message: 'Failed: '+e.message});
      } finally { master.disabled = false; }
    });
    const set = $('#app-set');
    if (set) set.addEventListener('click', async () => {
      const k = ((($('#app-key') || {}).value) || '').trim();
      const raw = ((($('#app-value') || {}).value) || '').trim();
      if (!k) { mdui.snackbar({message:'Key required'}); return; }
      let v = raw;
      if (raw === 'true' || raw === 'True') v = true;
      else if (raw === 'false' || raw === 'False') v = false;
      else if (raw !== '' && !isNaN(Number(raw))) v = Number(raw);
      try {
        const r = await API('/api/admin/app/settings', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key: k, value: v})});
        const d = await r.json();
        if (d.ok) { applyApp(d); mdui.snackbar({message:'Saved'}); }
        else mdui.snackbar({message: d.error || 'Failed'});
      } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
    });
    const rs = $('#app-reset');
    // There is no undo server-side, and this used to be a single unconfirmed
    // click that wiped every override.
    if (rs) rs.addEventListener('click', async () => {
      await mdui.confirm({headline:'Reset all settings',
        description:'Drops every override on every device. This cannot be undone.',
        cancelText:'Cancel', confirmText:'Reset', onConfirm: async () => {
          try {
            const r = await API('/api/admin/app/settings/reset', {method:'POST'});
            const d = await r.json();
            if (d.ok) { applyApp(d); mdui.snackbar({message:'Defaults restored'}); }
          } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        }});
    });
    // The Settings page gets its own confirm with its own wording: "every device"
    // is the wrong thing to say about a switch that never leaves this server.
    const srs = $('#srv-reset');
    if (srs) srs.addEventListener('click', async () => {
      await mdui.confirm({headline:'Reset server settings',
        description:'Drops every override, including the remote ones the devices use. This cannot be undone.',
        cancelText:'Cancel', confirmText:'Reset', onConfirm: async () => {
          try {
            const r = await API('/api/admin/app/settings/reset', {method:'POST'});
            const d = await r.json();
            if (d.ok) { applyApp(d); mdui.snackbar({message:'Defaults restored'}); }
          } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        }});
    });
    const srefresh = $('#srv-refresh');
    if (srefresh) srefresh.addEventListener('click', loadApp);
  };
  /* ---- targeted kill switch (build sha -> action) ---- */
  // The switches above are "every device, every build". This panel is "these
  // builds only", which is the shape that is actually useful once more than one
  // build is in the wild: kill the glass on build-42 and leave everyone else
  // alone. The server resolves the selector against the sha the device reports
  // (server/kill_switch.py), so nothing here is evaluated on the device.
  const killState = {targets: [], builds: [], tags: [], census: [], surfaces: [], scopes: []};

  const killApply = (d) => {
    killState.targets = d.targets || [];
    killState.builds = d.builds || [];
    killState.tags = d.tags || [];
    killState.census = d.census || [];
    killState.surfaces = d.surfaces || [];
    killState.scopes = d.scopes || [];
    renderKill();
    killFillOptions();
  };

  // Device counts next to every build. `n` is the live count (seen inside the
  // 30-day window); `ever` is the unpruned history, because "0 live, 900 ever"
  // is the shape of a build everybody already left and killing it is a no-op.
  const devCount = (n, ever) => {
    if (!n && !ever) return '<span class="pill pill-mute">0 devices</span>';
    const cls = n ? 'pill pill-warn' : 'pill pill-mute';
    const label = n
      ? `${n} device${n === 1 ? '' : 's'}`
      : `0 live / ${ever} ever`;
    return `<span class="${cls}">${esc(label)}</span>`;
  };

  const agoText = (ts) => {
    if (!ts) return 'never';
    const s = Math.max(0, Date.now() / 1000 - ts);
    if (s < 3600) return `${Math.round(s / 60)}m ago`;
    if (s < 86400) return `${Math.round(s / 3600)}h ago`;
    return `${Math.round(s / 86400)}d ago`;
  };

  const shaOpts = (selected) => {
    let h = `<option value="">every build (no selector)</option>`;
    killState.tags.forEach(t => {
      // A tagged build already appears in the sha list carrying its tag name,
      // so the tag list is only for commits that fell out of the 400-commit
      // window -- otherwise the same release is offered twice.
      if (t.known) return;
      h += `<option value="tag:${esc(t.tag)}"${selected === `tag:${t.tag}` ? ' selected' : ''}>tag ${esc(t.tag)} - ${esc(t.sha)} (older than the window) - ${t.devices} devices</option>`;
    });
    killState.builds.forEach(b => {
      const tag = b.tags && b.tags.length ? ` ${b.tags.join(', ')}` : '';
      h += `<option value="sha:${b.sha}"${selected === `sha:${b.sha}` ? ' selected' : ''}>${esc(b.sha)}${esc(tag)} - ${esc(b.subject)} - ${b.devices} devices</option>`;
    });
    return h;
  };

  const renderKill = () => {
    const host = $('#kill-list');
    if (host) {
      host.innerHTML = '';
      if (!killState.targets.length) {
        host.appendChild(el('div', {class:'list-row'}, 'No active kill targets'));
      }
      killState.targets.forEach(t => {
        const sel = t.sha ? `build ${t.sha}`
          : t.tag ? `tag ${t.tag}`
          : (t.from_sha || t.to_sha) ? `${t.from_sha || 'oldest'} .. ${t.to_sha || 'newest'}`
          : 'EVERY build';
        const scopeText = t.scope === 'surface' ? `one surface: ${t.key}`
          : t.scope === 'tweak' ? 'whole glass stack' : 'all V2 surfaces';
        const row = el('div', {class:'list-row', style:'grid-template-columns: 1fr auto auto auto;'});
        row.appendChild(el('div', {class:'app-text'},
          el('div', {class:'app-label mono'}, sel),
          el('div', {class:'app-desc'}, `${scopeText} -> ${(t.keys || []).join(', ')}${t.note ? ' - ' + t.note : ''}`)));
        row.appendChild(el('span', {class: t.status === 'blanket' ? 'pill pill-warn' : 'pill pill-ok'}, t.status));
        row.appendChild(el('span', {class:'pill pill-mute'}, `${t.devices || 0} devices`));
        const del = el('mdui-button', {variant:'text', icon:'delete'});
        del.textContent = 'Remove';
        del.addEventListener('click', async () => {
          try {
            const r = await API('/api/admin/kill/targets', {method:'DELETE', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id: t.id})});
            const d = await r.json();
            if (d.ok) { killApply(d); mdui.snackbar({message: 'Target removed'}); }
            else mdui.snackbar({message: d.error || 'Failed'});
          } catch (e) { mdui.snackbar({message: 'Failed: '+e.message}); }
        });
        row.appendChild(del);
        host.appendChild(row);
      });
    }

    // Build census: the "how many devices are on a version" answer, one row per
    // build the server has heard from.
    const cen = $('#kill-census');
    if (cen) {
      cen.innerHTML = '';
      if (!killState.census.length) {
        cen.appendChild(el('div', {class:'list-row'}, 'No device has reported a build yet'));
      }
      killState.census.slice(0, 25).forEach(r => {
        const full = killState.builds.find(b => b.sha === r.sha);
        const subject = full ? full.subject : '(outside the history window)';
        const row = el('div', {class:'list-row', style:'grid-template-columns: 1fr auto auto;'});
        row.appendChild(el('div', {class:'app-text'},
          el('div', {class:'app-label mono'}, `${r.sha}${r.version ? '  v' + r.version : ''}`),
          el('div', {class:'app-desc'}, `${subject} - last seen ${agoText(r.last_seen)}`)));
        row.appendChild(devCount(r.devices, r.devices_total));
        row.appendChild(el('span', {class:'pill pill-mute'}, `first ${agoText(r.first_seen)}`));
        cen.appendChild(row);
      });
    }
  };

  const loadKill = async () => {
    try {
      const r = await API('/api/admin/kill/targets');
      const d = await r.json();
      if (d.ok) killApply(d);
    } catch (e) { /* the App tab still works without this panel */ }
  };

  const killScopeChanged = () => {
    const scope = ($('#kill-scope') || {}).value || 'lg';
    const surf = $('#kill-surface-row');
    if (surf) surf.style.display = scope === 'surface' ? '' : 'none';
  };

  const killPreview = async () => {
    const sel = (($('#kill-build') || {}).value) || '';
    const host = $('#kill-preview');
    if (!host) return;
    host.innerHTML = '';
    if (!sel) { host.appendChild(el('span', {class:'pill pill-mute'}, 'pick a build to preview')); return; }
    const sha = sel.startsWith('sha:') ? sel.slice(4) : '';
    if (!sha) { host.innerHTML = '<span class="pill pill-mute">a tag selector cannot be previewed per-device; it resolves on the server</span>'; return; }
    try {
      const r = await API('/api/admin/kill/preview?sha=' + encodeURIComponent(sha));
      const d = await r.json();
      host.innerHTML = '';
      if (!d.ok) { host.appendChild(el('span', {class:'pill pill-mute'}, 'Preview failed')); return; }
      const hits = d.hits || [];
      host.appendChild(el('span', {class: hits.length ? 'pill pill-warn' : 'pill pill-ok'},
        hits.length ? `${hits.length} active target(s) fire here` : 'no target fires here'));
      (d.keys_off || []).forEach(k => host.appendChild(el('span', {class:'pill pill-bad mono'}, k)));
      if (!(d.keys_off || []).length && !hits.length) {
        host.appendChild(el('span', {class:'app-desc'}, 'This build receives the plain remote config.'));
      }
    } catch (e) {
      host.innerHTML = '';
      host.appendChild(el('span', {class:'pill pill-mute'}, 'Preview failed: '+e.message));
    }
  };

  const killAdd = async () => {
    const sel = (($('#kill-build') || {}).value) || '';
    const scope = (($('#kill-scope') || {}).value) || 'lg';
    const key = ((($('#kill-surface') || {}).value) || '').trim();
    const note = ((($('#kill-note') || {}).value) || '').trim();
    if (scope === 'surface' && !key) { mdui.snackbar({message: 'Pick a surface'}); return; }
    const body = {scope, note};
    if (sel.startsWith('sha:')) body.sha = sel.slice(4);
    else if (sel.startsWith('tag:')) body.tag = sel.slice(4);
    if (scope === 'surface') body.key = key;
    try {
      const r = await API('/api/admin/kill/targets', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
      const d = await r.json();
      if (!d.ok) { mdui.snackbar({message: d.error || 'Failed'}); return; }
      killApply(d);
      mdui.snackbar({message: 'Target armed'});
    } catch (e) { mdui.snackbar({message: 'Failed: '+e.message}); }
  };

  const killInit = () => {
    const scope = $('#kill-scope');
    if (scope) scope.addEventListener('change', killScopeChanged);
    const pv = $('#kill-preview-btn');
    if (pv) pv.addEventListener('click', killPreview);
    const add = $('#kill-add');
    if (add) add.addEventListener('click', killAdd);
    const rf = $('#kill-refresh');
    if (rf) rf.addEventListener('click', loadKill);
    const bs = $('#kill-build');
    if (bs) bs.addEventListener('change', killPreview);
    killScopeChanged();
  };

  // Both pickers are options lists served by the server: the build list comes
  // from git (plus the census, for the device counts) and the surface list from
  // the app_settings schema, so neither can name something the device does not
  // actually read. Populated on load, not from a hardcoded copy here.
  const killFillOptions = () => {
    const bs = $('#kill-build');
    if (bs) bs.innerHTML = shaOpts((bs.value || '').trim());
    const sf = $('#kill-surface');
    if (sf) {
      sf.innerHTML = '';
      killState.surfaces.forEach(([k, label]) => {
        sf.appendChild(el('mdui-select-item', {value: k}, label || k));
      });
    }
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
  let probeVideoId = null;
  let probeTitle = null;
  let probeArtist = null;
  // Live animated provider rows (web elements, not text): each provider gets
  // a row with a continuous spinner while probing, a smooth elapsed ticker
  // (local 250ms clock, zero HTTP), and a determinate pill + retry button
  // when it lands. Movement never jumps in steps.
  // TODO(web-anim): skeleton shimmer behind rows while the first provider
  // is still probing; stagger terminal pills by finish order.
  const probeRowMap = new Map();
  let probeElapsedTimer = null;
  const probeTickElapsed = () => {
    const now = Date.now();
    probeRowMap.forEach(r => {
      if (r.running && r.elapsed) r.elapsed.textContent = ((now - r.t0) / 1000).toFixed(1) + 's';
    });
  };
  const probeStartElapsed = () => {
    if (probeElapsedTimer) return;
    probeElapsedTimer = setInterval(probeTickElapsed, 250);
  };
  const probeStopElapsed = () => {
    if (probeElapsedTimer) { clearInterval(probeElapsedTimer); probeElapsedTimer = null; }
  };
  const probeRetryProvider = (provider) => {
    if (!probeVideoId) { mdui.snackbar({message:'No video for this run'}); return; }
    probeRefetch({url: probeVideoId, source: provider,
      title: probeTitle || undefined, artist: probeArtist || undefined});
  };
  const probeLiveLine = (provider, status, detail) => {
    const live = $('#refetch-live');
    if (!live) return;
    live.classList.add('has-lines');
    while (live.children.length > 200) {
      const old = live.firstChild;
      live.removeChild(old);
      // Keep the row map in sync so later updates for an evicted provider
      // rebuild its row instead of touching a detached node.
      probeRowMap.forEach((v, k) => { if (v.row === old) probeRowMap.delete(k); });
    }
    let r = probeRowMap.get(provider);
    if (!r) {
      const spin = el('mdui-circular-progress', {style:'width:16px;height:16px;flex:none;'});
      const slot = el('span', {style:'display:inline-flex;width:52px;flex:none;'});
      const pill = el('span', {class:'pl-run'}, '[...]');
      slot.appendChild(spin);
      const name = el('span', {style:'font-weight:600;'}, provider);
      const det = el('span', {class:'pl-miss', style:'opacity:.75;'}, '');
      const elapsed = el('span', {class:'mono', style:'font-size:11px;opacity:.6;'}, '0.0s');
      const retry = el('mdui-button-icon', {icon:'refresh', variant:'text', style:'flex:none;', title:'Re-probe this provider'});
      retry.style.display = 'none';
      retry.addEventListener('click', () => probeRetryProvider(provider));
      const row = el('div', {class:'probe-live-row'}, slot, name, det,
        el('span', {style:'flex:1;'}),
        elapsed, retry);
      live.appendChild(row);
      r = {row, spin, pill, det, elapsed, retry, t0: Date.now(), running: true, slot};
      probeRowMap.set(provider, r);
      live.scrollTop = live.scrollHeight;
    }
    const terminal = status === 'found' || status === 'missed' || status === 'error' || status === 'skipped';
    if (terminal) {
      r.running = false;
      r.elapsed.textContent = ((Date.now() - r.t0) / 1000).toFixed(1) + 's';
      const tag = status === 'found' ? 'OK' : status === 'missed' ? '--'
        : status === 'error' ? 'FAIL' : 'SKIP';
      const cls = status === 'found' ? 'pl-ok' : status === 'missed' ? 'pl-miss'
        : status === 'error' ? 'pl-fail' : 'pl-miss';
      r.pill.textContent = `[${tag}]`;
      r.pill.className = cls;
      r.slot.innerHTML = '';
      r.slot.appendChild(r.pill);
      r.det.textContent = detail ? ' ' + detail : '';
      r.retry.style.display = '';
    } else {
      // started / song / probing: keep the spinner running, refresh detail.
      r.running = true;
      if (detail) r.det.textContent = ' ' + detail;
      r.retry.style.display = 'none';
    }
    live.scrollTop = live.scrollHeight;
  };
  const probeClearRows = () => {
    probeRowMap.clear();
    probeStopElapsed();
  };
  const tierPill = t => {
    const cls = t === 'wbw' ? 'pill-ok' : t === 'line' ? 'pill-warn' : 'pill-mute';
    return el('span', {class:`pill ${cls}`}, t);
  };
  /* ---- background probe + provider pager ----
     probe/start returns immediately; probe_progress SSE streams race lines
     (including the song line) into #refetch-live, and the final done/error
     event fetches the full candidates once -- no status polling. A
     single-shot safety fetch covers a missed SSE disconnect. Full
     candidates are kept server-side (RAM store, per-video); left/right pages
     without re-probing. */
  let probeStatusUrl = null;
  let probeFoundCount = 0;
  let probeSafetyTimer = null;
  let probePager = null;
  const clearProbeSafety = () => {
    if (probeSafetyTimer) { clearTimeout(probeSafetyTimer); probeSafetyTimer = null; }
  };
  const stopProbePoll = () => { clearProbeSafety(); probeStopElapsed(); probeRunId = null; };
  const setProbeStatus = (text, cls) => {
    const status = $('#refetch-status');
    if (!status) return;
    status.textContent = text;
    status.className = 'pill ' + (cls || 'pill-mute');
  };
  const applyProbeCandidate = async (saveBtn, d, c) => {
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
  };
  const renderProbePager = () => {
    const meta = $('#refetch-meta');
    const list = $('#refetch-candidates');
    if (!list || !probePager) return;
    list.innerHTML = '';
    const d = probePager.d;
    const cands = (d && d.candidates) || [];
    if (!cands.length) {
      if (meta) meta.textContent = (d && d.error) ? `Probe error: ${d.error}` : 'No lyrics found from any provider for this video.';
      return;
    }
    if (probePager.idx < 0) probePager.idx = 0;
    if (probePager.idx >= cands.length) probePager.idx = cands.length - 1;
    const i = probePager.idx;
    const c = cands[i];
    const renamed = d.renamed ? ' (saved rename applied)' : '';
    const notes = (d.notes && d.notes.length) ? ' | ' + d.notes.join('; ') : '';
    if (meta) meta.textContent = `${d.song || '?'} - ${d.artist || '?'} | ${d.duration || 0}s | ${cands.length} candidate(s)${renamed}${notes}`;
    const prevBtn = el('mdui-button-icon', {icon:'chevron_left'});
    prevBtn.addEventListener('click', () => { if (probePager.idx > 0) { probePager.idx--; renderProbePager(); } });
    if (i <= 0) prevBtn.setAttribute('disabled', '');
    const nextBtn = el('mdui-button-icon', {icon:'chevron_right'});
    nextBtn.addEventListener('click', () => { if (probePager.idx < cands.length - 1) { probePager.idx++; renderProbePager(); } });
    if (i >= cands.length - 1) nextBtn.setAttribute('disabled', '');
    const countLabel = el('span', {style:'min-width:52px; text-align:center; font-weight:600;'}, `${i + 1}/${cands.length}`);
    const previewBtn = el('mdui-button', {variant:'tonal', icon:'visibility'}, 'Preview');
    previewBtn.addEventListener('click', () => openPreview(d.video_id, d.lang, c.data));
    const saveBtn = el('mdui-button', {variant:'filled', icon:'save'}, 'Save');
    saveBtn.addEventListener('click', () => applyProbeCandidate(saveBtn, d, c));
    const rowCls = i === 0 ? 'rb-upgraded' : 'rb-same';
    list.appendChild(el('div', {class:'rebase-row probe-nav'},
      prevBtn, countLabel, nextBtn,
      el('span', {class:'probe-name'}, `${i === 0 ? 'best: ' : ''}${c.provider || '?'}`),
      el('span', {class:'probe-source'}, `${c.source || ''} | ${c.lines} lines | score ${c.score}`),
      tierPill(c.tier)));
    list.appendChild(el('div', {class:`rebase-row ${rowCls} probe-row`},
      el('span', {class:'probe-actions'}, previewBtn, saveBtn)));
  };
  const probeRefetch = async (opts={}) => {
    const probeBtn = $('#refetch-probe');
    const url = (opts.url || ($('#refetch-url') && $('#refetch-url').value) || '').trim();
    if (!url) { mdui.snackbar({message:'Enter a YouTube URL or video ID'}); return; }
    stopProbePoll();
    probePager = null;
    let started;
    try {
      const r = await API('/api/admin/library/probe/start', {method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          url,
          lang: ($('#refetch-lang') && $('#refetch-lang').value || 'zh-TW').trim(),
          title: opts.title || undefined,
          artist: opts.artist || undefined,
          source: opts.source || undefined,
        })});
      started = await r.json();
      if (!started.ok) throw new Error(started.error || 'probe start failed');
    } catch (e) {
      setProbeStatus('error', 'pill-mute');
      mdui.snackbar({message:'Probe failed: '+e.message});
      const list = $('#refetch-candidates');
      if (list) list.innerHTML = '';
      return;
    }
    // job_id doubles as the SSE run_id, so race lines stream live.
    probeRunId = started.job_id;
    probeStatusUrl = started.status_url;
    probeVideoId = started.video_id || url;
    probeTitle = opts.title || null;
    probeArtist = opts.artist || null;
    probeFoundCount = 0;
    const live = $('#refetch-live');
    if (live) { live.innerHTML = ''; live.classList.remove('has-lines'); }
    probeClearRows();
    probeStartElapsed();
    const list = $('#refetch-candidates');
    if (list) list.innerHTML = '';
    const meta = $('#refetch-meta');
    if (meta) meta.textContent = `${started.song || '?'} - ${started.artist || ''} | probing...`;
    if (probeBtn) probeBtn.loading = true;
    setProbeStatus('probing... 0', 'pill-warn');
    // Safety net only: if the final SSE event is missed (disconnect), one
    // status fetch 150s later still closes the run. Not a poll.
    clearProbeSafety();
    const runId = probeRunId;
    probeSafetyTimer = setTimeout(async () => {
      if (probeRunId !== runId) return;
      try {
        const s = await json(probeStatusUrl);
        if (probeRunId !== runId) return;
        if (s.state === 'done' || s.state === 'error') finishProbeRun(s.state === 'error');
      } catch {}
    }, 150000);
  };
  const finishProbeRun = async (failed) => {
    const runId = probeRunId;
    const statusUrl = probeStatusUrl;
    if (!runId) return; // stray event, no active run
    clearProbeSafety();
    probeStopElapsed();
    probeRunId = null;
    probeStatusUrl = null;
    const probeBtn = $('#refetch-probe');
    if (probeBtn) probeBtn.loading = false;
    if (!statusUrl) { setProbeStatus('error', 'pill-mute'); return; }
    if (failed) {
      setProbeStatus('error', 'pill-mute');
      const meta = $('#refetch-meta');
      if (meta) meta.textContent = 'Probe error (see race lines above)';
      return;
    }
    try {
      const f = await json(statusUrl + '?full=1');
      if (probeRunId && probeRunId !== runId) return; // superseded mid-flight
      if (!f.ok) throw new Error(f.error || 'fetch failed');
      probePager = {d: f, idx: 0};
      renderProbePager();
      setProbeStatus(`${(f.candidates || []).length} providers`, 'pill-ok');
    } catch (e) {
      setProbeStatus('error', 'pill-mute');
      mdui.snackbar({message:'Probe failed: '+e.message});
    }
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

  /* ---- playlist refetch (web; track rows stream over SSE, no polling) ---- */
  let plJobId = null;
  let plState = null;
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
    try { sessionStorage.removeItem('ymtu-playlist-job'); } catch {}
    plJobId = null;
    plState = null;
    renderPlSync({state:'stopped'});
  };
  const startPlaylistSyncWeb = async () => {
    const url = ($('#plsync-url') && $('#plsync-url').value || '').trim();
    if (!url) { mdui.snackbar({message:'Enter a playlist URL or ID'}); return; }
    const startBtn = $('#plsync-start');
    if (startBtn) startBtn.loading = true;
    try {
      const r = await API('/api/playlist/sync', {method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({playlist_id: url, lang: ($('#plsync-lang') && $('#plsync-lang').value || 'zh-TW').trim()})});
      const d = await r.json();
      plJobId = d.job_id;
      // Rows arrive as playlist_sync_progress SSE events; nothing to poll.
      plState = {state:'queued', total: 0, done: 0, found: 0, unlyriced: 0, error_count: 0, current: '', tracks: []};
      try { sessionStorage.setItem('ymtu-playlist-job', plJobId); } catch {}
      renderPlSync(plState);
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
  let bulkJobId = null;
  let bulkState = null;
  const fmtDur = s => {
    if (s == null || !isFinite(s)) return '--';
    s = Math.round(s);
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s/60)}m ${s%60}s`;
    return `${Math.floor(s/3600)}h ${Math.floor((s%3600)/60)}m`;
  };
  const bulkLive = () => {
    // state is 'running' or 'translating' (waiting on the translate queue).
    // Both mean a job owns the slot.
    const s = bulkState && bulkState.state;
    return s === 'running' || s === 'translating';
  };
  const setBulkField = (id, v) => {
    const e = $(id);
    // Stringified, not assigned raw: these are mdui-text-field value properties
    // and the server sends numbers, so a strict component would either coerce
    // oddly or show nothing at all.
    if (e && v != null && e.value !== undefined && String(e.value) !== String(v)) {
      e.value = String(v);
    }
  };
  const renderBulk = st => {
    const progress = $('#bulk-progress');
    const summary = $('#bulk-summary');
    const status = $('#bulk-status');
    const list = $('#bulk-results');
    const stageLine = $('#bulk-stage');
    const live = $('#bulk-live');
    const running = st && (st.state === 'running' || st.state === 'translating');
    if (status) {
      status.textContent = (st && st.state) || 'idle';
      status.className = 'pill ' + (st && st.state === 'translating' ? 'pill-warn'
        : running ? 'pill-ok' : 'pill-mute');
    }
    const stopBtn = $('#bulk-stop');
    if (stopBtn) stopBtn.style.display = running ? '' : 'none';
    // Start is disabled while a job owns the slot and Take over takes its
    // place. This is the whole fix for "a bulk refetch is already running" with
    // nothing on screen: the panel now shows the job that owns the slot.
    const startBtn = $('#bulk-start');
    if (startBtn) startBtn.disabled = !!running;
    const takeBtn = $('#bulk-takeover');
    if (takeBtn) takeBtn.style.display = running ? '' : 'none';
    if (progress) progress.value = (st && st.total > 0) ? Math.min(1, st.done / st.total) : 0;
    if (summary) {
      const bits = [];
      if (st && st.total > 0) {
        bits.push(`${st.done}/${st.total}`);
        bits.push(`up=${st.upgraded || 0}`);
        bits.push(`kept=${st.kept || 0}`);
        bits.push(`failed=${st.failed || 0}`);
        if (st.errors) bits.push(`err=${st.errors}`);
        if (st.skipped) bits.push(`skipped=${st.skipped}`);
        // Translate is part of the job, not a background detail: pending > 0 is
        // why a finished fetch is still running.
        bits.push(`tr ${st.tq_done || 0}/${st.tq_queued || 0}`);
        if (st.tq_pending) bits.push(`tr-pending=${st.tq_pending}`);
      }
      if (running && st && st.batch_total) {
        bits.push(`batch ${st.batch_index || 0}/${st.batch_total}`);
        bits.push(`in-flight=${st.in_flight || 0}`);
      }
      if (running && st && st.elapsed_s != null) {
        bits.push(`${fmtDur(st.elapsed_s)} elapsed`);
        if (st.eta_s != null) bits.push(`~${fmtDur(st.eta_s)} left`);
      }
      if (st && st.current && (st.current.song || st.current.video_id)) {
        bits.push(st.current.song || st.current.video_id);
      }
      summary.textContent = bits.join('  ');
    }
    if (live) {
      if (running && st) {
        const stale = st.stale ? ` | last beat ${fmtDur(st.beat_age_s)} ago (looks stuck)` : '';
        live.textContent = `Running ${st.scope || ''}/${st.mode || ''} ${st.lang || ''}`
          + ` -- fetch ${st.workers || '?'} thr, cpu ${st.cpu_workers || '?'}, tr ${st.tq_workers || '?'} thr`
          + `, batch ${st.batch || '?'} | live: these numbers can be changed now${stale}`;
      } else {
        live.textContent = 'Fetch threads, CPU workers, translate workers and batch size stay editable while a job runs.';
      }
    }
    if (stageLine) stageLine.textContent = (running && st && st.stage) ? st.stage : '';
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
  const bulkNum = (id, dflt, lo, hi) => {
    const v = parseInt((($('#' + id) && $('#' + id).value) || dflt), 10);
    return Math.max(lo, Math.min(hi, isNaN(v) ? dflt : v));
  };
  // Push a knob change to the RUNNING job. Debounced because a number field
  // fires per keystroke and each one would be a request; the server treats an
  // unchanged value as a silent no-op, so a duplicate is harmless anyway.
  let bulkTuneTimer = null;
  const tuneBulkLive = () => {
    if (!bulkLive()) return;
    clearTimeout(bulkTuneTimer);
    bulkTuneTimer = setTimeout(async () => {
      if (!bulkLive()) return;
      try {
        const r = await API('/api/admin/library/refetch/tune', {method:'POST',
          headers:{'Content-Type':'application/json'},
          body: JSON.stringify({
            workers: bulkNum('bulk-workers', 8, 1, 32),
            cpu_workers: bulkNum('bulk-cpu', 2, 1, 64),
            tq_workers: bulkNum('bulk-tq', 2, 1, 16),
            batch: bulkNum('bulk-batch', 25, 1, 500),
            translate: !!(($('#bulk-translate') && $('#bulk-translate').checked)),
          })});
        const d = await r.json();
        if (d && d.ok && bulkState) {
          // Adopt what the server actually clamped, so the field never shows a
          // number the job is not using.
          setBulkField('#bulk-workers', d.workers);
          setBulkField('#bulk-cpu', d.cpu_workers);
          setBulkField('#bulk-tq', d.tq_workers);
          setBulkField('#bulk-batch', d.batch);
          if (d.translate != null && $('#bulk-translate')) $('#bulk-translate').checked = !!d.translate;
        }
      } catch (e) { console.warn('bulk tune failed', e); }
    }, 400);
  };
  const applyBulkStatus = st => {
    if (!st || !st.job_id) return false;
    bulkJobId = st.job_id;
    bulkState = {...bulkState, ...st};
    setBulkField('#bulk-workers', st.workers);
    setBulkField('#bulk-cpu', st.cpu_workers);
    setBulkField('#bulk-tq', st.tq_workers);
    setBulkField('#bulk-batch', st.batch);
    if ($('#bulk-translate') && st.translate != null) $('#bulk-translate').checked = !!st.translate;
    try { sessionStorage.setItem('ymtu-bulk-job', st.job_id); } catch {}
    renderBulk(bulkState);
    return true;
  };
  // The ADOPT path: ask the server what is running, with no job id. Called on
  // page load and after any 409, so a job started in another tab (or by the
  // stale-refetch button) is never invisible.
  const loadBulkStatus = async () => {
    try {
      const st = await json('/api/admin/library/refetch/status');
      if (st && st.job_id && (st.state === 'running' || st.state === 'translating')) {
        applyBulkStatus(st);
        return true;
      }
    } catch (e) { console.warn('bulk status failed', e); }
    return false;
  };
  const stopBulk = async () => {
    try { await API('/api/admin/library/refetch/stop', {method:'POST'}); } catch {}
    try { sessionStorage.removeItem('ymtu-bulk-job'); } catch {}
    bulkJobId = null;
    bulkState = null;
    renderBulk({state:'stopped'});
  };
  const translateMissing = async () => {
    try {
      const lang = (($('#bulk-lang') && $('#bulk-lang').value) || '').trim();
      const r = await API('/api/admin/library/translate/retry', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({lang})});
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || 'failed');
      mdui.snackbar({message:`Translate queue: ${d.enqueued} enqueued (${d.checked} checked, ${d.pending ?? 0} pending)`});
      const stage = $('#bulk-stage');
      if (stage) stage.textContent = `Translate queue: ${d.enqueued} enqueued, ${d.pending ?? 0} pending -- workers retry through 429s until done.`;
    } catch (e) { mdui.snackbar({message:'Translate retry failed: '+e.message}); }
  };
  const startBulk = async () => {
    const startBtn = $('#bulk-start');
    if (startBtn) startBtn.loading = true;
    const num = (id, dflt, lo, hi) => {
      const v = parseInt(($('#' + id) && $('#' + id).value) || dflt, 10);
      return Math.max(lo, Math.min(hi, isNaN(v) ? dflt : v));
    };
    try {
      // Raw fetch, not API(): a 409 body carries the RUNNING job and that is
      // exactly what this handler needs, and API() throws the body away.
      const resp = await fetch('/api/admin/library/refetch/start', {method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          scope: segVal('bulk-scope', 'non-wbw'),
          mode: segVal('bulk-mode', 'fresh'),
          lang: (($('#bulk-lang') && $('#bulk-lang').value) || 'zh-TW').trim(),
          workers: num('bulk-workers', 8, 1, 32),
          cpu_workers: num('bulk-cpu', 2, 1, 64),
          tq_workers: num('bulk-tq', 2, 1, 16),
          batch: num('bulk-batch', 25, 1, 500),
          translate: !!(($('#bulk-translate') && $('#bulk-translate').checked)),
          force: !!bulkForceNext,
        })});
      const d = await resp.json().catch(() => ({}));
      bulkForceNext = false;
      if (d.running && d.running.job_id) {
        // The 409 path: adopt what is actually running instead of pretending
        // the panel is idle.
        applyBulkStatus(d.running);
        mdui.snackbar({message:`Already running: ${d.running.done}/${d.running.total}`
          + ` (${d.running.scope}/${d.running.mode}) -- showing it. Take over to replace it.`});
        return;
      }
      if (!d.ok) throw new Error(d.error || `start failed (HTTP ${resp.status})`);
      bulkJobId = d.job_id;
      // Rows + stage lines arrive as bulk_progress SSE events; nothing to poll.
      bulkState = {state:'running', total: d.total || 0, done: 0, upgraded: 0, kept: 0,
                   failed: 0, errors: 0, skipped: 0, tq_done: 0, tq_queued: 0,
                   tq_pending: 0, workers: d.workers, cpu_workers: d.cpu_workers,
                   tq_workers: d.tq_workers, batch: d.batch,
                   batch_index: 0, batch_total: d.batches || 0, in_flight: 0,
                   elapsed_s: 0, scope: segVal('bulk-scope', 'non-wbw'),
                   mode: segVal('bulk-mode', 'fresh'),
                   lang: (($('#bulk-lang') && $('#bulk-lang').value) || 'zh-TW').trim(),
                   translate: !!(($('#bulk-translate') && $('#bulk-translate').checked)),
                   current: null, stage: '', results: []};
      try { sessionStorage.setItem('ymtu-bulk-job', bulkJobId); } catch {}
      renderBulk(bulkState);
    } catch (e) {
      // A 409 used to be a dead end: the panel stayed on 'idle' and every click
      // produced the same error. Now the response carries the running job, so
      // adopt it and let the operator watch or take it over.
      const run = e && e.running;
      if (run && run.job_id) {
        applyBulkStatus(run);
        mdui.snackbar({message:`A bulk refetch is already running: ${run.done}/${run.total}`
          + ` (${run.scope}/${run.mode}) -- showing it. Take over to replace it.`});
      } else {
        mdui.snackbar({message:'Bulk refetch failed: '+e.message});
      }
    }
    if (startBtn) startBtn.loading = false;
  };
  // Take over: same request with force, after a confirm naming what is being
  // replaced -- force cancels the running job, which is not something to do by
  // accident from a mis-click.
  let bulkForceNext = false;
  const takeOverBulk = async () => {
    const run = (bulkState && bulkState.job_id) ? bulkState : null;
    await mdui.confirm({
      headline: 'Take over the running refetch',
      description: run
        ? `Stop job ${run.job_id} (${run.done || 0}/${run.total || 0}) and start a new one with the options above? Its remaining songs are dropped.`
        : 'Stop the running refetch and start a new one with the options above?',
      cancelText: 'Cancel', confirmText: 'Take over',
      onConfirm: async () => { bulkForceNext = true; await startBulk(); },
    });
  };

  /* ---- Database version sweep (server/db_migrate.py) ---- */
  // No polling: the sweep is seconds of local file IO, so the button's
  // response already carries the finished job. `needs_refetch` is rendered
  // separately from the fix counts because it is the number that decides
  // whether the Refetch stale button has anything to do.
  const renderDbVer = (d) => {
    const pill = $('#dbver-status');
    const line = $('#dbver-line');
    const list = $('#dbver-results');
    const s = d.scan || {};
    const j = d.job;
    if (pill) {
      pill.textContent = j && j.state === 'running' ? 'running'
        : s.stale_entries ? `${s.stale_songs} stale` : 'current';
    }
    if (line) {
      const bits = [`format v${d.format_version} / parser epoch ${d.parser_epoch}`];
      if (s.entries != null) bits.push(`${s.songs} song(s), ${s.entries} file(s)`);
      if (s.stale_entries) {
        bits.push(`${s.stale_entries} stale`);
        bits.push(`${s.needs_refetch} need a real refetch`);
      } else {
        bits.push('all current');
      }
      if (j && j.state === 'done') {
        bits.push(`sweep: ${j.fixed} fixed, ${j.demoted} demoted, ${j.restamped} re-stamped, ${j.skipped} skipped`);
        if (j.translations_repaired) bits.push(`${j.translations_repaired} translation(s) repaired`);
        if (j.candidates_written) bits.push(`${j.candidates_written}/${j.candidates} snapshot(s)`);
        if (j.errors) bits.push(`${j.errors} error(s)`);
      }
      // The old cache/ directory, when it is still there. Its state files were
      // migrated automatically at startup; its lyrics were deliberately left,
      // so the button is the only way to do anything with them.
      const lg = d.legacy;
      if (lg && (lg.lyrics || lg.candidates)) {
        bits.push(`old cache/: ${lg.lyrics} file(s) not adopted`);
        if (lg.would_adopt) bits.push(`${lg.would_adopt} ready to adopt`);
        else if (!lg.already_present) bits.push('all already adopted');
      }
      if (d.adopt) {
        const a = d.adopt;
        if (a.dry_run) bits.push(`adopt dry run: ${a.lyrics} lyric(s), ${a.candidates} snapshot(s) would be imported as stale`);
        else bits.push(`adopted ${a.lyrics} lyric(s) + ${a.candidates} snapshot(s), all left stale for Refetch stale`);
        if (a.skipped_present) bits.push(`${a.skipped_present} already present`);
        if (a.unreadable) bits.push(`${a.unreadable} unreadable`);
        if (a.claimed_epoch) bits.push(`${a.claimed_epoch} had the epoch claim dropped`);
      }
      line.textContent = bits.join(' | ');
    }
    const refetchBtn = $('#dbver-refetch');
    if (refetchBtn) refetchBtn.disabled = !(s.needs_refetch > 0);
    // Only offered when there is something in cache/ we have not taken, and the
    // count comes from the server's own filesystem walk rather than a guess.
    const adoptBtn = $('#dbver-adopt');
    if (adoptBtn) {
      const lg = d.legacy;
      const show = !!(lg && lg.would_adopt > 0);
      adoptBtn.style.display = show ? '' : 'none';
      adoptBtn.disabled = !show;
    }
    if (list) {
      const rows = (j && j.results) || [];
      list.innerHTML = '';
      if (!rows.length) return;
      rows.slice(-60).reverse().forEach(r => {
        const cls = r.status === 'needs_refetch' ? 'rb-failed'
          : r.status === 'demoted' ? 'rb-same'
          : (r.status === 'error') ? 'rb-failed' : 'rb-upgraded';
        const el2 = el('div', {class:`rebase-row ${cls}`});
        el2.appendChild(document.createTextNode(
          `${r.song || r.key} - ${r.artist || ''} | ${r.status}${r.message ? ' | ' + r.message : ''}`));
        list.appendChild(el2);
      });
    }
  };
  const loadDbVer = async () => {
    try {
      const r = await API('/api/admin/library/dbversion');
      renderDbVer(await r.json());
    } catch {}
  };
  const runDbSweep = async (dryRun) => {
    const btn = dryRun ? $('#dbver-dry') : $('#dbver-sweep');
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/library/dbsweep/start', {method:'POST',
        headers:{'Content-Type':'application/json'}, body: JSON.stringify({dry_run: !!dryRun})});
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || 'sweep failed');
      renderDbVer(d);
      mdui.snackbar({message: d.job.dry_run ? 'Dry run finished' : `Sweep: ${d.job.fixed} fixed, ${d.job.demoted} demoted, ${d.job.needs_refetch} still need a refetch`});
      loadLibrary();
    } catch (e) { mdui.snackbar({message:'Sweep failed: '+e.message}); }
    if (btn) btn.loading = false;
  };
  // Two clicks on purpose: the first is a dry run and says exactly what would
  // be imported, the second writes. 2000 files is too many to write off a
  // single unconfirmed click, and the whole point of the operation is that the
  // imported text is NOT usable until it has been refetched -- so the operator
  // should see that count before agreeing to it.
  let adoptArmed = false;
  const adoptLegacy = async () => {
    const btn = $('#dbver-adopt');
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/library/dbversion/adopt', {method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({dry_run: !adoptArmed})});
      const d = await r.json();
      if (!d.ok) throw new Error((d.report && d.report.error) || 'adopt failed');
      const a = d.report || {};
      if (!adoptArmed) {
        adoptArmed = true;
        if (btn) { btn.textContent = `Adopt ${a.lyrics || 0} now`; btn.disabled = false; }
        mdui.snackbar({message: a.lyrics
          ? `Would import ${a.lyrics} lyric file(s) + ${a.candidates || 0} snapshot(s) AS STALE. Click again to write; they need Refetch stale after.`
          : 'Nothing left in cache/ to adopt'});
      } else {
        adoptArmed = false;
        if (btn) { btn.textContent = 'Adopt old cache/'; }
        mdui.snackbar({message: `Adopted ${a.lyrics || 0} lyric(s) + ${a.candidates || 0} snapshot(s), all left stale. Run Refetch stale to re-derive them.`});
        await loadDbVer();
      }
    } catch (e) { adoptArmed = false; mdui.snackbar({message:'Adopt failed: '+e.message}); }
    if (btn) btn.loading = false;
  };
  const refetchStale = async () => {
    const btn = $('#dbver-refetch');
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/library/dbversion/refetch', {method:'POST',
        headers:{'Content-Type':'application/json'}, body: JSON.stringify({workers: 4})});
      const d = await r.json();
      if (!d.ok) {
        if (d.running && d.running.job_id) {
          applyBulkStatus(d.running);
          mdui.snackbar({message:`Already running: ${d.running.done}/${d.running.total} -- showing it in the bulk panel`});
        } else {
          throw new Error(d.error || 'refetch failed');
        }
        return;
      }
      mdui.snackbar({message:`Refetching ${d.total} stale song(s) in ${d.batches || 1} batch(es) -- watch the bulk panel`});
      // Hand the work to the bulk panel rather than starting a second,
      // invisible job: bulk_progress is the only stream it renders.
      applyBulkStatus({job_id: d.job_id, state: 'running', total: d.total || 0,
                       workers: d.workers, cpu_workers: d.cpu_workers,
                       tq_workers: d.tq_workers, batch: d.batch,
                       batch_total: d.batches || 0, scope: 'stale', mode: 'fresh'});
      const stop = $('#bulk-stop');
      if (stop) stop.style.display = '';
    } catch (e) { mdui.snackbar({message:'Refetch stale failed: '+e.message}); }
    if (btn) btn.loading = false;
  };

  /* ---- Retranslate broken (server/retranslate.py) ---- */
  const renderRTrans = (d) => {
    const pill = $('#rtrans-status');
    const line = $('#rtrans-line');
    const list = $('#rtrans-results');
    const s = d.scan || {};
    const j = d.job;
    if (pill) pill.textContent = j && j.state === 'running' ? 'running'
      : s.songs_broken ? `${s.songs_broken} song(s) broken` : 'clean';
    if (line) {
      const bits = [];
      if (s.songs != null) bits.push(`${s.songs} song(s) checked`);
      if (s.rows_broken) {
        bits.push(`${s.rows_broken} broken row(s)`);
        const det = Object.entries(s.defects || {}).map(([k, v]) => `${k} x${v}`).join(', ');
        if (det) bits.push(det);
      } else {
        bits.push('no broken translations');
      }
      if (j && j.state !== 'running' && j.done) {
        bits.push(`${j.done}/${j.total}: ${j.fixed} song(s) retranslated, ${j.rows_fixed} row(s) fixed, ${j.rows_remaining} still broken`);
        if (j.errors) bits.push(`${j.errors} error(s)`);
      }
      line.textContent = bits.join(' | ');
    }
    if (list) {
      const rows = (j && j.results) || [];
      list.innerHTML = '';
      rows.slice(-60).reverse().forEach(r => {
        const cls = (r.status === 'error' || r.status === 'rate_limited') ? 'rb-failed'
          : r.status === 'partial' ? 'rb-same' : 'rb-upgraded';
        const el2 = el('div', {class:`rebase-row ${cls}`});
        el2.appendChild(document.createTextNode(
          `${r.song || r.key} - ${r.artist || ''} | ${r.status} | ${r.defects} broken (${r.detail || 'none'})${r.fixed ? ' | fixed ' + r.fixed : ''}`));
        list.appendChild(el2);
      });
    }
  };
  const scanRTrans = async () => {
    const btn = $('#rtrans-scan');
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/library/retranslate?lang=' +
        encodeURIComponent((($('#rtrans-lang') || {}).value || '').trim()));
      renderRTrans(await r.json());
    } catch (e) { mdui.snackbar({message:'Scan failed: '+e.message}); }
    if (btn) btn.loading = false;
  };
  const startRTrans = async () => {
    const btn = $('#rtrans-start');
    if (btn) btn.loading = true;
    try {
      const r = await API('/api/admin/library/retranslate/start', {method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({lang: (($('#rtrans-lang') || {}).value || '').trim()})});
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || 'start failed');
      mdui.snackbar({message:'Retranslate started'});
      await scanRTrans();
      const stop = $('#rtrans-stop');
      if (stop) stop.style.display = '';
    } catch (e) { mdui.snackbar({message:'Retranslate failed: '+e.message}); }
    if (btn) btn.loading = false;
  };
  const stopRTrans = async () => {
    try { await API('/api/admin/library/retranslate/stop', {method:'POST'}); } catch {}
    const stop = $('#rtrans-stop');
    if (stop) stop.style.display = 'none';
    await scanRTrans();
  };

  /* ---- nav (hash-routed: each tab is its own URL, middle-click / duplicate-tab safe) ---- */
  const pages = ['overview','logs','caches','library','nodes','jwt','update','files','crashes','settings','app'];
  const pageFromHash = () => (location.hash || '').replace(/^#\/?/, '');
  const switchPage = p => {
    if (!pages.includes(p)) return;
    activePage = p;
    if (pageFromHash() !== p) history.replaceState(null, '', '#/' + p);
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
    // Settings and App render from the SAME payload (the schema describes every
    // key); they differ only in which groups they draw, so opening either page
    // fetches once.
    else if (p==='settings' || p==='app') loadApp();
    if (p==='app') loadKill();
  };
  const initNav = () => {
    $$('#nav-list mdui-list-item').forEach(item => {
      item.addEventListener('click', () => { switchPage(item.dataset.page); });
    });
  };

  /* ---- polling: none. All live updates arrive server-pushed over the
      single SSE stream (interval via ?interval=); pages also (re)load on
      every navigation. ---- */

  /* ---- init ---- */
  const adoptRunningJobs = async () => {
    // Rejoin jobs that outlived a page reload: one status fetch each (not a
    // poll), then live SSE takes over. Dead ids are dropped silently.
    // FIRST ask the server what is running, with no job id at all. The
    // sessionStorage path below only knows about jobs THIS browser started, so
    // a job started in another tab -- or by the stale-refetch button -- left the
    // panel reading 'idle' with a Start button that could only answer 409.
    if (await loadBulkStatus()) return;
    try {
      const bj = sessionStorage.getItem('ymtu-bulk-job');
      if (bj) {
        const st = await json(`/api/admin/library/refetch/status/${encodeURIComponent(bj)}`);
        if (st && (st.state === 'running' || st.state === 'translating')) {
          applyBulkStatus(st);
        } else sessionStorage.removeItem('ymtu-bulk-job');
      }
    } catch { try { sessionStorage.removeItem('ymtu-bulk-job'); } catch {} }
    try {
      const pj = sessionStorage.getItem('ymtu-playlist-job');
      if (pj) {
        const st = await json(`/api/playlist/sync/status/${encodeURIComponent(pj)}`);
        if (st && (st.state === 'running' || st.state === 'queued')) {
          plJobId = pj;
          plState = {state: st.state, total: st.total || 0, done: st.done || 0,
            found: st.found || 0, unlyriced: st.unlyriced || 0, error_count: st.error_count || 0,
            current: st.current || '', tracks: st.tracks || []};
          renderPlSync(plState);
        } else sessionStorage.removeItem('ymtu-playlist-job');
      }
    } catch { try { sessionStorage.removeItem('ymtu-playlist-job'); } catch {} }
  };
  const init = () => {
    applyTheme();
    initNav();
    connectSSE();
    adoptRunningJobs();
    window.addEventListener('hashchange', () => {
      const p = pageFromHash();
      if (p && p !== activePage) switchPage(p);
    });
    switchPage(pages.includes(pageFromHash()) ? pageFromHash() : 'overview');
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
    const genDlBtn = $('#gen-dl-btn');
    if (genDlBtn) genDlBtn.addEventListener('click', () => downloadNodePy(false));
    const genDlWinBtn = $('#gen-dl-win-btn');
    if (genDlWinBtn) genDlWinBtn.addEventListener('click', () => downloadNodePy(true));
    const genCloseBtn = $('#gen-close');
    if (genCloseBtn) genCloseBtn.addEventListener('click', () => { try{$('#gen-dialog').open=false;}catch{} });

    const jwtCheckBtn = $('#jwt-check');
    if (jwtCheckBtn) jwtCheckBtn.addEventListener('click', () => checkJwt(jwtCheckBtn));
    const jwtStatsClear = $('#jwt-stats-clear');
    if (jwtStatsClear) jwtStatsClear.addEventListener('click', async () => {
      // Confirmed, because "clear history" reads like it clears the POOL. It
      // does not: the tokens keep working, only the ledger and the graphs go.
      await mdui.confirm({headline:'Clear token history',
        description:'Drops the request counters, the hourly buckets and the retirement ledger. '
          + 'The pool itself is untouched -- every token keeps working, its counters just start at zero.',
        cancelText:'Cancel', confirmText:'Clear history',
        onConfirm: async () => {
          try {
            await API('/api/admin/jwt/stats/clear', {method:'POST'});
            mdui.snackbar({message:'History cleared (the pool is unchanged)'});
            loadJwt();
          } catch (e) { mdui.snackbar({message:'Failed: '+e.message}); }
        }});
    });
    const jwtContribBtn = $('#jwt-contribute');
    if (jwtContribBtn) jwtContribBtn.addEventListener('click', contributeJwt);
    const jwtPushKeyBtn = $('#jwt-pushkey');
    if (jwtPushKeyBtn) jwtPushKeyBtn.addEventListener('click', async () => {
      if (jwtPushKeyBtn.loading) return;
      jwtPushKeyBtn.loading = true;
      try {
        const d = await json('/api/admin/jwt/push_key');
        const key = (d && d.key) || '';
        if (!key) { mdui.snackbar({message: 'No push key returned'}); return; }
        try {
          await navigator.clipboard.writeText(key);
          mdui.snackbar({message: 'Push key copied - paste it into the userscript CONFIG.key'});
        } catch {
          window.prompt('Push key (select and copy):', key);
        }
      } catch (e) {
        mdui.snackbar({message: 'Could not read the push key: ' + e.message});
      } finally {
        jwtPushKeyBtn.loading = false;
      }
    });

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
    const latRefreshBtn = $('#lat-refresh');
    if (latRefreshBtn) latRefreshBtn.addEventListener('click', loadLatency);
    const latClearBtn = $('#lat-clear');
    if (latClearBtn) latClearBtn.addEventListener('click', clearLatency);

    const rebaseStartBtn = $('#rebase-start');
    if (rebaseStartBtn) rebaseStartBtn.addEventListener('click', startRebase);
    const rebaseStopBtn = $('#rebase-stop');
    if (rebaseStopBtn) rebaseStopBtn.addEventListener('click', stopRebase);
    const retitleAllBtn = $('#unlyriced-retitle-all');
    if (retitleAllBtn) retitleAllBtn.addEventListener('click', retitleAll);
    const retitleSelBtn = $('#unlyriced-retitle-selected');
    if (retitleSelBtn) retitleSelBtn.addEventListener('click', retitleSelected);
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
    const bulkTakeBtn = $('#bulk-takeover');
    if (bulkTakeBtn) bulkTakeBtn.addEventListener('click', takeOverBulk);
    // Live knobs. `change` (not every keystroke) plus the debounce in
    // tuneBulkLive: mdui-text-field fires input per character, and a request per
    // character is a request storm against a job that is already busy.
    ['bulk-workers', 'bulk-cpu', 'bulk-tq', 'bulk-batch'].forEach(id => {
      const e = $('#' + id);
      if (e) e.addEventListener('change', tuneBulkLive);
    });
    const bulkTr = $('#bulk-translate');
    if (bulkTr) bulkTr.addEventListener('change', tuneBulkLive);
    const bulkTransBtn = $('#bulk-translate-missing');
    if (bulkTransBtn) bulkTransBtn.addEventListener('click', translateMissing);
    const dbvRefresh = $('#dbver-refresh');
    if (dbvRefresh) dbvRefresh.addEventListener('click', loadDbVer);
    const dbvDry = $('#dbver-dry');
    if (dbvDry) dbvDry.addEventListener('click', () => runDbSweep(true));
    const dbvSweep = $('#dbver-sweep');
    if (dbvSweep) dbvSweep.addEventListener('click', () => runDbSweep(false));
    const dbvRefetch = $('#dbver-refetch');
    if (dbvRefetch) dbvRefetch.addEventListener('click', refetchStale);
    const dbvAdopt = $('#dbver-adopt');
    if (dbvAdopt) dbvAdopt.addEventListener('click', adoptLegacy);
    const rtScan = $('#rtrans-scan');
    if (rtScan) rtScan.addEventListener('click', scanRTrans);
    const rtStart = $('#rtrans-start');
    if (rtStart) rtStart.addEventListener('click', startRTrans);
    const rtStop = $('#rtrans-stop');
    if (rtStop) rtStop.addEventListener('click', stopRTrans);
    aiInit();
    appInit();
    killInit();
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
