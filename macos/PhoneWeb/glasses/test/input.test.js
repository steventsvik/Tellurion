import assert from "node:assert/strict";
import { test } from "node:test";
import { PROMPT_GUARD, createDebouncer, createUI, normalizeEvent, spokenCommand, step, subscriptions } from "../input.js";
import { withLink, withMessage } from "../model.js";
import { render } from "../screens.js";
import { ADA, CY, OTTO, ada, agents, connected, cy, otto } from "./helpers.js";

const NOW = 1_000_000;
const quiet = () => connected([otto(), cy()]);

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

const top = (ui) => ui.stack[ui.stack.length - 1];
const click = { type: "click" };
const double = { type: "double" };
const up = { type: "up" };
const down = { type: "down" };

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
  // A list's first row comes without its index.
  assert.deepEqual(normalizeEvent({ listEvent: { eventType: undefined } }), { type: "click", index: 0 });
  assert.deepEqual(normalizeEvent({ listEvent: { currentSelectItemIndex: 2 } }), { type: "click", index: 2 });
  assert.equal(normalizeEvent({ sysEvent: { imuData: { x: 1 } } }), null);
  assert.equal(normalizeEvent({ sysEvent: { eventType: 8 } }), null);
  assert.equal(normalizeEvent({}), null);
  assert.equal(normalizeEvent(null), null);
  const pcm = new Uint8Array([1, 2]);
  assert.deepEqual(normalizeEvent({ audioEvent: { audioPcm: pcm } }), { type: "audio", pcm });
});

test("repeats are dropped", () => {
  const fresh = createDebouncer();
  assert.equal(fresh(up, 0), true);
  assert.equal(fresh(up, 100), false);
  assert.equal(fresh(down, 150), true);
  assert.equal(fresh(up, 500), true);
  assert.equal(fresh(click, 600), true);
  assert.equal(fresh(click, 650), false, "one tap on two channels");
  assert.equal(fresh(click, 900), true);
  assert.equal(fresh({ type: "release" }, 901), true);
});

test("double-tap closes the app on Home and goes back everywhere else", () => {
  const model = quiet();
  assert.deepEqual(run(createUI(), model, [double]).fx, ["exit"]);
  const inAgent = run(createUI(), model, [click]);
  assert.equal(top(inAgent.ui).name, "agent");
  const actions = run(inAgent.ui, model, [click]);
  assert.equal(top(actions.ui).name, "actions");
  const back = run(actions.ui, model, [double]);
  assert.equal(top(back.ui).name, "agent");
  assert.deepEqual(back.fx, []);
  const home = run(back.ui, model, [double]);
  assert.equal(top(home.ui).name, "home");
  assert.deepEqual(home.fx, []);
});

test("swipes move the choice on Home and a tap opens it", () => {
  const model = quiet();
  const moved = run(createUI(), model, [down]);
  assert.equal(moved.ui.sel, "a:" + CY);
  assert.equal(run(moved.ui, model, [down, down]).ui.sel, "a:" + CY, "stops at the last row");
  const opened = run(moved.ui, model, [click]);
  assert.deepEqual(top(opened.ui), { name: "agent", id: CY, page: 0 });
  assert.deepEqual(subscriptions(opened.ui).at(-1), { t: "tail", id: CY, lines: 30 });
  assert.deepEqual(subscriptions(createUI()), [{ t: "glance" }, { t: "orch" }]);
});

test("the chosen row survives the list changing under it", () => {
  let model = quiet();
  const ui = run(createUI(), model, [down]).ui;
  // A new agent sorts in above, and another line changes.
  model = withMessage(model, agents([otto({ id: "new", name: "Zed" }), otto({ task: "Something else" }), cy()], NOW), NOW);
  const after = step(ui, model, { type: "model" }, NOW).ui;
  assert.equal(after.sel, "a:" + CY);
  assert.match(render(after, model, NOW).containers[1].text, /> ★ Cy/);
  assert.deepEqual(top(run(after, model, [click]).ui), { name: "agent", id: CY, page: 0 });
});

