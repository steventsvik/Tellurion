import assert from "node:assert/strict";
import { test } from "node:test";
import { BACKOFF, PAIR_POLL, PAIR_RETRY, TOKEN_KEY, createLink, pairingCode, resolveOrigin, socketURL, subscriptionChanges } from "../link.js";

test("the Mac's address is the page's own, or the one packed in", () => {
  const served = { protocol: "https:", host: "mac.tail.ts.net:8443" };
  assert.deepEqual(resolveOrigin("", served), { origin: "https://mac.tail.ts.net:8443", packaged: false });
  assert.deepEqual(resolveOrigin(undefined, { protocol: "http:", host: "127.0.0.1:47811" }), { origin: "http://127.0.0.1:47811", packaged: false });
  // Packaged: the page's own address is the Even app's, and isn't used.
  assert.deepEqual(resolveOrigin("https://mac.tail.ts.net/", { protocol: "file:", host: "" }), { origin: "https://mac.tail.ts.net", packaged: true });
  assert.deepEqual(resolveOrigin("https://mac.tail.ts.net:8443", served), { origin: "https://mac.tail.ts.net:8443", packaged: true });
  // Nothing usable packed in, and no address of its own.
  assert.equal(resolveOrigin("", { protocol: "file:", host: "" }), null);
  assert.equal(resolveOrigin("http://plain.example", { protocol: "app:", host: "x" }), null);
  assert.equal(resolveOrigin("https://mac.example/path?x=1", null), null);
  assert.equal(socketURL("https://mac.tail.ts.net:8443"), "wss://mac.tail.ts.net:8443/glasses/ws");
  assert.equal(socketURL("http://127.0.0.1:47811"), "ws://127.0.0.1:47811/glasses/ws");
});

test("a pairing code is read from a scanned address", () => {
  assert.equal(pairingCode({ hash: "#pair=K7QM-2XRD", search: "" }), "K7QM-2XRD");
  assert.equal(pairingCode({ hash: "", search: "?pair=ABCD-EFGH" }), "ABCD-EFGH");
  assert.equal(pairingCode({ hash: "#other=1", search: "" }), null);
  assert.equal(pairingCode(undefined), null);
});

test("subscriptions are sent when new and stopped when dropped", () => {
  const home = [{ t: "glance" }, { t: "orch" }];
  const agent = [...home, { t: "tail", id: "a", lines: 30 }];
  assert.deepEqual(subscriptionChanges([], home), home);
  assert.deepEqual(subscriptionChanges(home, agent), [{ t: "tail", id: "a", lines: 30 }]);
  assert.deepEqual(subscriptionChanges(agent, [...home, { t: "tail", id: "b", lines: 30 }]), [{ t: "tail", id: "b", lines: 30 }]);
  assert.deepEqual(subscriptionChanges(agent, home), [{ t: "untail" }]);
});

