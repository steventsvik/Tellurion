import assert from "node:assert/strict";
import { test } from "node:test";
import { bytes } from "../fit.js";
import { createUI } from "../input.js";
import { createModel, summary, withLink, withMessage } from "../model.js";
import { BODY_LINES, HINT_PROMPT, HINT_SEND, actionItems, agentLine, homeItems, menuText, plain, render } from "../screens.js";
import { ADA, ada, agents, connected, cy, otto } from "./helpers.js";

const NOW = 1_000_000;

function check(page) {
  assert.equal(page.containers.filter((c) => c.capture).length, 1, "exactly one container takes the input");
  assert.ok(page.containers.length <= 8);
  for (const c of page.containers) {
    assert.ok(c.x >= 0 && c.y >= 0 && c.x + c.w <= 576 && c.y + c.h <= 288);
    if (c.type === "text") assert.ok(bytes(c.text) <= 999);
    if (c.type === "list") for (const item of c.items) assert.ok(bytes(item) <= 63);
  }
  return page;
}

test("Home leads with who needs you, one agent a line", () => {
  const model = connected();
  assert.equal(summary(model), "1 needs you · 1 working");
  const page = check(render(createUI(), model, NOW));
  assert.equal(page.key, "home");
  assert.equal(page.containers[0].text, "1 needs you · 1 working");
  assert.equal(page.containers[1].text, [
    "> ● Ada: needs permission 1m",
    "   ▶ Otto: working 3m",
    "   ★ Cy: done · check failed",
  ].join("\n"));
});

test("an agent's line names its marks", () => {
  const model = connected();
  assert.equal(agentLine(model, otto({ budget: { f: 0.83, s: "warning" }, conflicts: 2 }), NOW), "▶ Otto: working 3m · budget 83% · 2 conflicts");
  assert.equal(agentLine(model, cy({ unseen: false, check: { s: "passed", sum: "" } }), NOW), "☆ Cy: done");
});

test("orchestrators follow the agents on Home", () => {
  const model = connected([otto()], NOW, [{ id: "p1", name: "shop", status: "Turn 2 of 12 · 1 working", log: [] }]);
  assert.deepEqual(homeItems(model, NOW).map((row) => row.id), ["a:" + otto().id, "o:p1"]);
});

test("a long menu shows the rows around the chosen one", () => {
  const rows = Array.from({ length: 15 }, (_, i) => ({ id: "r" + i, text: "Row " + i }));
  const shown = menuText(rows, "r10").split("\n");
  assert.equal(shown.length, BODY_LINES);
  assert.ok(shown.includes("> Row 10"));
  assert.equal(menuText(rows, "r0").split("\n")[0], "> Row 0");
  assert.equal(menuText(rows, "gone").split("\n")[0], "> Row 0");
});

test("Allow and Deny are offered only while there's a prompt", () => {
  assert.deepEqual(actionItems(ada()).map((row) => row.id), ["allow", "deny", "talk", "output", "back"]);
  assert.deepEqual(actionItems(otto()).map((row) => row.id), ["talk", "output", "back"]);
  assert.deepEqual(actionItems(ada({ prompt: undefined })).map((row) => row.id), ["talk", "output", "back"]);
});

test("the prompt screen names the agent, the command and what a tap does", () => {
  const ui = { ...createUI(), prompt: { id: ADA, prompt: "p-ada-1", at: 0 } };
  const page = check(render(ui, connected(), NOW));
  assert.equal(page.key, "prompt");
  assert.equal(page.containers[0].text, "● Ada needs permission");
  assert.ok(page.containers[1].text.startsWith("Bash: rm -rf build"));
  assert.ok(page.containers[1].text.endsWith(HINT_PROMPT));
});

test("an agent's screen has its state, task, what it waits on and its last lines", () => {
  let model = connected();
  model = withMessage(model, { t: "tail", id: ADA, text: "Removing build\nAsk before deleting" }, NOW);
  const ui = { ...createUI(), stack: [{ name: "home" }, { name: "agent", id: ADA, page: 0 }] };
  const page = check(render(ui, model, NOW));
  assert.equal(page.containers[0].text, "Ada · needs permission 1m");
  assert.equal(page.containers[1].text, "Clean the build\n\nWaiting on: Bash: rm -rf build\n\nRemoving build\nAsk before deleting");
});

test("speech heard asks before it's sent", () => {
  const voice = { phase: "heard", target: { kind: "agent", id: ADA, name: "Ada" }, via: "hold", text: "run the tests again", error: "", at: 0 };
  const page = check(render({ ...createUI(), voice }, connected(), NOW));
  assert.equal(page.containers[0].text, "Send to Ada?");
  assert.equal(page.containers[1].text, "Heard: run the tests again\n\n" + HINT_SEND);
});

test("connection states each say what to do", () => {
  const at = (state, extra) => plain(check(render(createUI(), withLink(createModel(), state, NOW, extra), NOW + 60_000)));
  assert.match(at("unpaired"), /Not paired[\s\S]*Pair glasses/);
  assert.match(at("pairing", { code: "4821" }), /Code {2}4821/);
  assert.match(at("off"), /Glasses are off/);
  assert.match(at("connecting"), /Connecting to your Mac/);
  assert.match(at("lost"), /Can't reach your Mac[\s\S]*asleep or offline, or Tailscale is off on this phone/);
  assert.match(at("nomac"), /No Mac set/);
});

test("a dropped connection keeps the last screen, dimmed, before it gives up", () => {
  const lost = withLink(connected(), "lost", NOW);
  const soon = check(render(createUI(), lost, NOW + 2000));
  assert.equal(soon.key, "home");
  assert.equal(soon.containers[0].text, "Reconnecting...");
  assert.deepEqual(soon.containers.map((c) => c.color), [1, 1]);
  assert.match(soon.containers[1].text, /Ada/);
  assert.equal(render(createUI(), lost, NOW + 20_000).key, "unreachable");
  // Back: the same screen, bright again.
  assert.deepEqual(render(createUI(), withLink(lost, "ok", NOW + 30_000), NOW + 30_000).containers.map((c) => c.color), [4, 4]);
});

test("every screen keeps to what the glasses can show, whatever the text", () => {
  const wild = ada({ name: "N".repeat(80), detail: "\u{1F680}".repeat(50) + "x".repeat(400), task: "t".repeat(300) });
  let model = withMessage(connected([wild]), { t: "tail", id: ADA, text: "long line ".repeat(300) }, NOW);
  model = withMessage(model, agents(Array.from({ length: 30 }, (_, i) => otto({ id: "id" + i, name: "Agent number " + i })).concat(wild), NOW), NOW);
  const stacks = [[{ name: "home" }], [{ name: "home" }, { name: "agent", id: ADA, page: 3 }],
    [{ name: "home" }, { name: "actions", id: ADA, sel: "deny" }], [{ name: "home" }, { name: "output", id: ADA, back: 99 }]];
  for (const stack of stacks) {
    const page = check(render({ ...createUI(), stack }, model, NOW));
    assert.ok(page.containers[1].text.split("\n").length <= BODY_LINES + 1);
  }
  check(render({ ...createUI(), prompt: { id: ADA, prompt: "p-ada-1", at: 0 } }, model, NOW));
});
