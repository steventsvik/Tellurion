import assert from "node:assert/strict";
import { test } from "node:test";
import { KEYS, MAX_BEFORE, PROMPT_GUARD, createDebouncer, createUI, normalizeEvent, spokenCommand, step, subscriptions } from "../input.js";
import { withLink, withMessage } from "../model.js";
import { FULL_LINES, OS_MENU, render, topScreen } from "../screens.js";
import {
  ADA, CY, MISSION_PAGE, OTTO, REVIEW_PAGE, SEARCH_PAGE, TOOLS, ZSH, ada, agents, connected, cy, otto, part, screen, shopOrchestrator, zsh,
} from "./helpers.js";

const NOW = 1_000_000;
/// Rows: shop, Otto, site, Cy, Tools.
const quiet = () => connected([otto(), cy()]);
/// The same with shop's orchestrator and the Mac's tools.
const team = (list = [ada(), otto(), cy()]) => withMessage(connected(list, NOW, [shopOrchestrator()]), TOOLS, NOW);

/// Runs events one after another; returns the last state and everything that was sent or asked for.
function run(ui, model, events, start = NOW) {
  const out = [];
  const fx = [];
  let now = start;
  for (const event of events) {
    if (event.wait) { now += event.wait; continue; }
    const result = step(ui, model, event, now);
    ui = result.ui;
    out.push(...result.out);
    fx.push(...result.fx.map((effect) => effect.fx));
    now += 400;
  }
  return { ui, out, fx, now };
}

const on = (sel, extra = {}) => ({ ...createUI(), sel, ...extra });
const term = (id, extra = {}) => ({ name: "term", id, before: 0, off: 0, trail: [], menu: null, later: null, ...extra });
const orch = (extra = {}) => ({ name: "orch", id: "p1", sel: null, menu: null, confirm: null, ...extra });
const tool = (id, extra = {}) => ({ name: "tool", id, sel: null, menu: null, confirm: null, ...extra });
const tools = (extra = {}) => ({ name: "tools", sel: null, confirm: false, ...extra });
/// Inside a tab's terminal, come from its row.
const inTerm = (id, extra = {}, more = {}) => on("p:" + id, { stack: [term(id, extra)], ...more });
const within = (...stack) => on("tools", { stack });
const names = (ui) => ui.stack.map((entry) => entry.name);
const click = { type: "click" };
const double = { type: "double" };
const up = { type: "up" };
const down = { type: "down" };
const hold = { type: "long" };
const release = { type: "release" };
const heard = (text) => ({ type: "heard", text, final: true });

test("events from the glasses are read wherever they arrive", () => {
  assert.deepEqual(normalizeEvent({ textEvent: { eventType: undefined } }), { type: "click" });
  assert.deepEqual(normalizeEvent({ textEvent: { eventType: 0 } }), { type: "click" });
  assert.deepEqual(normalizeEvent({ sysEvent: {} }), { type: "click" });
  assert.deepEqual(normalizeEvent({ sysEvent: { eventType: 3 } }), { type: "double" });
  assert.deepEqual(normalizeEvent({ textEvent: { eventType: 1 } }), { type: "up" });
  assert.deepEqual(normalizeEvent({ textEvent: { eventType: 2 } }), { type: "down" });
  assert.deepEqual(normalizeEvent({ sysEvent: { eventType: 9 } }), { type: "long" });
  assert.deepEqual(normalizeEvent({ sysEvent: { eventType: 10 } }), { type: "release" });
  assert.deepEqual(normalizeEvent({ sysEvent: { eventType: 4 } }), { type: "foreground" });
  assert.deepEqual(normalizeEvent({ sysEvent: { eventType: 6 } }), { type: "abnormal" });
  assert.deepEqual(normalizeEvent({ listEvent: { eventType: undefined } }), { type: "click", index: 0 });
  assert.deepEqual(normalizeEvent({ listEvent: { currentSelectItemIndex: 2 } }), { type: "click", index: 2 });
  assert.deepEqual(normalizeEvent({ menuItemClickEvent: { itemID: 3 } }), { type: "menu", id: 3 });
  assert.equal(normalizeEvent({ sysEvent: { imuData: { x: 1 } } }), null);
  assert.equal(normalizeEvent({ sysEvent: { eventType: 8 } }), null);
  assert.equal(normalizeEvent({}), null);
  assert.equal(normalizeEvent(null), null);
  const pcm = new Uint8Array([1, 2]);
  assert.deepEqual(normalizeEvent({ audioEvent: { audioPcm: pcm } }), { type: "audio", pcm });
});

test("repeats are dropped, and swipes keep a cooldown whichever way they go", () => {
  const fresh = createDebouncer();
  assert.equal(fresh(up, 0), true);
  assert.equal(fresh(up, 100), false);
  assert.equal(fresh(down, 150), false, "a swipe reported back the other way");
  assert.equal(fresh(down, 320), true);
  assert.equal(fresh(click, 710), true);
  assert.equal(fresh(click, 760), false, "one tap on two channels");
  assert.equal(fresh(click, 1000), true);
  assert.equal(fresh(double, 1010), true);
  assert.equal(fresh(release, 1011), true);
  assert.equal(fresh(release, 1012), true);
});

// MARK: Getting around

