import assert from "node:assert/strict";
import { test } from "node:test";
import { MOST_IN_PLACE, containerPayload, createGlass, layoutKey, plan } from "../glass.js";
import { createUI } from "../input.js";
import { render } from "../screens.js";
import { ADA, OTTO, ada, connected, otto, screen, shopOrchestrator } from "./helpers.js";

const HEAD = { id: 1, name: "head", x: 0, y: 0, w: 576, h: 44 };
const BODY = { id: 2, name: "body", x: 0, y: 44, w: 576, h: 244 };
const LIST = { id: 3, name: "list", x: 0, y: 44, w: 576, h: 244 };

const page = (top, body, color = 4) => ({
  key: "x",
  containers: [{ ...HEAD, type: "text", text: top, color, capture: false }, { ...BODY, type: "text", text: body, color, capture: true }],
});
/// A page of `count` lines, each a container of its own.
const rows = (texts) => ({
  key: "rows",
  containers: texts.map((text, i) => ({ id: i + 1, name: "row" + i, x: 0, y: i * 30, w: 576, h: 30, type: "text", text, color: 4, capture: i === 0, rank: texts.length - i })),
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

test("text changes in place, the most urgent first; a change of scene with a lot to change rebuilds", () => {
  const before = rows(["a", "b", "c", "d", "e"]);
  const few = plan(before, rows(["a", "B", "C", "d", "e"]));
  assert.equal(few.op, "upgrade");
  assert.deepEqual(few.changes.map((c) => c.name), ["row2", "row1"], "by rank");
  // However much changes, a page in the same scene is never rebuilt.
  assert.equal(plan(before, rows(["A", "B", "C", "D", "E"])).changes.length, 5);
  const elsewhere = (texts) => ({ ...rows(texts), scene: "pane" });
  assert.deepEqual(plan(before, elsewhere(["A", "B", "C", "d", "e"])), { op: "rebuild" });
  assert.equal(plan(before, elsewhere(["a", "B", "C", "d", "e"])).changes.length, MOST_IN_PLACE);
});

test("moving through a list never rebuilds the page; going in or out redraws it once", () => {
  const NOW = 1_000_000;
  const model = screen(screen(connected([ada(), otto()], NOW, [shopOrchestrator()]), ADA, "ada's screen"), OTTO, "otto's screen");
  const at = (sel, stack = []) => render({ ...createUI(), sel, stack }, model, NOW);
  const step = plan(at("p:" + ADA), at("p:" + OTTO));
  assert.equal(step.op, "upgrade");
  // The cursor first, then the title, the prompt's box and the short look.
  assert.deepEqual(step.changes.map((c) => c.name), ["sidehi", "head", "box", "pane"]);
  for (const [from, to] of [["g:p1", "p:" + ADA], ["p:" + OTTO, "tools"], ["tools", "g:p1"]]) {
    assert.notEqual(plan(at(from), at(to)).op, "rebuild", from + " to " + to);
  }
  // Every screen you go into has one shape; browsing has another.
  const term = (id, extra = {}) => ({ name: "term", id, before: 0, off: 0, trail: [], menu: null, later: null, ...extra });
  const orch = (extra = {}) => ({ name: "orch", id: "p1", sel: null, menu: null, confirm: null, ...extra });
  const inOtto = at("p:" + OTTO, [term(OTTO)]);
  assert.notEqual(layoutKey(at("p:" + OTTO)), layoutKey(inOtto));
  assert.equal(plan(at("p:" + OTTO), inOtto).op, "rebuild");
  assert.equal(layoutKey(inOtto), layoutKey(at("o:p1", [orch()])));
  assert.equal(layoutKey(inOtto), layoutKey(at("tools", [{ name: "tools", sel: null, confirm: false }])));
  // Inside: a menu, a swipe through the team, are text in place.
  assert.equal(plan(inOtto, at("p:" + OTTO, [term(OTTO, { menu: { sel: "talk" } })])).op, "upgrade");
  const moved = plan(at("o:p1", [orch({ sel: "goal" })]), at("o:p1", [orch({ sel: "m:" + OTTO })]));
  assert.equal(moved.op, "upgrade");
  assert.equal(moved.changes[0].name, "bodyhi", "the cursor first");
  // From the orchestrator into one of its agents: one redraw, not a call per line.
  assert.equal(plan(at("o:p1", [orch()]), at("o:p1", [orch(), term(OTTO)])).op, "rebuild");
});

test("the page is described as the bridge takes it", () => {
  const payload = containerPayload(listPage(["one", "two"]));
  assert.equal(payload.containerTotalNum, 2);
  assert.equal(payload.textObject[0].isEventCapture + payload.listObject[0].isEventCapture, 1);
  assert.deepEqual(payload.listObject[0].itemContainer.itemName, ["one", "two"]);
  assert.equal(payload.textObject[0].content, "top");
  assert.equal(payload.menuObject, undefined);
  // Borders, and the rows for the glasses' own menu, which goes with every page that has one.
  const main = containerPayload(render(createUI(), connected(), 1_000_000));
  assert.equal(main.containerTotalNum, 7);
  assert.equal(containerPayload(render({ ...createUI(), stack: [{ name: "ruler" }] }, connected(), 1_000_000)).containerTotalNum, 6);
  assert.equal(main.textObject.filter((c) => c.isEventCapture === 1).length, 1);
  assert.deepEqual(main.textObject.find((c) => c.containerName === "evt"), {
    xPosition: 0, yPosition: 0, width: 576, height: 288, containerID: 1, containerName: "evt",
    borderWidth: 0, borderColor: 0, borderRadius: 0, paddingLength: 0, isEventCapture: 1, content: " ", textColor: 0,
  });
  assert.equal(main.textObject.find((c) => c.containerName === "pane").borderWidth, 1);
  assert.deepEqual(main.menuObject.menuItems[0], { itemID: 1, itemName: "Talk" });
  assert.ok(main.textObject.every((c) => c.containerName.length <= 16));
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

test("several changes go one call at a time, and a newer page takes over in between", async () => {
  const bridge = fakeBridge();
  const glass = createGlass({ bridge });
  glass.show(rows(["a", "b", "c", "d"]));
  await idle();
  glass.show(rows(["a", "B", "C", "d"]));
  await idle();
  assert.deepEqual(bridge.calls, ["create", "upgrade", "upgrade"]);
  assert.equal(bridge.most, 1);
  // Two more changes wanted, then only one of them: the other is never sent.
  const sent = [];
  const watched = fakeBridge({ upgrade: (change) => { sent.push(change.content); return true; } });
  const second = createGlass({ bridge: watched });
  second.show(rows(["a", "b", "c", "d"]));
  await idle();
  second.show(rows(["a", "b", "C", "D"]));
  second.show(rows(["a", "b", "c", "D"]));
  await idle();
  assert.deepEqual(sent, ["D"], "the last row is the most urgent here; the other was only wanted in between");
  assert.deepEqual(second.shown.containers.map((c) => c.text), ["a", "b", "c", "D"]);
});

test("a page the glasses cleared is set again whole", async () => {
  const bridge = fakeBridge();
  const glass = createGlass({ bridge });
  glass.redraw();
  glass.show(page("a", "1"));
  await idle();
  glass.redraw();
  await idle();
  assert.deepEqual(bridge.calls, ["create", "rebuild"]);
  assert.equal(glass.shown.containers[1].text, "1");
});

test("the page is only ever made once, even when making it fails", async () => {
  let failures = 2;
  const bridge = fakeBridge({ create: () => 1, rebuild: () => { if (failures-- > 0) throw new Error("not yet"); return true; } });
  const timers = { setTimeout: (work, ms) => setTimeout(work, Math.min(ms, 5)), clearTimeout };
  const glass = createGlass({ bridge, timers, onError: () => {} });
  glass.show(page("a", "1"));
  await idle();
  assert.equal(bridge.calls.filter((name) => name === "create").length, 1);
  assert.equal(bridge.calls.filter((name) => name === "rebuild").length, 3);
  assert.equal(glass.shown.containers[1].text, "1");
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
