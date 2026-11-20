// Netflix Sleep Timer: in-player button.
// Counts down, fades the video's volume over the last minute (with a "Still watching?" card),
// pauses Netflix, restores the volume, then asks the Windows helper to sleep / screen-off / shut down.
(() => {
  if (window.__netflixSleepTimer) return;
  window.__netflixSleepTimer = true;

  const FADE_MS = 60 * 1000;
  const TICK_MS = 250;
  const IDLE_HIDE_MS = 3000;
  const STORE_END = 'nst-endTime'; // sessionStorage: survives a page reload in this tab
  const PRESETS = [15, 30, 45, 60, 90, 120];
  const ACTIONS = [
    { id: 'pause', label: 'Pause only' },
    { id: 'screenOff', label: 'Pause + screen off' },
    { id: 'sleep', label: 'Pause + sleep PC' },
    { id: 'shutdown', label: 'Pause + shut down' },
  ];

  // ---------------- state ----------------
  let endTime = readStoredEnd();
  let action = 'sleep';
  let fading = false;
  let origVolume = null;
  let lastActivity = Date.now();
  let panelOpen = false;
  let message = '';

  chrome.storage.local.get({ action: 'sleep' }).then((v) => {
    if (ACTIONS.some((a) => a.id === v.action)) action = v.action;
    render();
  });

  function readStoredEnd() {
    try {
      const v = Number(sessionStorage.getItem(STORE_END));
      return v > Date.now() ? v : null;
    } catch { return null; }
  }
  function storeEnd() {
    try {
      if (endTime) sessionStorage.setItem(STORE_END, String(endTime));
      else sessionStorage.removeItem(STORE_END);
    } catch { /* storage blocked: timer just won't survive a reload */ }
  }

  // ---------------- Netflix helpers ----------------
  function getVideo() {
    const vids = [...document.querySelectorAll('video')];
    return vids.find((v) => !v.paused) || vids[0] || null;
  }
  function onWatchPage() {
    return location.pathname.startsWith('/watch') && !!getVideo();
  }
  function pauseNetflix() {
    const btn = document.querySelector('[data-uia="control-play-pause-pause"]');
    if (btn) btn.click();
    const v = getVideo();
    if (v && !v.paused) v.pause();
  }

  // ---------------- volume fade ----------------
  function restoreVolume() {
    const v = getVideo();
    if (v && origVolume !== null) v.volume = origVolume;
    origVolume = null;
    fading = false;
  }

  // ---------------- timer ----------------
  function start(minutes) {
    restoreVolume();
    endTime = Date.now() + minutes * 60 * 1000;
    message = '';
    storeEnd();
    panelOpen = false;
    render();
  }
  function addMinutes(minutes) {
    if (!endTime) return start(minutes);
    endTime += minutes * 60 * 1000;
    if (endTime - Date.now() > FADE_MS) restoreVolume();
    storeEnd();
    render();
  }
  function cancel() {
    restoreVolume();
    endTime = null;
    message = 'Timer cancelled';
    storeEnd();
    render();
  }
  function complete() {
    const chosen = action;
    endTime = null;
    storeEnd();
    pauseNetflix();
    setTimeout(() => {
      restoreVolume(); // paused, so silent; volume is back to normal next time you watch
      message = 'Paused. Goodnight.';
      render();
      if (chosen !== 'pause') sendPower(chosen);
    }, 800);
  }

  function sendPower(act) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: 'power', action: act }, (resp) => {
          if (chrome.runtime.lastError) resolve({ ok: false, error: chrome.runtime.lastError.message });
          else resolve(resp || { ok: false });
        });
      } catch (e) {
        resolve({ ok: false, error: String(e) }); // extension reloaded/updated while the page was open
      }
    }).then((resp) => {
      if (!resp.ok && act !== 'ping') {
        message = 'Paused, but the PC helper is not installed (run Install.bat).';
        render();
      }
      return resp;
    });
  }

  let helperOk = null;
  function checkHelper() {
    sendPower('ping').then((r) => { helperOk = !!r.ok; render(); });
  }

  // ---------------- UI ----------------
  const host = document.createElement('div');
  host.id = 'netflix-sleep-timer';
  host.style.cssText = 'all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `
    <style>
      .wrap, .card { font-family: 'Netflix Sans', 'Helvetica Neue', 'Segoe UI', Arial, sans-serif; }
      * { box-sizing: border-box; }
      button, select, input { font: inherit; }
      .wrap { position: absolute; top: 20px; left: 50%; transform: translateX(-50%);
              display: flex; flex-direction: column; align-items: center; gap: 10px;
              pointer-events: auto; transition: opacity .3s; }
      .wrap.hidden { opacity: 0; pointer-events: none; }
      .pill { display: flex; align-items: center; gap: 8px; height: 40px; padding: 0 16px;
              border: 0; border-radius: 20px; background: rgba(20,20,20,.75); color: #fff;
              font-size: 16px; font-weight: 700; cursor: pointer; backdrop-filter: blur(6px); }
      .pill:hover, .pill:focus-visible { background: rgba(50,50,50,.9); outline: 2px solid #fff; }
      .pill .moon { font-size: 18px; }
      .panel { width: 320px; padding: 16px; border-radius: 8px; background: #141414; color: #fff;
               box-shadow: 0 8px 32px rgba(0,0,0,.6); }
      .panel h2 { margin: 0 0 12px; font-size: 14px; letter-spacing: .08em; color: #e50914; }
      .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
      .btn { height: 38px; border: 0; border-radius: 4px; background: #2d2d2d; color: #fff;
             font-weight: 700; font-size: 14px; cursor: pointer; }
      .btn:hover, .btn:focus-visible { background: #404040; outline: none; }
      .btn.red { background: #e50914; }
      .btn.red:hover, .btn.red:focus-visible { background: #f6121d; }
      .row { display: flex; align-items: center; gap: 8px; margin-top: 12px; }
      .row label { flex: 1; color: #aaa; font-size: 14px; }
      input, select { height: 34px; border: 1px solid #444; border-radius: 4px; background: #2d2d2d;
                      color: #fff; padding: 0 8px; font-size: 14px; }
      input { width: 72px; }
      select { width: 170px; }
      .two { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 12px; }
      .note { margin-top: 10px; font-size: 12px; color: #f5a623; }
      .status { font-size: 13px; color: #ccc; background: rgba(20,20,20,.75); padding: 4px 10px; border-radius: 4px; }
      .card { position: absolute; right: 32px; bottom: 140px; width: 300px; padding: 14px;
              border-radius: 8px; background: #141414; color: #fff; pointer-events: auto;
              box-shadow: 0 8px 32px rgba(0,0,0,.6); }
      .card p { margin: 0 0 12px; font-size: 16px; font-weight: 700; }
      [hidden] { display: none !important; }
    </style>
    <div class="wrap hidden" part="wrap">
      <button class="pill" aria-expanded="false" aria-label="Sleep timer"><span class="moon" aria-hidden="true">&#x1F319;</span><span class="time">Sleep timer</span></button>
      <div class="status" hidden></div>
      <div class="panel" role="dialog" aria-label="Sleep timer" hidden>
        <h2>SLEEP TIMER</h2>
        <div class="grid">${PRESETS.map((m) => `<button class="btn preset" data-min="${m}">${m} min</button>`).join('')}</div>
        <div class="row">
          <label for="custom">Custom (minutes)</label>
          <input id="custom" type="number" min="1" max="600" value="40">
          <button class="btn red" data-act="custom" style="width:70px">Start</button>
        </div>
        <div class="row">
          <label for="action">When it ends</label>
          <select id="action">${ACTIONS.map((a) => `<option value="${a.id}">${a.label}</option>`).join('')}</select>
        </div>
        <div class="two">
          <button class="btn" data-act="plus10">+10 min</button>
          <button class="btn" data-act="cancel">Cancel timer</button>
        </div>
        <div class="note" hidden>PC helper not found: the timer will only pause Netflix. Run Install.bat to enable sleep / screen off / shut down.</div>
      </div>
    </div>
    <div class="card" role="alertdialog" aria-live="polite" hidden>
      <p class="card-text">Still watching?</p>
      <div class="two" style="margin-top:0">
        <button class="btn red" data-act="plus15">+15 min</button>
        <button class="btn" data-act="now">Pause now</button>
      </div>
    </div>`;

  const $ = (sel) => root.querySelector(sel);
  const wrap = $('.wrap'), pill = $('.pill'), pillTime = $('.time'), panel = $('.panel');
  const statusEl = $('.status'), note = $('.note'), card = $('.card'), cardText = $('.card-text');
  const customInput = $('#custom'), actionSelect = $('#action');

  // Keep Netflix from reacting to our clicks/keys (space would toggle play, clicks would pause).
  for (const type of ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'keydown', 'keyup', 'keypress', 'wheel']) {
    root.addEventListener(type, (e) => {
      e.stopPropagation();
      if (type === 'keydown' && e.key === 'Escape') { panelOpen = false; render(); pill.focus(); }
    });
  }

  pill.addEventListener('click', () => {
    panelOpen = !panelOpen;
    if (panelOpen) { message = ''; checkHelper(); }
    render();
  });
  root.querySelectorAll('.preset').forEach((b) => b.addEventListener('click', () => start(Number(b.dataset.min))));
  root.addEventListener('click', (e) => {
    const act = e.target.closest('[data-act]')?.dataset.act;
    if (act === 'custom') {
      const m = Math.round(Number(customInput.value));
      if (m >= 1 && m <= 600) start(m); else customInput.focus();
    } else if (act === 'plus10') addMinutes(10);
    else if (act === 'cancel') cancel();
    else if (act === 'plus15') addMinutes(15);
    else if (act === 'now') { endTime = Date.now(); tick(); }
  });
  actionSelect.addEventListener('change', () => {
    action = actionSelect.value;
    chrome.storage.local.set({ action }).catch(() => {});
    render();
  });

  document.addEventListener('mousemove', () => { lastActivity = Date.now(); }, true);

  function fmt(ms) {
    const s = Math.max(0, Math.ceil(ms / 1000));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
  }

  function render() {
    const remaining = endTime ? endTime - Date.now() : null;
    const inFade = remaining !== null && remaining <= FADE_MS;
    pillTime.textContent = remaining !== null ? fmt(remaining) : 'Sleep timer';
    pill.setAttribute('aria-expanded', String(panelOpen));
    panel.hidden = !panelOpen;
    actionSelect.value = action;
    note.hidden = !(panelOpen && action !== 'pause' && helperOk === false);
    statusEl.hidden = !message;
    statusEl.textContent = message;
    card.hidden = !inFade;
    if (inFade) cardText.textContent = `Still watching? Pausing in ${fmt(remaining)}`;
    const active = Date.now() - lastActivity < IDLE_HIDE_MS;
    const show = (onWatchPage() || endTime) && (panelOpen || active || root.activeElement);
    wrap.classList.toggle('hidden', !show);
  }

  // In fullscreen only the fullscreen element's subtree is visible, so follow it.
  function attach() {
    const fs = document.fullscreenElement;
    const parent = fs && fs.tagName !== 'VIDEO' ? fs : document.body;
    if (parent && host.parentNode !== parent) parent.appendChild(host);
  }

  function tick() {
    attach();
    if (endTime) {
      const remaining = endTime - Date.now();
      if (remaining <= 0) { complete(); }
      else if (remaining <= FADE_MS) {
        const v = getVideo();
        if (!fading) { fading = true; origVolume = v ? v.volume : null; }
        if (v && origVolume !== null) v.volume = Math.max(0, Math.min(1, origVolume * (remaining / FADE_MS)));
      }
    }
    render();
  }

  document.addEventListener('fullscreenchange', attach);
  window.addEventListener('pagehide', restoreVolume);
  setInterval(tick, TICK_MS);
  tick();
})();