test("swipes move the choice through the sidebar and the short look follows", () => {
  const model = quiet();
  const start = step(createUI(), model, { type: "model" }, NOW).ui;
  assert.equal(start.sel, "g:p1", "the first row is the choice to begin with");
  assert.deepEqual(start.stack, []);
  const moved = run(start, model, [down]);
  assert.equal(moved.ui.sel, "p:" + OTTO);
  assert.deepEqual(subscriptions(moved.ui).at(-1), { t: "tail", id: OTTO, lines: 40, src: "screen", before: 0 });
  assert.equal(part(render(moved.ui, screen(model, OTTO, "otto's screen"), NOW), "pane").text, "Task: Write the tests\n\notto's screen");
  assert.equal(run(moved.ui, model, [down, down, down, down, down]).ui.sel, "tools", "stops at the last row");
  assert.equal(run(moved.ui, model, [up, up, up]).ui.sel, "g:p1", "and at the first");
  assert.deepEqual(subscriptions(start), [{ t: "glance" }, { t: "orch" }, { t: "tools" }]);
  assert.deepEqual(run(start, model, [down, down, up, down, down]).out, [], "moving around sends nothing");
});

test("a tap goes in, a double-tap comes back out one level, and only browsing closes the app", () => {
  const model = withMessage(team(), MISSION_PAGE, NOW);
  // A tab: its terminal over the whole display, and back to the same row.
  const inside = run(on("p:" + OTTO), model, [click]);
  assert.deepEqual(inside.ui.stack, [term(OTTO)]);
  assert.equal(render(inside.ui, model, NOW).key, "term");
  const menu = run(inside.ui, model, [click]);
  assert.deepEqual(topScreen(menu.ui).menu, { sel: "talk" });
  const closed = run(menu.ui, model, [double]);
  assert.equal(topScreen(closed.ui).menu, null);
  assert.deepEqual(names(closed.ui), ["term"]);
  const back = run(closed.ui, model, [double]);
  assert.deepEqual(back.ui.stack, []);
  assert.equal(back.ui.sel, "p:" + OTTO);
  assert.deepEqual([...inside.fx, ...menu.fx, ...closed.fx, ...back.fx], [], "never the exit from inside");
  assert.deepEqual(run(back.ui, model, [double]).fx, ["exit"]);
  // The orchestrator, then one of its agents: back to the orchestrator, then to browsing.
  const deep = run(on("o:p1"), model, [click, down, down, click]);
  assert.deepEqual(names(deep.ui), ["orch", "term"]);
  assert.equal(topScreen(deep.ui).id, ADA);
  const out1 = run(deep.ui, model, [{ wait: 5000 }, up, double]);
  assert.deepEqual(names(out1.ui), ["orch"]);
  assert.equal(topScreen(out1.ui).sel, "m:" + ADA, "with the same agent chosen");
  assert.deepEqual(run(out1.ui, model, [double]).ui.stack, []);
  // Tools, a tool's page, an agent from that page: three levels, three double-taps.
  const far = run(on("tools"), model, [click, click, click]);
  assert.deepEqual(names(far.ui), ["tools", "tool", "term"]);
  const home = run(far.ui, model, [{ wait: 5000 }, up, double, double, double]);
  assert.deepEqual(home.ui.stack, []);
  assert.deepEqual([...deep.fx, ...out1.fx, ...far.fx, ...home.fx], []);
  assert.deepEqual([...deep.out, ...far.out, ...home.out], [], "getting around sends nothing");
});

test("the chosen row survives the rows changing; a screen about something gone closes", () => {
  let model = quiet();
  const ui = on("p:" + CY, { at: 3 });
  model = withMessage(model, agents([otto({ id: "new", name: "Zed" }), otto({ task: "Something else" }), cy()], NOW), NOW);
  const after = step(ui, model, { type: "model" }, NOW).ui;
  assert.equal(after.sel, "p:" + CY);
  // Its tab closes while you're in it, menu open: back to browsing, on the row now in its place.
  const gone = step(inTerm(CY, { menu: { sel: "talk" } }, { at: 4 }), connected([otto(), otto({ id: "new", name: "Zed" })]), { type: "model" }, NOW).ui;
  assert.deepEqual(gone.stack, []);
  assert.equal(gone.sel, "tools");
  // An agent opened from its orchestrator closes: back on the orchestrator.
  const from = on("o:p1", { stack: [orch({ sel: "m:" + ADA }), term(ADA)] });
  assert.deepEqual(names(step(from, team([otto(), cy()]), { type: "model" }, NOW).ui), ["orch"]);
  // The project loses its orchestrator: its screen and everything over it close.
  assert.deepEqual(step(on("o:p1", { stack: [orch(), { name: "log", id: "p1", off: 0 }] }), quiet(), { type: "model" }, NOW).ui.stack, []);
});

test("a tap on a project folds and unfolds it", () => {
  const model = team();
  const folded = run(on("g:p1"), model, [click]);
  assert.deepEqual(folded.ui.folded, ["p1"]);
  assert.deepEqual(folded.ui.stack, [], "a project has nothing to go into");
  assert.equal(run(folded.ui, model, [down]).ui.sel, "g:p2");
  const open = run(folded.ui, model, [click]);
  assert.deepEqual(open.ui.folded, []);
  assert.equal(run(open.ui, model, [down]).ui.sel, "o:p1");
  assert.deepEqual([...folded.out, ...open.out, ...folded.fx, ...open.fx], []);
});

test("a choice kept from last time waits for the Mac to say who's there", () => {
  const kept = on("p:" + CY, { folded: ["p1"] });
  let model = withLink(connected([]), "ok", NOW);
  model = { ...model, seen: { agents: false, orch: false } };
  assert.equal(step(kept, model, { type: "model" }, NOW).ui.sel, "p:" + CY);
  assert.equal(step(kept, quiet(), { type: "model" }, NOW).ui.sel, "p:" + CY);
  assert.deepEqual(step(kept, quiet(), { type: "model" }, NOW).ui.folded, ["p1"]);
});

// MARK: Speech

