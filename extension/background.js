// Relays power actions from the Netflix page to the Windows helper (native messaging host).
// Content scripts cannot talk to native hosts directly, so they go through this worker.

const HOST = 'com.netflixsleeptimer.host';
const ALLOWED = new Set(['ping', 'sleep', 'screenOff', 'shutdown']);

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || !msg || msg.type !== 'power') return false;
  if (!ALLOWED.has(msg.action)) {
    sendResponse({ ok: false, error: 'Unknown action' });
    return false;
  }
  chrome.runtime.sendNativeMessage(HOST, { action: msg.action }, (response) => {
    if (chrome.runtime.lastError) {
      sendResponse({ ok: false, error: chrome.runtime.lastError.message });
    } else {
      sendResponse(response || { ok: false, error: 'No response from helper' });
    }
  });
  return true; // keep the channel open for the async reply
});
