// Reports the active tab of the last focused window to the oculus-page native
// host, which writes it where the Omarchy bar widget reads it.
//
// The extension only has host permissions for GitHub and Codeberg, so Chromium
// hands it the URL of tabs on those sites and nothing else: any other
// page is reported as an empty URL, which the widget reads as "not a forge page".
//
// Keep this filename versioned. Chromium caches service workers for extensions
// loaded via --load-extension, so a new URL forces registration of new code.

const HOST = "com.andrewgilley.oculus_page";
let last = null;

function send(tab) {
  const url = (tab && tab.url) || "";
  if (url === last) return;
  last = url;
  chrome.runtime.sendNativeMessage(HOST, { url }, () => {
    // No host installed, or it failed: try again on the next change.
    if (chrome.runtime.lastError) last = null;
  });
}

function reportActive() {
  chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
    if (chrome.runtime.lastError) return;
    send(tabs[0]);
  });
}

chrome.tabs.onActivated.addListener(reportActive);
chrome.windows.onFocusChanged.addListener((windowId) => {
  // Focus moving to another app isn't a page change; keep the last one.
  if (windowId !== chrome.windows.WINDOW_ID_NONE) reportActive();
});
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (tab.active && (change.url !== undefined || change.status !== undefined)) {
    reportActive();
  }
});
chrome.tabs.onRemoved.addListener(reportActive);
chrome.runtime.onStartup.addListener(reportActive);
chrome.runtime.onInstalled.addListener(reportActive);
