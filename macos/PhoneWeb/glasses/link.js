// The connection to Tellurion on the Mac: pairing, then one WebSocket that says who it is
// first, comes back by itself when it drops, and asks again for what the screen needs.
//
// The Mac's address is this page's own when Tellurion serves the page (a scanned QR), and
// the one written into config.js when the app was packaged for the glasses' menu. The
// device token is the only secret: it lives in the Even app's storage, never in the package.

export const TOKEN_KEY = "tellurion.token";
export const BACKOFF = [1000, 2000, 4000, 8000, 15000, 30000];
export const PING_EVERY = 20_000;
export const SILENCE_LIMIT = 45_000;
export const PAIR_POLL = 2000;
export const PAIR_RETRY = 5000;

/// Where Tellurion is: the configured address if the package has one, or this page's own.
/// Null when there's neither (a packaged page with nothing written in).
export function resolveOrigin(configured, location) {
  const fixed = String(configured ?? "").trim().replace(/\/+$/, "");
  if (/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(fixed)) return { origin: fixed, packaged: true };
  if (location && /^https?:$/.test(location.protocol) && location.host) {
    return { origin: location.protocol + "//" + location.host, packaged: false };
  }
  return null;
}

export function socketURL(origin) {
  return origin.replace(/^http/, "ws") + "/glasses/ws";
}

