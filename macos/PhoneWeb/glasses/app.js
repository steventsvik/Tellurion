// Tellurion on Even G2 glasses: who needs you, answering a permission prompt, an agent's
// latest output, and talking to an agent or the orchestrator. This file only wires the
// parts together; what's shown is decided in screens.js and what input does in input.js.

import {
  AudioInputSource, CreateStartUpPageContainer, ListContainerProperty, ListItemContainerProperty, RebuildPageContainer,
  TextContainerProperty, TextContainerUpgrade, waitForEvenAppBridge,
} from "./vendor/even_hub_sdk/index.js";
import { TELLURION_ORIGIN } from "./config.js";
import { createGlass } from "./glass.js";
import { createDebouncer, createUI, normalizeEvent, step, subscriptions } from "./input.js";
import { createLink, pairingCode, resolveOrigin } from "./link.js";
import { createModel, withLink, withMessage } from "./model.js";
import { plain, render } from "./screens.js";
import { createVoice } from "./voice.js";

const $ = (id) => document.getElementById(id);
const UI_KEY = "tellurion.ui";
const STATUS = {
  boot: "Starting…", connecting: "Connecting to your Mac…", pairing: "Waiting for you to approve on your Mac",
  unpaired: "Not paired", ok: "Connected", lost: "Can't reach your Mac. Trying again.", off: "Glasses are turned off in Tellurion",
  nomac: "This build has no Mac address",
};

let model = createModel();
let ui = createUI();
let glass = null;
let link = null;
let voice = null;
let bridge = null;
const fresh = createDebouncer();

/// The page's own storage, for when the Even app's isn't there (a plain browser).
const pageStore = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* not kept */ } },
  remove(key) { try { localStorage.removeItem(key); } catch { /* not kept */ } },
};

/// The Even app's storage, which outlives the page; the page's own as a second copy.
const storage = {
  async get(key) {
    try { const value = await bridge?.getLocalStorage(key); if (value) return value; } catch { /* fall through */ }
    return pageStore.get(key);
  },
  async set(key, value) {
    pageStore.set(key, value);
    try { await bridge?.setLocalStorage(key, value); } catch { /* the page's copy is there */ }
  },
  async remove(key) {
    pageStore.remove(key);
    try { await bridge?.setLocalStorage(key, ""); } catch { /* the page's copy is gone */ }
  },
};

function draw() {
  const now = Date.now();
  const description = render(ui, model, now);
  glass?.show(description);
  $("status").textContent = (STATUS[model.link] ?? "") + (model.link === "ok" && model.mac ? " to " + model.mac : "");
  $("mirror").textContent = plain(description);
}

/// One step of the input machine, then everything it asked for. Nothing here may throw:
/// a failed call must not leave the screen stuck.
function advance(event) {
  const now = Date.now();
  let result;
  try { result = step(ui, model, event, now); } catch (error) { console.error("step", error); return; }
  const screenChanged = result.ui.stack !== ui.stack;
  ui = result.ui;
  for (const message of result.out) {
    if (!link?.send(message)) ui = { ...ui, flash: { text: "Not connected", until: now + 3000 } };
  }
  for (const effect of result.fx) {
    try {
      if (effect.fx === "listen") voice?.begin();
      else if (effect.fx === "stop") voice?.end();
      else if (effect.fx === "cancel") voice?.cancel();
      else if (effect.fx === "exit") glass?.exit(1);
    } catch (error) { console.error(effect.fx, error); }
  }
  link?.subscribe(subscriptions(ui));
  // Where you were survives the page being put away and brought back.
  if (screenChanged) storage.set(UI_KEY, JSON.stringify({ stack: ui.stack, sel: ui.sel })).catch(() => {});
  draw();
}

function onEvent(raw) {
  let event;
  try { event = normalizeEvent(raw); } catch { return; }
  if (!event) return;
  if (event.type === "audio") { voice?.audio(event.pcm); return; }
  const now = Date.now();
  if (!fresh(event, now)) return;
  if (event.type === "up" || event.type === "down") glass?.noteScroll();
  if (event.type === "foreground") link?.wake();
  if (event.type === "abnormal") glass?.forget();
  advance(event);
}

function onMessage(message) {
  if (message.t === "heard") { advance({ type: "heard", text: message.text, final: message.final === true, error: message.error }); return; }
  if (message.t === "answered" || message.t === "said" || message.t === "orchsent") {
    advance({ type: "reply", ok: message.ok === true, message: message.message });
    return;
  }
  if (message.t === "error") { advance({ type: "reply", ok: false, message: message.message }); return; }
  model = withMessage(model, message, Date.now());
  advance({ type: "model" });
}

function onState(state, extra) {
  model = withLink(model, state, Date.now(), extra);
  if (state !== "ok") voice?.cancel();
  advance({ type: "model" });
}

async function restore() {
  try {
    const saved = JSON.parse((await storage.get(UI_KEY)) || "null");
    if (saved && Array.isArray(saved.stack) && saved.stack.length && saved.stack[0]?.name === "home") {
      ui = { ...ui, stack: saved.stack.slice(0, 4), sel: typeof saved.sel === "string" ? saved.sel : null };
    }
  } catch { /* starts on Home */ }
}

async function main() {
  // Outside the Even app there's no bridge and this waits: the page says so meanwhile.
  const waiting = setTimeout(() => { $("status").textContent = "Open this from the Even app to use it on your glasses."; }, 4000);
  bridge = await waitForEvenAppBridge();
  clearTimeout(waiting);

  glass = createGlass({
    bridge,
    make: {
      create: (page) => new CreateStartUpPageContainer(shaped(page)),
      rebuild: (page) => new RebuildPageContainer(shaped(page)),
      upgrade: (change) => new TextContainerUpgrade(change),
    },
    onError: (error) => console.warn("glasses", error?.message ?? error),
  });
  voice = createVoice({
    send: (message) => link?.send(message),
    sendAudio: (bytes) => link?.sendAudio(bytes),
    // The glasses' microphones need a page on the glasses first.
    mic: (on) => (on && !glass.ready ? null : bridge.audioControl(on, AudioInputSource.Glasses)),
  });
  bridge.onEvenHubEvent(onEvent);

  await restore();
  const where = resolveOrigin(TELLURION_ORIGIN, location);
  if (!where) {
    model = withLink(model, "nomac", Date.now());
    draw();
    return;
  }
  const code = pairingCode(location);
  // The code is used once; it doesn't stay in the address.
  if (code) history.replaceState(null, "", location.pathname);
  link = createLink({ origin: where.origin, WebSocket, fetch: (...args) => fetch(...args), storage, onState, onMessage });
  link.subscribe(subscriptions(ui));
  link.start(code);
  draw();
  // Time passing: "working 3m" moves on, a dropped connection becomes "Can't reach your Mac".
  setInterval(() => advance({ type: "tick" }), 2000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { link.wake(); draw(); } });
}

/// A page with the SDK's own container classes inside.
function shaped(page) {
  return {
    containerTotalNum: page.containerTotalNum,
    textObject: page.textObject.map((item) => new TextContainerProperty(item)),
    listObject: page.listObject.map((item) => new ListContainerProperty({ ...item, itemContainer: new ListItemContainerProperty(item.itemContainer) })),
  };
}

main().catch((error) => {
  console.error(error);
  $("status").textContent = "Something went wrong starting up. Close and open it again.";
});