test("a new permission prompt comes up over what's there, and a tap allows it", () => {
  const ui = run(createUI(), quiet(), [click]).ui;
  const model = connected();
  const shown = step(ui, model, { type: "model" }, NOW).ui;
  assert.deepEqual(shown.prompt, { id: ADA, prompt: "p-ada-1", at: NOW });
  const allowed = run(shown, model, [click], NOW + PROMPT_GUARD + 1);
  assert.deepEqual(allowed.out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
  assert.equal(allowed.ui.prompt, null, "answered: it doesn't come back while the Mac still lists it");
  assert.equal(top(allowed.ui).name, "agent", "and you're back where you were");
  const denied = run(shown, model, [double], NOW + PROMPT_GUARD + 1);
  assert.deepEqual(denied.out, [{ t: "answer", id: ADA, allow: false, prompt: "p-ada-1" }]);
});

test("a tap already on its way when the prompt appears doesn't answer it", () => {
  const model = connected();
  const shown = step(createUI(), model, { type: "model" }, NOW).ui;
  const early = run(shown, model, [click, double], NOW + 300);
  assert.deepEqual(early.out, []);
  assert.ok(early.ui.prompt);
});

test("a stale prompt is never answered", () => {
  const shown = step(createUI(), connected(), { type: "model" }, NOW).ui;
  // The agent moved on to another command before the tap landed and before the screen caught up.
  const moved = connected([ada({ detail: "Bash: git push --force", prompt: "p-ada-2", since: 990 })]);
  const tapped = step(shown, moved, click, NOW + 5000);
  assert.deepEqual(tapped.out, []);
  // The new prompt is shown as a new one, with its own wait before taps count.
  assert.deepEqual(tapped.ui.prompt, { id: ADA, prompt: "p-ada-2", at: NOW + 5000 });
  assert.deepEqual(step(tapped.ui, moved, click, NOW + 5100).out, []);
  // And from the menu: it was opened for the first prompt.
  const menu = { ...createUI(), stack: [{ name: "home" }, { name: "agent", id: ADA, page: 0 }, { name: "actions", id: ADA, sel: "allow", prompt: "p-ada-1" }], later: ["p-ada-2"] };
  const fromMenu = step(menu, moved, click, NOW);
  assert.deepEqual(fromMenu.out, []);
  assert.equal(fromMenu.ui.flash.text, "That prompt is gone");
  // Gone altogether: the prompt screen closes by itself.
  assert.equal(step(shown, quiet(), { type: "model" }, NOW).ui.prompt, null);
});

test("a swipe puts a prompt off, and the next one waiting comes up", () => {
  const second = otto({ act: "permission", detail: "Edit: main.swift", prompt: "p-otto-1" });
  const model = connected([ada(), second]);
  const first = step(createUI(), model, { type: "model" }, NOW).ui;
  const next = step(first, model, down, NOW + 2000).ui;
  assert.deepEqual(next.later, ["p-ada-1"]);
  assert.equal(next.prompt.id, OTTO);
  const none = step(next, model, up, NOW + 4000).ui;
  assert.equal(none.prompt, null);
  // Still answerable from the agent's own menu.
  const menu = run(none, model, [click, click]);
  assert.equal(top(menu.ui).name, "actions");
  assert.deepEqual(run(menu.ui, model, [click]).out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
});

test("hold to talk: nothing is sent until the tap after it's heard", () => {
  const model = quiet();
  const ui = run(createUI(), model, [click]).ui;
  const held = run(ui, model, [{ type: "long" }]);
  assert.deepEqual(held.fx, ["listen"]);
  assert.equal(held.ui.voice.phase, "listening");
  const released = run(held.ui, model, [{ type: "release" }]);
  assert.deepEqual(released.fx, ["stop"]);
  const heard = run(released.ui, model, [{ type: "heard", text: "run the", final: false }, { type: "heard", text: "run the tests", final: true }]);
  assert.equal(heard.ui.voice.phase, "heard");
  assert.deepEqual(heard.out, []);
  assert.deepEqual(run(heard.ui, model, [up, down, { type: "release" }, { type: "long" }]).out, []);
  const sent = run(heard.ui, model, [click]);
  assert.deepEqual(sent.out, [{ t: "say", id: OTTO, text: "run the tests" }]);
  assert.equal(sent.ui.voice, null);
  const cancelled = run(heard.ui, model, [double]);
  assert.deepEqual(cancelled.out, []);
  assert.equal(cancelled.ui.voice, null);
  assert.equal(top(cancelled.ui).name, "agent");
});

test("Talk to it: a tap starts, a tap stops, a tap sends", () => {
  const model = quiet();
  const menu = run(createUI(), model, [click, click]).ui;
  assert.equal(top(menu).sel, "talk");
  const talking = run(menu, model, [click]);
  assert.deepEqual(talking.fx, ["listen"]);
  assert.equal(talking.ui.voice.via, "tap");
  const stopped = run(talking.ui, model, [click]);
  assert.deepEqual(stopped.fx, ["stop"]);
  const sent = run(stopped.ui, model, [{ type: "heard", text: "try again", final: true }, click]);
  assert.deepEqual(sent.out, [{ t: "say", id: OTTO, text: "try again" }]);
  assert.deepEqual(run(talking.ui, model, [double]).fx, ["cancel"]);
});

test("on the orchestrator's screen speech goes to the orchestrator", () => {
  const model = connected([otto()], NOW, [{ id: "p1", name: "shop", status: "Idle", log: [] }]);
  const ui = run(createUI(), model, [down, click]).ui;
  assert.deepEqual(top(ui), { name: "orch", id: "p1", page: 0 });
  const sent = run(ui, model, [click, click, { type: "heard", text: "ship the release", final: true }, click]);
  assert.deepEqual(sent.out, [{ t: "orchcmd", id: "p1", text: "ship the release" }]);
});

test("a prompt never appears over speech, where a tap means send", () => {
  const ui = run(createUI(), quiet(), [click, { type: "long" }, { type: "release" }, { type: "heard", text: "hello", final: true }]).ui;
  const model = connected([ada(), otto(), cy()]);
  const during = step(ui, model, { type: "model" }, NOW).ui;
  assert.equal(during.prompt, null);
  const sent = step(during, model, click, NOW + 100);
  assert.deepEqual(sent.out, [{ t: "say", id: OTTO, text: "hello" }]);
  // Once the speech is done the prompt comes up, with its own wait.
  assert.deepEqual(sent.ui.prompt, { id: ADA, prompt: "p-ada-1", at: NOW + 100 });
  assert.deepEqual(step(sent.ui, model, click, NOW + 300).out, []);
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

function sayOnHome(model, words, ui = createUI()) {
  const start = { ...ui, prompt: null, later: model.agents.filter((a) => a.prompt).map((a) => a.prompt) };
  return run(start, model, [{ type: "long" }, { type: "release" }, { type: "heard", text: words, final: true }]);
}

test("saying allow only brings up a single waiting prompt, which still needs its tap", () => {
  const model = connected();
  const said = sayOnHome(model, "allow");
  assert.deepEqual(said.out, [], "saying it sends nothing");
  assert.equal(said.ui.prompt.id, ADA);
  assert.deepEqual(step(said.ui, model, click, said.ui.prompt.at + 100).out, [], "not right away either");
  assert.deepEqual(step(said.ui, model, click, said.ui.prompt.at + PROMPT_GUARD + 1).out, [{ t: "answer", id: ADA, allow: true, prompt: "p-ada-1" }]);
  // "deny" brings up the same screen; the double-tap there is what denies.
  const deny = sayOnHome(model, "deny");
  assert.deepEqual(deny.out, []);
  assert.deepEqual(step(deny.ui, model, double, deny.ui.prompt.at + PROMPT_GUARD + 1).out, [{ t: "answer", id: ADA, allow: false, prompt: "p-ada-1" }]);
});

test("saying allow does nothing with two prompts waiting, or none", () => {
  const two = connected([ada(), otto({ act: "permission", detail: "Edit", prompt: "p-otto-1" })]);
  const said = sayOnHome(two, "allow");
  assert.deepEqual(said.out, []);
  assert.equal(said.ui.prompt, null);
  assert.equal(said.ui.flash.text, "More than one is waiting");
  const none = sayOnHome(quiet(), "allow");
  assert.deepEqual(none.out, []);
  assert.equal(none.ui.flash.text, "Nothing is waiting");
});

test("other things said on Home move around or are turned away, never sent", () => {
  const model = quiet();
  assert.deepEqual(top(sayOnHome(model, "open cy").ui), { name: "agent", id: CY, page: 0 });
  assert.equal(sayOnHome(model, "next").ui.sel, "a:" + CY);
  const other = sayOnHome(model, "delete the repository");
  assert.deepEqual(other.out, []);
  assert.equal(other.ui.flash.text, "Say it on an agent's screen");
  assert.equal(sayOnHome(model, "open nobody").ui.flash.text, "No agent called nobody");
});

test("nothing is sent while the connection is down", () => {
  const down_ = withLink(connected(), "lost", NOW);
  const ui = { ...createUI(), prompt: { id: ADA, prompt: "p-ada-1", at: 0 } };
  const result = run(ui, down_, [click, double, { type: "long" }]);
  assert.deepEqual(result.out, []);
  assert.deepEqual(result.fx, []);
});

test("speech that's never answered doesn't leave the screen stuck", () => {
  const model = quiet();
  const waiting = run(createUI(), model, [click, { type: "long" }, { type: "release" }]);
  const late = step(waiting.ui, model, { type: "tick" }, waiting.now + 20_000);
  assert.equal(late.ui.voice.phase, "error");
  assert.equal(step(late.ui, model, click, waiting.now + 21_000).ui.voice, null);
  // The Mac couldn't recognize speech at all.
  const failed = run(waiting.ui, model, [{ type: "heard", error: "Turn on Speech Recognition for Tellurion." }]);
  assert.equal(failed.ui.voice.phase, "error");
  assert.deepEqual(failed.out, []);
  // Put away mid-sentence: the microphone is let go.
  const listening = run(createUI(), model, [{ type: "long" }]);
  const gone = run(listening.ui, model, [{ type: "abnormal" }]);
  assert.deepEqual(gone.fx, ["cancel"]);
  assert.equal(gone.ui.voice, null);
});

test("a screen for an agent that's gone closes", () => {
  const ui = run(createUI(), quiet(), [click, click]).ui;
  const after = step(ui, connected([cy()]), { type: "model" }, NOW).ui;
  assert.deepEqual(after.stack, [{ name: "home" }]);
});