/// The pairing code in a scanned address ("#pair=K7QM-2XRD" or "?pair="), if any.
export function pairingCode(location) {
  for (const part of [location?.hash, location?.search]) {
    const code = new URLSearchParams(String(part ?? "").replace(/^[#?]/, "")).get("pair");
    if (code) return code;
  }
  return null;
}

/// What a set of subscriptions takes to become another: messages to send.
export function subscriptionChanges(before, after) {
  const key = (message) => JSON.stringify(message);
  const had = new Set(before.map(key));
  const messages = after.filter((message) => !had.has(key(message)));
  for (const old of before) {
    if (!after.some((message) => message.t === old.t)) messages.push({ t: "un" + old.t });
  }
  return messages;
}

/// `storage`: { get(key), set(key, value), remove(key) }, each may be async.
/// `onState(state, extra)`: "connecting", "pairing" { code }, "unpaired" { note }, "ok" { mac },
/// "lost", "off". `onMessage(message)`: everything the Mac says once connected.
export function createLink({ origin, WebSocket, fetch, storage, timers = globalThis, now = () => Date.now(), onState, onMessage, name = "Even G2" }) {
  let token = null;
  let socket = null;
  let ready = false;
  let attempt = 0;
  let timer = null;
  let pinger = null;
  let lastHeard = 0;
  let stopped = false;
  let subscriptions = [];
  /// Bumped whenever pairing starts over, so an old wait's answer is dropped.
  let pairing = 0;

  const later = (work, ms) => {
    timers.clearTimeout(timer);
    timer = timers.setTimeout(() => { timer = null; if (!stopped) work(); }, ms);
  };
  const backoff = () => BACKOFF[Math.min(attempt++, BACKOFF.length - 1)];

  async function post(path, body) {
    const response = await fetch(origin + "/glasses/api/" + path, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    let data = {};
    try { data = await response.json(); } catch { /* not ours */ }
    return { status: response.status, ok: response.ok, data };
  }

  async function keep(value) {
    token = value;
    try { if (value) await storage.set(TOKEN_KEY, value); else await storage.remove(TOKEN_KEY); } catch { /* kept for this run at least */ }
  }

  // MARK: Pairing

  /// A code from a scanned QR: traded for a token once.
  async function pairWithCode(code) {
    try {
      const reply = await post("pair", { code, name });
      if (reply.ok && reply.data.token) { await keep(reply.data.token); connect(); return; }
      if (reply.status === 404) { onState("off"); later(begin, BACKOFF[4]); return; }
      onState("unpaired", { note: reply.data.error || "That code didn't work." });
      later(askToPair, PAIR_RETRY);
    } catch {
      onState("lost");
      later(() => pairWithCode(code), backoff());
    }
  }

  /// No code: ask the Mac, show the number it gives, and wait for Approve there.
  async function askToPair() {
    const round = ++pairing;
    try {
      const reply = await post("pair-request", { name });
      if (round !== pairing || stopped) return;
      if (reply.ok && reply.data.ticket) {
        attempt = 0;
        onState("pairing", { code: String(reply.data.code ?? "") });
        later(() => waitForApproval(reply.data.ticket, round), PAIR_POLL);
      } else if (reply.status === 404) {
        onState("off");
        later(askToPair, BACKOFF[4]);
      } else {
        onState("unpaired", { note: "" });
        later(askToPair, PAIR_RETRY);
      }
    } catch {
      if (round !== pairing || stopped) return;
      onState("lost");
      later(askToPair, backoff());
    }
  }

  async function waitForApproval(ticket, round) {
    try {
      const reply = await post("pair-wait", { ticket });
      if (round !== pairing || stopped) return;
      const state = reply.data.state;
      if (state === "approved" && reply.data.token) { await keep(reply.data.token); connect(); return; }
      if (state === "waiting") { later(() => waitForApproval(ticket, round), PAIR_POLL); return; }
      onState("unpaired", { note: state === "denied" ? "Denied on your Mac." : "" });
      later(askToPair, PAIR_RETRY);
    } catch {
      if (round !== pairing || stopped) return;
      // The Mac went away mid-wait; the ticket may still be good when it's back.
      later(() => waitForApproval(ticket, round), PAIR_POLL * 2);
    }
  }

  // MARK: The socket

  function connect() {
    if (stopped || socket) return;
    if (!token) { askToPair(); return; }
    let mine;
    try { mine = new WebSocket(socketURL(origin)); } catch { dropped(null); return; }
    socket = mine;
    ready = false;
    mine.binaryType = "arraybuffer";
    mine.onopen = () => {
      if (socket !== mine) return;
      lastHeard = now();
      mine.send(JSON.stringify({ t: "hello", token, client: "glasses", v: 1 }));
    };
    mine.onmessage = (event) => {
      if (socket !== mine || typeof event.data !== "string") return;
      lastHeard = now();
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      if (!message || typeof message !== "object") return;
      if (message.t === "hello") {
        if (message.glasses === false) { onState("off"); mine.close(); return; }
        ready = true;
        attempt = 0;
        onState("ok", { mac: message.mac });
        for (const wanted of subscriptions) mine.send(JSON.stringify(wanted));
        startPinging();
      } else if (message.t === "error" && message.code === "unpaired") {
        // Removed on the Mac: the token is no use any more.
        socket = null;
        mine.close();
        keep(null).then(() => { onState("unpaired", { note: "This was unpaired on your Mac." }); later(askToPair, 500); });
      } else if (message.t === "error" && message.code === "off") {
        onState("off");
        mine.close();
      } else if (message.t !== "pong") {
        onMessage(message);
      }
    };
    mine.onclose = () => dropped(mine);
    mine.onerror = () => { /* a close follows */ };
  }

  function dropped(which) {
    if (which && socket !== which) return;
    const wasReady = ready;
    socket = null;
    ready = false;
    timers.clearInterval(pinger);
    pinger = null;
    if (stopped || !token) return;
    if (wasReady) attempt = 0;
    probe();
    later(connect, backoff());
  }

  /// Why the socket won't open: glasses turned off on the Mac, or the Mac not there at all.
  async function probe() {
    try {
      const response = await fetch(origin + "/glasses/api/ping");
      if (socket || stopped) return;
      onState(response.status === 404 ? "off" : "lost");
    } catch {
      if (!socket && !stopped) onState("lost");
    }
  }

  function startPinging() {
    timers.clearInterval(pinger);
    pinger = timers.setInterval(() => {
      if (!socket) return;
      // Nothing for a while, not even an answer to a ping: the connection is dead without having said so.
      if (now() - lastHeard > SILENCE_LIMIT) { socket.close(); dropped(socket); return; }
      try { socket.send(JSON.stringify({ t: "ping" })); } catch { /* a close follows */ }
    }, PING_EVERY);
  }

  async function begin(code) {
    onState("connecting");
    if (code) { pairWithCode(code); return; }
    if (!token) {
      try { token = (await storage.get(TOKEN_KEY)) || null; } catch { token = null; }
    }
    connect();
  }

  return {
    /// Starts: with a pairing code from a scanned QR if there is one, else the stored token,
    /// else by asking the Mac to pair.
    start(code) { stopped = false; return begin(code); },
    stop() {
      stopped = true;
      timers.clearTimeout(timer);
      timers.clearInterval(pinger);
      const mine = socket;
      socket = null;
      ready = false;
      if (mine) mine.close();
    },
    get connected() { return ready; },
    /// Sends a message; false when there's no connection to send it on.
    send(message) {
      if (!ready || !socket) return false;
      try { socket.send(JSON.stringify(message)); return true; } catch { return false; }
    },
    sendAudio(bytes) {
      if (!ready || !socket) return false;
      try { socket.send(bytes); return true; } catch { return false; }
    },
    /// What the Mac should keep sending; asked for again after every reconnect.
    subscribe(wanted) {
      const changes = subscriptionChanges(subscriptions, wanted);
      subscriptions = wanted;
      if (ready && socket) for (const message of changes) socket.send(JSON.stringify(message));
    },
    /// The app came back to the front: don't wait out a backoff, and ask for everything again.
    wake() {
      if (stopped) return;
      if (ready && socket) {
        for (const wanted of subscriptions) socket.send(JSON.stringify(wanted));
      } else if (!socket && token) {
        attempt = 0;
        later(connect, 0);
      }
    },
  };
}