// A clock, timers and sockets that only move when the test says.
function world({ token = null, replies = {} } = {}) {
  let now = 0;
  let nextTimer = 1;
  const timers = new Map();
  const sockets = [];
  const states = [];
  const messages = [];
  const posts = [];
  const store = new Map(token ? [[TOKEN_KEY, token]] : []);
  class FakeSocket {
    constructor(url) { this.url = url; this.sent = []; this.closed = false; sockets.push(this); }
    send(data) { this.sent.push(typeof data === "string" ? JSON.parse(data) : data); }
    close() { if (!this.closed) { this.closed = true; this.onclose?.(); } }
    open() { this.onopen?.(); }
    say(message) { this.onmessage?.({ data: JSON.stringify(message) }); }
  }
  const fetch = async (url, options) => {
    const path = url.replace("https://mac.example", "");
    posts.push({ path, body: options?.body ? JSON.parse(options.body) : null });
    const reply = typeof replies[path] === "function" ? replies[path]() : replies[path];
    if (!reply) throw new Error("unreachable");
    return { status: reply.status ?? 200, ok: (reply.status ?? 200) < 300, json: async () => reply.body ?? {} };
  };
  const link = createLink({
    origin: "https://mac.example", WebSocket: FakeSocket, fetch, now: () => now,
    storage: { get: async (key) => store.get(key) ?? null, set: async (key, value) => { store.set(key, value); }, remove: async (key) => { store.delete(key); } },
    timers: {
      setTimeout: (work, ms) => { timers.set(nextTimer, { at: now + ms, work }); return nextTimer++; },
      clearTimeout: (id) => timers.delete(id),
      setInterval: (work, ms) => { timers.set(nextTimer, { at: now + ms, work, every: ms }); return nextTimer++; },
      clearInterval: (id) => timers.delete(id),
    },
    onState: (state, extra) => states.push(extra?.code ? state + ":" + extra.code : state),
    onMessage: (message) => messages.push(message),
  });
  const settle = async () => { for (let i = 0; i < 20; i += 1) await Promise.resolve(); };
  /// Moves the clock on, running what comes due.
  const advance = async (ms) => {
    const end = now + ms;
    for (;;) {
      await settle();
      const due = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      const [id, timer] = due;
      now = Math.max(now, timer.at);
      if (timer.every) timer.at += timer.every; else timers.delete(id);
      timer.work();
    }
    now = end;
    await settle();
  };
  return { link, sockets, states, messages, posts, store, advance, settle };
}

test("the stored token is sent first, and what the screen needs is asked for after hello", async () => {
  const w = world({ token: "secret" });
  w.link.subscribe([{ t: "glance" }, { t: "orch" }]);
  await w.link.start();
  await w.settle();
  const socket = w.sockets[0];
  assert.equal(socket.url, "wss://mac.example/glasses/ws");
  assert.equal(w.link.send({ t: "say" }), false, "nothing goes out before hello");
  socket.open();
  assert.deepEqual(socket.sent, [{ t: "hello", token: "secret", client: "glasses", v: 1 }]);
  socket.say({ t: "hello", mac: "Studio", v: 1, glasses: true });
  assert.deepEqual(socket.sent.slice(1), [{ t: "glance" }, { t: "orch" }]);
  assert.deepEqual(w.states, ["connecting", "ok"]);
  socket.say({ t: "agents", agents: [] });
  socket.say({ t: "pong" });
  assert.deepEqual(w.messages, [{ t: "agents", agents: [] }]);
  assert.equal(w.link.send({ t: "say", id: "a", text: "hi" }), true);
  w.link.subscribe([{ t: "glance" }, { t: "orch" }, { t: "tail", id: "a", lines: 30 }]);
  assert.deepEqual(socket.sent.at(-1), { t: "tail", id: "a", lines: 30 });
});

test("a dropped connection comes back by itself, slower each time, and asks again", async () => {
  const w = world({ token: "secret" });
  w.link.subscribe([{ t: "glance" }]);
  await w.link.start();
  await w.settle();
  w.sockets[0].open();
  w.sockets[0].say({ t: "hello", glasses: true });
  w.sockets[0].close();
  await w.settle();
  assert.equal(w.states.at(-1), "lost", "the Mac can't be reached at all");
  assert.equal(w.link.send({ t: "say" }), false);
  await w.advance(BACKOFF[0]);
  assert.equal(w.sockets.length, 2);
  w.sockets[1].close();
  await w.advance(BACKOFF[1] - 1);
  assert.equal(w.sockets.length, 2, "the second wait is longer");
  await w.advance(1);
  assert.equal(w.sockets.length, 3);
  w.sockets[2].open();
  w.sockets[2].say({ t: "hello", glasses: true });
  assert.equal(w.states.at(-1), "ok");
  assert.deepEqual(w.sockets[2].sent, [{ t: "hello", token: "secret", client: "glasses", v: 1 }, { t: "glance" }]);
});

