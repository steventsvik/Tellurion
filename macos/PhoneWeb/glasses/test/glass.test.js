import assert from "node:assert/strict";
import { test } from "node:test";
import { containerPayload, createGlass, plan } from "../glass.js";
import { BODY, HEAD, LIST } from "../screens.js";

const page = (top, body, color = 4) => ({
  key: "x",
  containers: [{ ...HEAD, type: "text", text: top, color, capture: false }, { ...BODY, type: "text", text: body, color, capture: true }],
});
const listPage = (items) => ({
  key: "l",
  containers: [{ ...HEAD, type: "text", text: "top", color: 4, capture: false }, { ...LIST, type: "list", items, selected: 0, capture: true }],
});

test("only what changed is sent", () => {
  assert.deepEqual(plan(null, page("a", "b")), { op: "create" });
  assert.deepEqual(plan(page("a", "b"), page("a", "b")), { op: "none" });
  const step = plan(page("a", "b"), page("a", "c"));
  assert.equal(step.op, "upgrade");
  assert.deepEqual(step.changes.map((c) => c.name), ["body"]);
  assert.equal(plan(page("a", "b"), page("a", "b", 1)).changes.length, 2, "dimming is a change in place too");
  assert.deepEqual(plan(page("a", "b"), listPage(["one"])), { op: "rebuild" });
  assert.deepEqual(plan(listPage(["one"]), listPage(["one", "two"])), { op: "rebuild" }, "a list can't be changed in place");
  assert.deepEqual(plan(listPage(["one"]), listPage(["one"])), { op: "none" });
});

test("the page is described as the bridge takes it", () => {
  const payload = containerPayload(listPage(["one", "two"]));
  assert.equal(payload.containerTotalNum, 2);
  assert.equal(payload.textObject[0].isEventCapture + payload.listObject[0].isEventCapture, 1);
  assert.deepEqual(payload.listObject[0].itemContainer.itemName, ["one", "two"]);
  assert.equal(payload.textObject[0].content, "top");
});

function fakeBridge(behaviour = {}) {
  const calls = [];
  let active = 0;
  let most = 0;
  const method = (name, fallback) => async (argument) => {
    calls.push(name);
    active += 1;
    most = Math.max(most, active);
    await new Promise((resolve) => setTimeout(resolve, 2));
    active -= 1;
    return behaviour[name] ? behaviour[name](argument, calls) : fallback;
  };
  return {
    calls,
    get most() { return most; },
    createStartUpPageContainer: method("create", 0),
    rebuildPageContainer: method("rebuild", true),
    textContainerUpgrade: method("upgrade", true),
    shutDownPageContainer: method("exit", true),
  };
}

const idle = () => new Promise((resolve) => setTimeout(resolve, 60));

test("one call at a time, the newest page winning", async () => {
  const bridge = fakeBridge();
  const shown = [];
  const glass = createGlass({ bridge, onShown: (p) => shown.push(p.containers[1].text) });
  glass.show(page("a", "1"));
  glass.show(page("a", "2"));
  glass.show(page("a", "3"));
  await idle();
  assert.equal(bridge.most, 1);
  assert.equal(bridge.calls[0], "create");
  assert.equal(shown.at(-1), "3");
  assert.ok(bridge.calls.length <= 3, "the page in between was skipped");
  assert.equal(glass.ready, true);
});

test("text changes go in place, without a rebuild", async () => {
  const bridge = fakeBridge();
  const glass = createGlass({ bridge });
  glass.show(page("a", "1"));
  await idle();
  glass.show(page("a", "2"));
  await idle();
  assert.deepEqual(bridge.calls, ["create", "upgrade"]);
});

test("a text update that fails falls back to a rebuild", async () => {
  const bridge = fakeBridge({ upgrade: () => false });
  const glass = createGlass({ bridge });
  glass.show(page("a", "1"));
  await idle();
  glass.show(page("a", "2"));
  await idle();
  assert.deepEqual(bridge.calls, ["create", "upgrade", "rebuild"]);
  assert.equal(glass.shown.containers[1].text, "2");
});

test("a page that's already there is rebuilt instead of made", async () => {
  const bridge = fakeBridge({ create: () => 1 });
  const glass = createGlass({ bridge });
  glass.show(page("a", "1"));
  await idle();
  assert.deepEqual(bridge.calls, ["create", "rebuild"]);
  assert.equal(glass.ready, true);
});

test("a call that throws is tried again later and doesn't block the next page", async () => {
  let fail = true;
  const errors = [];
  const bridge = fakeBridge({ create: () => { throw new Error("no glasses"); }, rebuild: () => { if (fail) throw new Error("still none"); return true; } });
  const timers = { setTimeout: (work, ms) => setTimeout(work, Math.min(ms, 20)), clearTimeout };
  const glass = createGlass({ bridge, timers, onError: (error) => errors.push(error.message) });
  glass.show(page("a", "1"));
  await idle();
  assert.equal(glass.shown, null);
  assert.ok(errors.length >= 1);
  fail = false;
  glass.show(page("a", "2"));
  await idle();
  assert.equal(glass.shown.containers[1].text, "2");
});

test("closing asks the glasses with mode 1", async () => {
  const seen = [];
  const bridge = fakeBridge({ exit: (mode) => { seen.push(mode); return true; } });
  await createGlass({ bridge }).exit();
  assert.deepEqual(seen, [1]);
});