test("hold talks to whatever is chosen, straight from the sidebar", () => {
  const model = team([ada(), otto(), cy(), zsh()]);
  const target = (sel) => run(on(sel), model, [hold]);
  assert.deepEqual(target("p:" + OTTO).ui.voice.target, { kind: "agent", id: OTTO, name: "Otto" });
  assert.deepEqual(target("p:" + OTTO).fx, ["listen"]);
  assert.deepEqual(target("p:" + OTTO).ui.stack, [], "without going in");
  assert.deepEqual(target("o:p1").ui.voice.target, { kind: "orch", id: "p1", name: "the orchestrator" });
  assert.deepEqual(target("g:p1").ui.voice.target, { kind: "orch", id: "p1", name: "the orchestrator" });
  assert.deepEqual(target("tools").ui.voice.target, { kind: "home", id: "", name: "Tellurion" });
  const none = target("g:p2");
  assert.equal(none.ui.voice, null);
  assert.equal(none.ui.flash.text, "No agents in this project");
  const shell = target("p:" + ZSH);
  assert.equal(shell.ui.voice, null);
  assert.deepEqual(shell.fx, []);
  assert.equal(shell.ui.flash.text, "No agent there to talk to");
  // Inside a plain terminal too.
  assert.equal(run(inTerm(ZSH), model, [hold]).ui.voice, null);
});

test("hold to talk: nothing is sent until the tap after it's heard", () => {
  const model = quiet();
  for (const start of [on("p:" + OTTO), inTerm(OTTO), inTerm(OTTO, { menu: { sel: "key:tab" } })]) {
    const held = run(start, model, [hold]);
    assert.deepEqual(held.fx, ["listen"]);
    assert.deepEqual(held.ui.voice.target, { kind: "agent", id: OTTO, name: "Otto" });
    const released = run(held.ui, model, [release]);
    assert.deepEqual(released.fx, ["stop"]);
    const said = run(released.ui, model, [{ type: "heard", text: "run the", final: false }, heard("run the tests")]);
    assert.equal(said.ui.voice.phase, "heard");
    assert.deepEqual(said.out, []);
    assert.deepEqual(run(said.ui, model, [up, down, release, hold]).out, []);
    assert.equal(run(said.ui, model, [up, down]).ui.sel, "p:" + OTTO, "swipes don't move the choice meanwhile");
    const sent = run(said.ui, model, [click]);
    assert.deepEqual(sent.out, [{ t: "say", id: OTTO, text: "run the tests" }]);
    assert.equal(sent.ui.voice, null);
    assert.deepEqual(names(sent.ui), names(start), "and you stay where you were");
    const cancelled = run(said.ui, model, [double]);
    assert.deepEqual(cancelled.out, []);
    assert.deepEqual(cancelled.fx, [], "cancelling isn't the exit, nor a step back");
    assert.deepEqual(names(cancelled.ui), names(start));
  }
});

test("Talk in the menu: a tap starts, a tap stops, a tap sends", () => {
  const model = quiet();
  const menu = run(inTerm(OTTO), model, [click]).ui;
  const talking = run(menu, model, [click]);
  assert.deepEqual(talking.fx, ["listen"]);
  assert.equal(talking.ui.voice.via, "tap");
  const stopped = run(talking.ui, model, [click]);
  assert.deepEqual(stopped.fx, ["stop"]);
  assert.deepEqual(run(stopped.ui, model, [heard("try again"), click]).out, [{ t: "say", id: OTTO, text: "try again" }]);
  assert.deepEqual(run(talking.ui, model, [double]).fx, ["cancel"]);
});

test("speech that's never answered doesn't leave the screen stuck", () => {
  const model = quiet();
  const waiting = run(on("p:" + OTTO), model, [hold, release]);
  const late = step(waiting.ui, model, { type: "tick" }, waiting.now + 20_000);
  assert.equal(late.ui.voice.phase, "error");
  assert.equal(step(late.ui, model, click, waiting.now + 21_000).ui.voice, null);
  const failed = run(waiting.ui, model, [{ type: "heard", error: "Turn on Speech Recognition for Tellurion." }]);
  assert.equal(failed.ui.voice.phase, "error");
  assert.deepEqual(failed.out, []);
  const gone = run(run(on("p:" + OTTO), model, [hold]).ui, model, [{ type: "abnormal" }]);
  assert.deepEqual(gone.fx, ["cancel"]);
  assert.equal(gone.ui.voice, null);
});

test("spoken commands are matched whole", () => {
  assert.deepEqual(spokenCommand("Allow."), { command: "allow" });
  assert.deepEqual(spokenCommand(" deny "), { command: "deny" });
  assert.deepEqual(spokenCommand("Open Ada"), { command: "open", name: "ada" });
  assert.deepEqual(spokenCommand("orchestrator"), { command: "orchestrator" });
  assert.equal(spokenCommand("allow it all"), null);
  assert.equal(spokenCommand("please allow"), null);
  assert.equal(spokenCommand("don't allow"), null);
  assert.equal(spokenCommand("delete everything"), null);
  assert.equal(spokenCommand(""), null);
});

function sayAtTools(model, words, extra = {}) {
  return run(on("tools", extra), model, [hold, release, heard(words)]);
}