test("glasses turned off on the Mac is told apart from a Mac that's away", async () => {
  const w = world({ token: "secret", replies: { "/glasses/api/ping": { status: 404 } } });
  await w.link.start();
  await w.settle();
  w.sockets[0].close();
  await w.settle();
  assert.equal(w.states.at(-1), "off");
});

test("a connection that goes silent is dropped and remade", async () => {
  const w = world({ token: "secret" });
  await w.link.start();
  await w.settle();
  w.sockets[0].open();
  w.sockets[0].say({ t: "hello", glasses: true });
  await w.advance(70_000);
  assert.equal(w.sockets[0].closed, true);
  assert.ok(w.sockets[0].sent.some((message) => message.t === "ping"));
  assert.ok(w.sockets.length >= 2);
});

test("a scanned code is traded for a token, which is kept", async () => {
  const w = world({ replies: { "/glasses/api/pair": { body: { token: "fresh", mac: "Studio" } } } });
  await w.link.start("K7QM-2XRD");
  await w.settle();
  assert.deepEqual(w.posts[0], { path: "/glasses/api/pair", body: { code: "K7QM-2XRD", name: "Even G2" } });
  assert.equal(w.store.get(TOKEN_KEY), "fresh");
  w.sockets[0].open();
  assert.equal(w.sockets[0].sent[0].token, "fresh");
});

test("with no token it asks the Mac, shows the number, and connects once approved", async () => {
  let waits = 0;
  const w = world({
    replies: {
      "/glasses/api/pair-request": { body: { ticket: "t-1", code: "4821", expires: 120 } },
      "/glasses/api/pair-wait": () => ({ body: (waits += 1) < 3 ? { state: "waiting" } : { state: "approved", token: "granted" } }),
    },
  });
  await w.link.start();
  await w.settle();
  assert.deepEqual(w.states, ["connecting", "pairing:4821"]);
  assert.equal(w.sockets.length, 0);
  await w.advance(PAIR_POLL * 3);
  assert.equal(w.store.get(TOKEN_KEY), "granted");
  assert.deepEqual(w.posts.filter((p) => p.path.endsWith("pair-wait")).map((p) => p.body), [{ ticket: "t-1" }, { ticket: "t-1" }, { ticket: "t-1" }]);
  w.sockets[0].open();
  assert.equal(w.sockets[0].sent[0].token, "granted");
});

test("while the Mac isn't taking requests it says not paired and keeps asking", async () => {
  let open = false;
  const w = world({
    replies: {
      "/glasses/api/pair-request": () => (open ? { body: { ticket: "t", code: "0042" } } : { status: 403, body: { code: "closed" } }),
      "/glasses/api/pair-wait": { body: { state: "denied" } },
    },
  });
  await w.link.start();
  await w.settle();
  assert.equal(w.states.at(-1), "unpaired");
  open = true;
  await w.advance(PAIR_RETRY);
  assert.equal(w.states.at(-1), "pairing:0042");
  await w.advance(PAIR_POLL);
  assert.equal(w.states.at(-1), "unpaired", "denied on the Mac");
  assert.equal(w.store.has(TOKEN_KEY), false);
});

test("a Mac that's away while unpaired is reported as unreachable, and tried again", async () => {
  const w = world();
  await w.link.start();
  await w.settle();
  assert.equal(w.states.at(-1), "lost");
  await w.advance(BACKOFF[0]);
  assert.equal(w.posts.filter((p) => p.path.endsWith("pair-request")).length, 2);
});

test("a token removed on the Mac is forgotten, and pairing starts over", async () => {
  const w = world({ token: "old", replies: { "/glasses/api/pair-request": { status: 403 } } });
  await w.link.start();
  await w.settle();
  w.sockets[0].open();
  w.sockets[0].say({ t: "error", code: "unpaired" });
  await w.advance(600);
  assert.equal(w.store.has(TOKEN_KEY), false);
  assert.equal(w.states.at(-1), "unpaired");
  assert.equal(w.sockets.length, 1, "it doesn't reconnect with a token that's no good");
});
