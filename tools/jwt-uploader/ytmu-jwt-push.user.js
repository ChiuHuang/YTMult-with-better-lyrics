// ==UserScript==
// @name         YTMU JWT push (silent)
// @namespace    https://github.com/ChiuHuang/ytmusicultimate
// @version      1.0.0
// @description  Takes a Cubey JWT from the challenge page and pushes it into the YTMusicUltimate server JWT pool. No UI, no page changes, no console output.
// @author       ChiuHuang
// @match        https://lyrics.api.dacubeking.com/*
// (CONFIG.auto needs the whole web: uncomment the next line)
// @match        *://*/*
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @run-at       document-start
// ==/UserScript==

/* Setup, once:
 *   1. dashboard -> JWT Pool -> "Copy push key"
 *   2. put that key in CONFIG.key below, and your server in CONFIG.server
 *   3. save this file; Tampermonkey/Violentmonkey picks it up
 *   4. open https://lyrics.api.dacubeking.com/challenge once. The token is
 *      taken and pushed, and the page is left exactly as it was.
 *
 * CONFIG can also be set at runtime from the console, which avoids editing
 * this file:
 *   GM_setValue('cfg', {server:'http://192.168.1.5:20016', key:'<push key>'})
 *
 * Fully automatic (no tab at all): uncomment the `@match *://*/*` line in the
 * metadata block above, set CONFIG.auto = true, and the script drops a 2x2px
 * iframe of the challenge page into any page you visit, at most once every
 * CONFIG.autoEveryMin minutes. Caveat: Cloudflare's widget may refuse to solve
 * in a frame that is effectively invisible -- the manual page above always
 * works.
 */

(function () {
  'use strict';

  var CHALLENGE_URL = 'https://lyrics.api.dacubeking.com/challenge';
  var VERIFY_URL = '/verify-turnstile';
  var FRAME_ID = 'ytmu-jwt-push-frame';
  var DEBUG = false;

  var CONFIG = {
    server: 'http://localhost:20016', // your YTMU server
    key: '',                           // dashboard -> JWT Pool -> Copy push key
    auto: false,                       // true: hidden challenge iframe on any page
    autoEveryMin: 25,                  // how often auto mode may do that
    minGapSec: 90,                     // ignore a second token inside this window
    tokenWaitMs: 65000                 // how long to wait for the Turnstile answer
  };

  var cfg = loadCfg();
  var pushed = null;                   // this run's Turnstile token, dedupe guard

  function loadCfg() {
    var out = {};
    for (var k in CONFIG) {
      if (Object.prototype.hasOwnProperty.call(CONFIG, k)) out[k] = CONFIG[k];
    }
    try {
      var saved = GM_getValue('cfg', null);
      if (saved && typeof saved === 'object') {
        for (var s in saved) {
          if (Object.prototype.hasOwnProperty.call(saved, s) && saved[s] !== undefined) {
            out[s] = saved[s];
          }
        }
      }
    } catch (e) { /* no GM storage, CONFIG stands */ }
    out.server = String(out.server || '').replace(/\/+$/, '');
    out.key = String(out.key || '').trim();
    return out;
  }

  function log() {
    if (!DEBUG) return;
    try { console.log.apply(console, ['[ytmu-jwt]'].concat([].slice.call(arguments))); } catch (e) {}
  }

  function warnOnce(flag, text) {
    if (DEBUG) return;
    try {
      if (GM_getValue(flag, false)) return;
      GM_setValue(flag, true);
    } catch (e) { /* ignore */ }
    try { console.warn('[ytmu-jwt] ' + text); } catch (e) {}
  }

  function lastPush() {
    try { return Number(GM_getValue('lastPush', 0)) || 0; } catch (e) { return 0; }
  }

  function markPush() {
    try { GM_setValue('lastPush', Date.now()); } catch (e) { /* ignore */ }
  }

  // ---------- the push ----------

  function pushToken(jwt) {
    return new Promise(function (resolve) {
      if (!cfg.key) {
        warnOnce('warnedNoKey', 'no push key configured, set CONFIG.key (dashboard -> JWT Pool -> Copy push key)');
        resolve({ ok: false, error: 'no key' });
        return;
      }
      if (!cfg.server) {
        warnOnce('warnedNoServer', 'no server configured, set CONFIG.server');
        resolve({ ok: false, error: 'no server' });
        return;
      }
      try {
        GM_xmlhttpRequest({
          method: 'POST',
          url: cfg.server + '/api/jwt/push',
          headers: { 'Content-Type': 'application/json', 'X-YTMU-Key': cfg.key },
          data: JSON.stringify({ token: jwt, source: 'userscript' }),
          timeout: 15000,
          onload: function (r) {
            let body = null;
            try { body = JSON.parse(r.responseText); } catch (e) { body = null; }
            const ok = r.status === 200 && !!(body && body.ok);
            log('push', r.status, r.responseText);
            if (!ok) {
              warnOnce('warnedPushFail', 'push rejected: HTTP ' + r.status + ' ' +
                String(r.responseText || '').slice(0, 120));
            }
            resolve({ ok: ok, status: r.status, body: body });
          },
          onerror: function () { resolve({ ok: false, error: 'network' }); },
          ontimeout: function () { resolve({ ok: false, error: 'timeout' }); }
        });
      } catch (e) {
        resolve({ ok: false, error: String(e) });
      }
    });
  }

  // Same-origin from the challenge page, so a plain fetch is enough here.
  async function exchange(token) {
    const res = await fetch(VERIFY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token }),
      credentials: 'omit'
    });
    if (!res.ok) throw new Error('verify-turnstile HTTP ' + res.status);
    const text = await res.text();
    let data = null;
    try { data = JSON.parse(text); } catch (e) { data = null; }
    const jwt = (data && (data.jwt || data.jwtToken)) || '';
    if (jwt && jwt.length > 20) return jwt;
    const bare = text.replace(/\s+/g, '');
    if (!data && bare.length > 20 && !/[{}<>]/.test(bare)) return bare;
    throw new Error('no jwt in the verify-turnstile answer');
  }

  async function run(token) {
    if (pushed === token) return;
    pushed = token;
    if (Date.now() - lastPush() < (cfg.minGapSec || 90) * 1000) {
      log('skipped, inside the cooldown');
      return;
    }
    let jwt = '';
    try {
      jwt = await exchange(token);
    } catch (e) {
      warnOnce('warnedVerify', 'verify-turnstile failed: ' + (e && e.message ? e.message : e));
      return;
    }
    const res = await pushToken(jwt);
    if (res.ok) {
      markPush();
      log('pushed, pool=' + (res.body && res.body.num_pool));
    }
  }

  // ---------- picking the Turnstile token up ----------

  function watchChallenge() {
    window.addEventListener('message', function (e) {
      const d = e.data;
      if (!d || typeof d !== 'object') return;
      if (d.type === 'turnstile-token' && typeof d.token === 'string') {
        run(d.token);
      } else if (d.type === 'turnstile-error' || d.type === 'turnstile-timeout') {
        warnOnce('warnedChallenge', 'challenge reported ' + d.type);
      }
    });

    // Second, independent path: Cloudflare leaves the response in a hidden
    // input. Needed when this page is framed (the page posts to its PARENT, so
    // the message never arrives here) and when the message beats the script.
    const deadline = Date.now() + (cfg.tokenWaitMs || 65000);
    const poll = setInterval(function () {
      let el = null;
      try { el = document.querySelector('input[name="cf-turnstile-response"]'); } catch (e) { el = null; }
      if (el && el.value && el.value.length >= 20) {
        clearInterval(poll);
        run(el.value);
        return;
      }
      if (Date.now() > deadline) clearInterval(poll);
    }, 500);
  }

  // ---------- auto mode: an invisible frame of the challenge page ----------

  function injectHiddenChallenge() {
    if (document.getElementById(FRAME_ID)) return;
    const everyMs = Math.max(5, cfg.autoEveryMin || 25) * 60000;
    if (Date.now() - lastPush() < everyMs) return;

    let host = document.body || document.documentElement;
    if (!host) return;
    const frame = document.createElement('iframe');
    frame.id = FRAME_ID;
    frame.src = CHALLENGE_URL;
    frame.setAttribute('aria-hidden', 'true');
    frame.setAttribute('tabindex', '-1');
    frame.setAttribute('title', '');
    // 2x2px in the bottom-right corner, not a hidden frame: a frame parked
    // off-screen is exactly what the widget's visibility check rejects.
    frame.style.cssText = 'position:fixed;right:0;bottom:0;width:2px;height:2px;' +
      'border:0;margin:0;padding:0;opacity:0.02;pointer-events:none;z-index:2147483646;';
    host.appendChild(frame);
    log('hidden challenge frame added');
    setTimeout(function () {
      try { frame.remove(); } catch (e) {}
    }, 70000);
  }

  // ---------- entry ----------

  const onChallenge = location.hostname === 'lyrics.api.dacubeking.com';
  if (onChallenge) {
    watchChallenge();
  } else if (cfg.auto) {
    const start = function () { injectHiddenChallenge(); };
    if (document.body) start();
    else document.addEventListener('DOMContentLoaded', start, { once: true });
  }
})();