test("saying allow only brings the one waiting prompt into view, which still needs its tap", () => {
  const model = connected();
  const said = sayAtTools(model, "allow", { folded: ["p1"] });
  assert.deepEqual(said.out, [], "saying it sends nothing");
  assert.equal(said.ui.sel, "p:" + ADA);
  assert.deepEqual(said.ui.stack, [term(ADA)]);
  assert.deepEqual(said.ui.folded, [], "its project is unfolded for it");
  assert.deepEqual(step(said.ui, model, click, said.ui.seen.at + 100).out, [], "not right away either");
  assert.deepEqual(step(said.ui, model, click, said.ui.seen.at + PROMPT_GUARD + 1).out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
  const deny = sayAtTools(model, "deny");
  assert.deepEqual(deny.out, []);
  assert.deepEqual(step(deny.ui, model, double, deny.ui.seen.at + PROMPT_GUARD + 1).out, [{ t: "answer", id: ADA, allow: false, prompt: "p-ada-1" }]);
});

test("saying allow does nothing with two prompts waiting, or none", () => {
  const two = connected([ada(), otto({ act: "permission", detail: "Edit", prompt: "p-otto-1" })]);
  const said = sayAtTools(two, "allow");
  assert.deepEqual(said.out, []);
  assert.deepEqual(said.ui.stack, []);
  assert.equal(said.ui.flash.text, "More than one is waiting");
  const none = sayAtTools(quiet(), "allow");
  assert.deepEqual(none.out, []);
  assert.equal(none.ui.flash.text, "Nothing is waiting");
});

test("other things said at Tools move around or are turned away, never sent", () => {
  const model = team([otto(), cy()]);
  const opened = sayAtTools(model, "open cy");
  assert.equal(opened.ui.sel, "p:" + CY);
  assert.deepEqual(opened.ui.stack, [term(CY)]);
  assert.deepEqual(names(sayAtTools(model, "orchestrator").ui), ["orch"]);
  assert.equal(sayAtTools(connected([ada(), otto()]), "next").ui.sel, "p:" + ADA);
  const other = sayAtTools(model, "delete the repository");
  assert.deepEqual(other.out, []);
  assert.equal(other.ui.flash.text, "Say it on an agent's row");
  assert.equal(sayAtTools(model, "open nobody").ui.flash.text, "Nothing called nobody");
  assert.deepEqual([...opened.out, ...sayAtTools(model, "next").out], []);
});

// MARK: Permission prompts

test("a prompt is answered from inside its own terminal: tap allows, double-tap denies", () => {
  const model = connected();
  const entered = run(on("p:" + ADA), model, [click]);
  assert.deepEqual(entered.out, []);
  assert.deepEqual(names(entered.ui), ["term"]);
  assert.deepEqual(entered.ui.seen, { key: ADA + "\np-ada-1", at: NOW });
  const allowed = run(entered.ui, model, [click], NOW + PROMPT_GUARD + 1);
  assert.deepEqual(allowed.out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
  assert.deepEqual(names(allowed.ui), ["term"], "and you stay where you were");
  // Answered: it isn't offered again while the Mac still lists it.
  assert.deepEqual(run(allowed.ui, model, [{ wait: 5000 }, click, click]).out, []);
  const denied = run(entered.ui, model, [double], NOW + PROMPT_GUARD + 1);
  assert.deepEqual(denied.out, [{ t: "answer", id: ADA, allow: false, prompt: "p-ada-1" }]);
  assert.deepEqual(denied.fx, []);
  assert.deepEqual(names(denied.ui), ["term"], "denying isn't going back");
});

test("taps anywhere else never answer a prompt, however long it has been there", () => {
  const model = withMessage(team(), MISSION_PAGE, NOW);
  // Browsing, with the prompt in the short look.
  const ui = step(on("p:" + ADA), model, { type: "model" }, NOW).ui;
  assert.equal(ui.seen, null);
  const result = run(ui, model, [{ wait: 60_000 }, double]);
  assert.deepEqual(result.out, []);
  assert.deepEqual(result.fx, ["exit"]);
  // In another tab's terminal.
  assert.deepEqual(run(inTerm(OTTO), model, [{ wait: 60_000 }, click, click, double]).out, []);
  // On the orchestrator's screen, where it shows as a banner: a tap opens Ada's terminal, no more.
  const banner = step(on("o:p1", { stack: [orch()] }), model, { type: "model" }, NOW).ui;
  assert.equal(topScreen(banner).sel, "ask:" + ADA, "the banner takes the cursor");
  const opened = run(banner, model, [{ wait: 60_000 }, click]);
  assert.deepEqual(opened.out, []);
  assert.deepEqual(names(opened.ui), ["orch", "term"]);
  // There it has only just come into view: the tap right behind doesn't answer it.
  assert.deepEqual(run(opened.ui, model, [click, double], opened.now).out, []);
  assert.deepEqual(run(opened.ui, model, [{ wait: PROMPT_GUARD + 1 }, click], opened.now).out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
  // On a tool's page that lists it.
  const listed = run(within(tools(), tool("mission")), model, [{ wait: 60_000 }, double]);
  assert.deepEqual(listed.out, []);
  assert.deepEqual(names(listed.ui), ["tools"]);
});

test("a tap already on its way when the prompt appears doesn't answer it", () => {
  const before = connected([ada({ act: "working", prompt: undefined, detail: undefined }), otto()]);
  const waiting = step(inTerm(ADA), before, { type: "model" }, NOW).ui;
  const model = connected();
  const shown = step(waiting, model, { type: "model" }, NOW + 5000).ui;
  assert.deepEqual(shown.seen, { key: ADA + "\np-ada-1", at: NOW + 5000 });
  const early = run(shown, model, [click, double], NOW + 5300);
  assert.deepEqual(early.out, []);
  assert.deepEqual(names(early.ui), ["term"]);
  assert.equal(topScreen(early.ui).menu, null);
  assert.equal(step(shown, model, click, NOW + 5000 + PROMPT_GUARD).out.length, 1);
});

test("a menu that's open closes when its agent asks for permission", () => {
  const before = connected([ada({ act: "working", prompt: undefined, detail: undefined })]);
  const menu = run(inTerm(ADA), before, [click, down]).ui;
  assert.deepEqual(topScreen(menu).menu, { sel: "key:enter" });
  const model = connected([ada()]);
  const shown = step(menu, model, { type: "model" }, NOW + 5000);
  assert.equal(topScreen(shown.ui).menu, null);
  // The tap meant for "Enter" lands on the prompt's wait, and presses nothing.
  assert.deepEqual(step(shown.ui, model, click, NOW + 5200).out, []);
});

test("a stale prompt is never answered", () => {
  const shown = run(on("p:" + ADA), connected(), [click]).ui;
  const moved = connected([ada({ detail: "Bash: git push --force", prompt: "p-ada-2", since: 990 })]);
  const tapped = step(shown, moved, click, NOW + 5000);
  assert.deepEqual(tapped.out, []);
  assert.deepEqual(tapped.ui.seen, { key: ADA + "\np-ada-2", at: NOW + 5000 });
  assert.deepEqual(step(tapped.ui, moved, click, NOW + 5100).out, []);
  assert.deepEqual(step(tapped.ui, moved, click, NOW + 5000 + PROMPT_GUARD).out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-2" }]);
  const quietNow = connected([ada({ act: "working", prompt: undefined, detail: undefined })]);
  const after = run(shown, quietNow, [{ wait: 5000 }, click]);
  assert.deepEqual(after.out, []);
  assert.deepEqual(topScreen(after.ui).menu, { sel: "talk" });
});

test("a swipe puts a prompt off: scrolled back, a double-tap just goes back", () => {
  const model = screen(connected(), ADA, Array.from({ length: 30 }, (_, i) => "line " + i).join("\n"));
  const entered = run(on("p:" + ADA), model, [click]).ui;
  const scrolled = run(entered, model, [{ wait: 5000 }, up]);
  assert.ok(topScreen(scrolled.ui).off > 0);
  assert.equal(scrolled.ui.seen, null);
  assert.equal(part(render(scrolled.ui, model, NOW), "box").text, "");
  const back = run(scrolled.ui, model, [{ wait: 5000 }, double]);
  assert.deepEqual(back.out, []);
  assert.deepEqual(back.ui.stack, []);
  // With nothing to read back, the swipe still puts it off.
  const bare = run(run(on("p:" + ADA), connected(), [click]).ui, connected(), [{ wait: 5000 }, up]);
  assert.equal(bare.ui.seen, null);
  const left = run(bare.ui, connected(), [{ wait: 5000 }, double]);
  assert.deepEqual(left.out, []);
  assert.deepEqual(left.ui.stack, []);
  assert.deepEqual(run(bare.ui, connected(), [down]).ui.seen?.key, ADA + "\np-ada-1");
  const again = run(scrolled.ui, model, [down], NOW + 20_000);
  assert.equal(topScreen(again.ui).off, 0);
  assert.deepEqual(again.ui.seen, { key: ADA + "\np-ada-1", at: NOW + 20_000 });
  assert.deepEqual(step(again.ui, model, click, NOW + 20_100).out, []);
  assert.deepEqual(step(again.ui, model, click, NOW + 22_000).out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
});

test("a prompt is never answered by a tap meant for speech", () => {
  const before = connected([ada({ act: "working", prompt: undefined, detail: undefined }), otto()]);
  const ui = run(inTerm(ADA), before, [hold, release, heard("hello")]).ui;
  const model = connected([ada(), otto()]);
  const during = step(ui, model, { type: "model" }, NOW + 5000).ui;
  assert.equal(during.seen, null);
  const sent = step(during, model, click, NOW + 9000);
  assert.deepEqual(sent.out, [{ t: "say", id: ADA, text: "hello" }]);
  assert.deepEqual(sent.ui.seen, { key: ADA + "\np-ada-1", at: NOW + 9000 });
  assert.deepEqual(step(sent.ui, model, click, NOW + 9300).out, []);
  assert.deepEqual(step(sent.ui, model, double, NOW + 9300).out, []);
});

// MARK: Keys

test("keys go to an agent's pane, from the short list only", () => {
  const model = quiet();
  const menu = run(inTerm(OTTO), model, [click, down]);
  assert.deepEqual(topScreen(menu.ui).menu, { sel: "key:enter" });
  const pressed = run(menu.ui, model, [click]);
  assert.deepEqual(pressed.out, [{ t: "key", id: OTTO, key: "enter" }]);
  assert.deepEqual(topScreen(pressed.ui).menu, { sel: "key:enter" }, "the menu stays for the next key");
  assert.deepEqual(run(menu.ui, model, [down, down, click, down, click]).out, [{ t: "key", id: OTTO, key: "ctrl-c" }, { t: "key", id: OTTO, key: "up" }]);
  assert.deepEqual(KEYS, ["enter", "escape", "ctrl-c", "up", "down", "tab", "y", "n"]);
  for (const sel of ["key:backspace", "key:a", "key:ctrl-d", "key:", "key:Enter"]) {
    assert.deepEqual(run(inTerm(OTTO, { menu: { sel } }), model, [click]).out, [], sel);
  }
});

test("no key is pressed in a plain terminal or over a permission prompt", () => {
  const model = connected([ada(), otto(), zsh()]);
  const shell = run(inTerm(ZSH), model, [click]);
  assert.equal(topScreen(shell.ui).menu, null);
  for (const item of OS_MENU) {
    for (const start of [on("p:" + ZSH), inTerm(ZSH)]) {
      const result = run(start, model, [{ type: "menu", id: item.id }]);
      assert.deepEqual(result.out, [], item.name);
      assert.equal(result.ui.voice, null);
    }
  }
  assert.deepEqual(run(inTerm(ZSH, { menu: { sel: "key:enter" } }), model, [click]).out, []);
  // An agent asking for permission: Enter would allow it without saying which prompt.
  const enter = OS_MENU.find((item) => item.action === "key:enter");
  for (const start of [on("p:" + ADA), inTerm(ADA)]) {
    const asked = run(start, model, [{ wait: 5000 }, { type: "menu", id: enter.id }]);
    assert.deepEqual(asked.out, []);
    assert.equal(asked.ui.flash.text, "Answer its prompt instead");
  }
  assert.deepEqual(run(inTerm(ADA, { menu: { sel: "key:enter" } }), model, [{ wait: 5000 }, click]).out, []);
});

test("the glasses' own menu acts on the tab you're on or in", () => {
  const model = team([otto(), cy()]);
  const id = (action) => OS_MENU.find((item) => item.action === action).id;
  assert.deepEqual(run(on("p:" + OTTO), model, [{ type: "menu", id: id("key:escape") }]).out, [{ t: "key", id: OTTO, key: "escape" }]);
  assert.deepEqual(run(inTerm(CY), model, [{ type: "menu", id: id("key:escape") }]).out, [{ t: "key", id: CY, key: "escape" }]);
  assert.deepEqual(names(run(inTerm(OTTO), model, [{ type: "menu", id: id("output") }]).ui), ["term", "output"]);
  assert.deepEqual(names(run(on("g:p1"), model, [{ type: "menu", id: id("ruler") }]).ui), ["ruler"]);
  const talk = run(on("p:" + OTTO), model, [{ type: "menu", id: id("talk") }]);
  assert.equal(talk.ui.voice.via, "tap");
  // Not on a row or a screen that isn't a tab, and not while something is being said.
  assert.deepEqual(run(on("g:p1"), model, [{ type: "menu", id: id("key:enter") }]).out, []);
  assert.deepEqual(run(on("o:p1", { stack: [orch()] }), model, [{ type: "menu", id: id("key:enter") }]).out, []);
  assert.deepEqual(run(within(tools()), model, [{ type: "menu", id: id("key:enter") }]).out, []);
  assert.deepEqual(run(talk.ui, model, [{ type: "menu", id: id("key:enter") }]).out, []);
  assert.deepEqual(run(on("p:" + OTTO), model, [{ type: "menu", id: 99 }]).out, []);
});

// MARK: Reading a terminal

test("in a terminal a swipe reads back, then asks the Mac for older lines", () => {
  const text = Array.from({ length: 16 }, (_, i) => "line " + i).join("\n");
  let model = screen(quiet(), OTTO, text, { more: true });
  const first = run(inTerm(OTTO), model, [up]);
  assert.equal(topScreen(first.ui).off, FULL_LINES - 1);
  assert.match(part(render(first.ui, model, NOW), "body").text, /^line 3\n[\s\S]*line 9$/);
  const top = run(first.ui, model, [up]);
  assert.equal(topScreen(top.ui).off, 9, "stops at the top of what there is");
  const older = run(top.ui, model, [up]);
  assert.deepEqual(topScreen(older.ui), term(OTTO, { before: 16, off: 0, trail: [0] }));
  assert.deepEqual(subscriptions(older.ui).at(-1), { t: "tail", id: OTTO, lines: 40, src: "screen", before: 16 });
  // Until they come the terminal doesn't show the wrong lines.
  assert.equal(part(render(older.ui, model, NOW), "body").text, "...");
  model = screen(model, OTTO, "older a\nolder b", { before: 16, more: false });
  assert.equal(part(render(older.ui, model, NOW), "body").text, "older a\nolder b");
  assert.deepEqual(topScreen(run(older.ui, model, [up]).ui), topScreen(older.ui), "nothing older: it stays");
  const newer = run(older.ui, model, [down]);
  assert.equal(topScreen(newer.ui).before, 0);
  model = screen(model, OTTO, text, { more: true });
  assert.match(part(render(newer.ui, model, NOW), "body").text, /^line 0\n/);
  const bottom = run(newer.ui, model, [down, down, down]);
  assert.equal(topScreen(bottom.ui).off, 0);
  assert.match(part(render(bottom.ui, model, NOW), "body").text, /line 15$/);
  assert.deepEqual([...first.out, ...older.out, ...bottom.out], []);
  // Going in again starts at its end.
  assert.deepEqual(run(first.ui, model, [double, click]).ui.stack, [term(OTTO)]);
  const far = inTerm(OTTO, { before: MAX_BEFORE - 5, trail: [0] });
  const farModel = screen(model, OTTO, text, { before: MAX_BEFORE - 5, more: true });
  assert.equal(topScreen(run(far, farModel, [up, up, up, up]).ui).before, MAX_BEFORE - 5);
});

test("an agent's latest output opens over its terminal and closes with a tap", () => {
  const model = withMessage(quiet(), { t: "tail", id: OTTO, src: "answer", text: Array.from({ length: 20 }, (_, i) => "answer " + i).join("\n") }, NOW);
  const opened = run(inTerm(OTTO, { menu: { sel: "output" } }), model, [click]);
  assert.deepEqual(names(opened.ui), ["term", "output"]);
  assert.deepEqual(subscriptions(opened.ui).at(-1), { t: "tail", id: OTTO, lines: 30 });
  assert.equal(topScreen(run(opened.ui, model, [up]).ui).back, 1);
  assert.deepEqual(names(run(opened.ui, model, [double]).ui), ["term"]);
  assert.deepEqual(names(run(opened.ui, model, [click]).ui), ["term"]);
  assert.equal(run(opened.ui, model, [hold]).ui.voice, null);
});

// MARK: The orchestrator

test("the orchestrator's screen: swipes move through its rows, a tap opens the one chosen", () => {
  const model = team([ada({ act: "working", prompt: undefined, detail: undefined }), otto(), cy()]);
  const start = run(on("o:p1"), model, [click]);
  assert.deepEqual(names(start.ui), ["orch"]);
  // Rows: goal, Ada, Otto, latest, (last: only said). The goal is where it starts.
  const rows = [];
  let ui = start.ui;
  for (let i = 0; i < 6; i += 1) { ui = run(ui, model, [down]).ui; rows.push(topScreen(ui).sel); }
  assert.deepEqual(rows, ["m:" + ADA, "m:" + OTTO, "latest", "latest", "latest", "latest"], "the last line only says something");
  assert.deepEqual(names(run(ui, model, [click]).ui), ["orch", "log"]);
  const agent = run(start.ui, model, [down, down, click]);
  assert.deepEqual(agent.ui.stack.at(-1), term(OTTO));
  // Hold here, in the log, and from the agent opened from it.
  assert.deepEqual(run(start.ui, model, [hold]).ui.voice.target, { kind: "orch", id: "p1", name: "the orchestrator" });
  assert.deepEqual(run(ui, model, [click, hold]).ui.voice.target, { kind: "orch", id: "p1", name: "the orchestrator" });
  assert.deepEqual(run(agent.ui, model, [hold]).ui.voice.target, { kind: "agent", id: OTTO, name: "Otto" });
  const said = run(start.ui, model, [hold, release, heard("ship the release")]);
  assert.deepEqual(said.out, []);
  assert.deepEqual(run(said.ui, model, [click]).out, [{ t: "orchcmd", id: "p1", text: "ship the release" }]);
  assert.deepEqual(run(on("g:p1"), model, [hold, release, heard("stop"), click]).out, [{ t: "orchcmd", id: "p1", text: "stop" }]);
});

test("an agent that starts asking takes the orchestrator's cursor once, and not your menu", () => {
  const before = team([ada({ act: "working", prompt: undefined, detail: undefined }), otto()]);
  const calm = run(on("o:p1", { stack: [orch()] }), before, [down, down]).ui;
  assert.equal(topScreen(calm).sel, "m:" + OTTO);
  const model = team([ada(), otto()]);
  const asked = step(calm, model, { type: "model" }, NOW + 5000).ui;
  assert.equal(topScreen(asked).sel, "ask:" + ADA);
  // Moved away from it, it stays where you put it.
  const away = run(asked, model, [down, down]).ui;
  assert.equal(step(away, model, { type: "model" }, NOW + 9000).ui.stack[0].sel, topScreen(away).sel);
  // With the actions open, nothing moves under the tap.
  const menu = run(calm, before, [up, up, click]).ui;
  assert.deepEqual(topScreen(menu).menu, { sel: "stop" });
  const kept = step(menu, model, { type: "model" }, NOW + 5000).ui;
  assert.deepEqual(topScreen(kept).menu, { sel: "stop" });
  assert.equal(topScreen(kept).sel, "goal");
});

test("the orchestrator's actions are only sent by the tap that says yes", () => {
  const model = team([otto(), cy()]);
  const menu = run(on("o:p1", { stack: [orch()] }), model, [click]);
  assert.deepEqual(topScreen(menu.ui).menu, { sel: "stop" });
  assert.deepEqual(menu.out, []);
  const sent = {};
  for (const [moves, action, message] of [[0, "stop", "orchstop"], [1, "go", "orchgo"], [2, "wire", "orchwire"], [3, "clear", "orchclear"]]) {
    const asked = run(menu.ui, model, [...Array(moves).fill(down), click]);
    assert.equal(topScreen(asked.ui).confirm, action);
    assert.deepEqual(asked.out, [], action + " isn't sent by choosing it");
    assert.deepEqual(run(asked.ui, model, [up, down, hold, release]).out, []);
    const no = run(asked.ui, model, [double]);
    assert.deepEqual(no.out, []);
    assert.equal(topScreen(no.ui).confirm, null);
    const yes = run(asked.ui, model, [click]);
    assert.deepEqual(yes.out, [{ t: message, id: "p1" }]);
    assert.equal(topScreen(yes.ui).confirm, null);
    assert.deepEqual(run(yes.ui, model, [{ wait: 5000 }, down]).out, []);
    sent[action] = yes.out.length;
  }
  assert.deepEqual(Object.keys(sent), ["stop", "go", "wire", "clear"]);
  // A state that never went through the menu can't confirm something that isn't an action.
  assert.deepEqual(run(on("o:p1", { stack: [orch({ confirm: "delete" })] }), model, [click]).out, []);
});

// MARK: Tools

test("Tools: a tool with a page opens it, the others open on the Mac after being asked", () => {
  const model = team();
  const list = run(on("tools"), model, [click]);
  assert.deepEqual(names(list.ui), ["tools"]);
  const page = run(list.ui, model, [down, click]);
  assert.deepEqual(page.ui.stack.at(-1), tool("review"));
  assert.deepEqual(subscriptions(page.ui).at(-1), { t: "toolpage", id: "review" });
  assert.deepEqual(page.out, [], "opening a page here opens nothing on the Mac");
  // Skills has no page here.
  const asked = run(list.ui, model, [down, down, down, down, click]);
  assert.deepEqual(topScreen(asked.ui), tools({ sel: "skills", confirm: true }));
  assert.deepEqual(asked.out, []);
  assert.deepEqual(run(asked.ui, model, [up, down, hold]).out, []);
  assert.equal(topScreen(run(asked.ui, model, [up]).ui).sel, "skills", "the choice doesn't move under the question");
  const no = run(asked.ui, model, [double]);
  assert.deepEqual(no.out, []);
  assert.deepEqual(names(no.ui), ["tools"]);
  assert.deepEqual(run(asked.ui, model, [click]).out, [{ t: "tool", id: "skills" }]);
  // The display check is the glasses' own.
  assert.deepEqual(names(run(list.ui, model, [down, down, down, down, down, down, click]).ui), ["tools", "ruler"]);
  assert.deepEqual(subscriptions(list.ui), [{ t: "glance" }, { t: "orch" }, { t: "tools" }]);
});

test("a tool's page: actions are asked about, and only the yes sends them", () => {
  const model = withMessage(team(), REVIEW_PAGE, NOW);
  const start = within(tools({ sel: "review" }), tool("review"));
  const menu = run(start, model, [click]);
  assert.deepEqual(topScreen(menu.ui).menu, { sel: "feedback" });
  const asked = run(menu.ui, model, [down, click]);
  assert.equal(topScreen(asked.ui).confirm, "open");
  assert.deepEqual(asked.out, []);
  assert.deepEqual(run(asked.ui, model, [up, down, hold, double]).out, []);
  const yes = run(asked.ui, model, [click]);
  assert.deepEqual(yes.out, [{ t: "toolact", tool: "review", row: "r1", action: "open" }]);
  assert.deepEqual(names(yes.ui), ["tools", "tool"]);
  // The second row, with its one action.
  assert.deepEqual(run(start, model, [down, click, click, click]).out, [{ t: "toolact", tool: "review", row: "r2", action: "open" }]);
  // The row went away while the question was up: nothing is sent.
  const gone = withMessage(model, { ...REVIEW_PAGE, rows: [REVIEW_PAGE.rows[1]] }, NOW);
  const late = run(asked.ui, gone, [click]);
  assert.deepEqual(late.out, []);
  // An action the page doesn't offer can't be confirmed.
  assert.deepEqual(run(within(tools(), tool("review", { sel: "r2", confirm: "feedback" })), model, [click]).out, []);
  assert.deepEqual(run(within(tools(), tool("review", { sel: "r1", confirm: "accept-all" })), model, [click]).out, []);
  // Nor on a page that hasn't come.
  assert.deepEqual(run(within(tools(), tool("localhost", { confirm: "stop" })), model, [click]).out, []);
});

test("feedback by voice, and a spoken search, are sent by the tap after they're heard", () => {
  const model = withMessage(team(), REVIEW_PAGE, NOW);
  const talking = run(within(tools(), tool("review")), model, [click, click]);
  assert.deepEqual(talking.fx, ["listen"]);
  assert.deepEqual(talking.ui.voice.target, { kind: "tool", tool: "review", row: "r1", action: "feedback", name: "Otto" });
  const said = run(talking.ui, model, [click, heard("use the other test helper")]);
  assert.deepEqual(said.out, []);
  assert.deepEqual(run(said.ui, model, [double]).out, []);
  assert.deepEqual(run(said.ui, model, [click]).out, [{ t: "toolact", tool: "review", row: "r1", action: "feedback", text: "use the other test helper" }]);
  // A page that takes speech: hold, say it, tap.
  const search = withMessage(team(), SEARCH_PAGE, NOW);
  const asked = run(within(tools(), tool("search")), search, [hold, release, heard("login flow")]);
  assert.deepEqual(asked.out, []);
  assert.deepEqual(run(asked.ui, search, [click]).out, [{ t: "toolact", tool: "search", row: "", action: "query", text: "login flow" }]);
  // A page that doesn't: nothing to say.
  assert.equal(run(within(tools(), tool("review")), model, [hold]).ui.voice, null);
  assert.equal(run(within(tools()), model, [hold]).ui.voice, null);
});

test("a row of a tool's page can lead to a tab or an orchestrator, sending nothing", () => {
  const model = withMessage(team(), MISSION_PAGE, NOW);
  const start = within(tools(), tool("mission"));
  const agent = run(start, model, [click]);
  assert.deepEqual(agent.ui.stack.at(-1), term(ADA));
  const orchestrator = run(start, model, [down, click]);
  assert.deepEqual(names(orchestrator.ui), ["tools", "tool", "orch"]);
  const nothing = run(start, model, [down, down, click]);
  assert.deepEqual(names(nothing.ui), ["tools", "tool"]);
  assert.equal(topScreen(nothing.ui).menu, null);
  assert.deepEqual([...agent.out, ...orchestrator.out, ...nothing.out], []);
  // A tab that has closed since.
  const closed = withMessage(team([otto()]), MISSION_PAGE, NOW);
  assert.deepEqual(names(run(start, closed, [click]).ui), ["tools", "tool"]);
});

test("nothing is sent while the connection is down", () => {
  const lost = withLink(withMessage(team(), REVIEW_PAGE, NOW), "lost", NOW);
  const states = [
    inTerm(ADA, {}, { seen: { key: ADA + "\np-ada-1", at: 0 } }), inTerm(OTTO, { menu: { sel: "key:enter" } }),
    on("o:p1", { stack: [orch({ confirm: "stop" })] }), within(tools({ sel: "skills", confirm: true })), within(tools(), tool("review", { sel: "r1", confirm: "open" })),
    { ...inTerm(OTTO), voice: { phase: "heard", target: { kind: "agent", id: OTTO, name: "Otto" }, via: "hold", text: "hi", error: "", at: 0 } },
  ];
  for (const ui of states) {
    const result = run(ui, lost, [click, double, hold, { type: "menu", id: 2 }]);
    assert.deepEqual(result.out, []);
    assert.deepEqual(result.fx, []);
  }
});
