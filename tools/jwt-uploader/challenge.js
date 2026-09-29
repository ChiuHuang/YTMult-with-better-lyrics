/* Runs on https://lyrics.api.dacubeking.com/challenge (and frames of it).
   The page's inline script calls window.parent.postMessage({type:'turnstile-token',
   token}, '*'). When this page is a top-level tab -- which is how the extension
   opens it -- window.parent IS window, so the message lands right here and a
   content script listener still sees it.

   Second, independent path: Cloudflare leaves the response in a hidden
   input[name=cf-turnstile-response] inside the widget. Polling it covers the
   case where the page posts the message before this script is injected, or
   changes the message shape. Whichever arrives first wins; the value is
   deduped so a double hit does not upload twice.

   Nothing here talks to the network and nothing is stored: the token is
   forwarded to the service worker and dropped. */
(function () {
  'use strict';

  var sent = null;

  function relay(payload) {
    try {
      chrome.runtime.sendMessage(payload);
    } catch (e) {
      // Extension context invalidated (reloaded/updated). Nothing to do.
    }
  }

  function send(token, how) {
    if (typeof token !== 'string' || token.length < 20) return;
    if (token === sent) return;
    sent = token;
    relay({ type: 'turnstile-token', token: token, how: how });
  }

  function fail(kind) {
    relay({ type: 'turnstile-error', kind: kind });
  }

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || typeof d !== 'object') return;
    if (d.type === 'turnstile-token' && typeof d.token === 'string') {
      send(d.token, 'message');
    } else if (d.type === 'turnstile-error') {
      fail('challenge reported an error: ' + String(d.error || 'unknown'));
    } else if (d.type === 'turnstile-timeout') {
      fail('challenge timed out (Cloudflare did not hand out a token)');
    }
  });

  var tries = 0;
  var poll = setInterval(function () {
    tries += 1;
    var el = null;
    try {
      el = document.querySelector('input[name="cf-turnstile-response"]');
    } catch (e) {
      el = null;
    }
    if (el && el.value && el.value.length >= 20) {
      clearInterval(poll);
      send(el.value, 'input');
      return;
    }
    if (tries > 130) clearInterval(poll); // ~65s, one turn usually takes <10s
  }, 500);
})();
