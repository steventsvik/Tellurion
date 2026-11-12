import assert from "node:assert/strict";
import { test } from "node:test";
import { bytes, inner, textWidth } from "../fit.js";
import { createUI } from "../input.js";
import { createModel, groups, sidebarRows, withLink, withMessage } from "../model.js";
import {
  BODY, BODY_HI, BOX, BOX_LINES, EVT, FOOT, FULL_BOX, FULL_LINES, HEAD, HINTS, HINT_CONFIRM, HINT_PROMPT, HINT_SEND, OS_MENU, PANE, PANE_LINES, SIDE,
  SIDE_HI, SIDE_ROWS, TOP, groupLines, menuItems, orchestratorRows, orchestratorStatus, plain, render, rowLabel, sidebarText, toolsLines,
} from "../screens.js";
import {
  ADA, CY, MISSION_PAGE, OTTO, REVIEW_PAGE, SEARCH_PAGE, TOOLS, ZSH, ada, agents, connected, cy, otto, part, screen, shopOrchestrator, zsh,
} from "./helpers.js";

const NOW = 1_000_000;
const at = (sel, extra = {}) => ({ ...createUI(), sel, ...extra });
const term = (id, extra = {}) => ({ name: "term", id, before: 0, off: 0, trail: [], menu: null, later: null, ...extra });
const orch = (extra = {}) => ({ name: "orch", id: "p1", sel: null, menu: null, confirm: null, ...extra });
const tool = (id, extra = {}) => ({ name: "tool", id, sel: null, menu: null, confirm: null, ...extra });
const inside = (...stack) => at("tools", { stack });
const lines = (page, name) => part(page, name).text.split("\n");

/// What every page has to keep to, whatever is on it.
function check(page) {
  const catchers = page.containers.filter((c) => c.capture);
  assert.equal(catchers.length, 1, "exactly one container takes the input");
  // The one that takes the input shows nothing: text that fits its container bounces.
  assert.equal(catchers[0].text, " ");
  assert.ok(page.containers.length <= 8);
  assert.equal(new Set(page.containers.map((c) => c.id)).size, page.containers.length);
  for (const c of page.containers) {
    assert.ok(c.x >= 0 && c.y >= 0 && c.x + c.w <= 576 && c.y + c.h <= 288, c.name);
    assert.ok(bytes(c.text) <= 999, c.name);
    assert.ok(c.color >= 0 && c.color <= 4);
    assert.doesNotMatch(c.text, /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/, c.name + " has a control character");
    if (c.capture) continue;
    // No line is wider than its container, and no container holds more lines than fit.
    const room = inner(c.w, c.pad ?? 4, c.border ?? 0) + 4;
    for (const line of c.text.split("\n")) assert.ok(textWidth(line) <= room, c.name + ": " + line);
    assert.ok(c.text.split("\n").length * 27 <= c.h - 2 * ((c.pad ?? 4) + (c.border ?? 0)) + 1, c.name + " has too many lines");
  }
  for (const item of page.menu ?? []) assert.ok(bytes(item.name) <= 32 && item.id > 0);
  return page;
}

test("browsing is the window: sidebar, title, a short look, hints", () => {
  const model = screen(connected(), OTTO, "$ npm test\nFAIL login.test.ts");
  const page = check(render(at("p:" + OTTO), model, NOW));
  assert.equal(page.key, "main");
  assert.deepEqual(page.containers.map((c) => c.name), ["evt", "sidehi", "side", "head", "box", "pane", "foot"]);
  for (const [name, place] of [["evt", EVT], ["sidehi", SIDE_HI], ["side", SIDE], ["head", HEAD], ["box", BOX], ["pane", PANE], ["foot", FOOT]]) {
    const { x, y, w, h } = part(page, name);
    assert.deepEqual({ x, y, w, h }, { x: place.x, y: place.y, w: place.w, h: place.h });
  }
  assert.ok(SIDE.w / 576 > 0.28 && SIDE.w / 576 < 0.34);
  assert.equal(part(page, "head").text, "Otto · working 3m · Codex");
  // What it was asked, then the end of its screen.
  assert.equal(part(page, "pane").text, "Task: Write the tests\n\n$ npm test\nFAIL login.test.ts");
  assert.equal(part(page, "foot").text, "swipe · tap open · hold talk · 2×tap exit");
  assert.deepEqual(page.menu.map((item) => item.name), OS_MENU.map((item) => item.name));
});

test("every screen you go into has one shape, the whole display wide", () => {
  let model = withMessage(connected([ada(), otto(), cy()], NOW, [shopOrchestrator()]), TOOLS, NOW);
  model = withMessage(screen(model, OTTO, "text"), REVIEW_PAGE, NOW);
  const screens = [term(OTTO), orch(), { name: "log", id: "p1", off: 0 }, { name: "tools", sel: null, confirm: false }, tool("review"),
    { name: "output", id: OTTO, back: 0 }, { name: "ruler" }];
  const shapes = screens.map((entry) => check0(render(inside(entry), model, NOW)).containers.map((c) => [c.name, c.x, c.y, c.w, c.h].join()));
  for (const shape of shapes) assert.deepEqual(shape, shapes[0]);
  const page = render(inside(term(OTTO)), model, NOW);
  assert.deepEqual(page.containers.map((c) => c.name), ["evt", "top", "bodyhi", "body", "box", "foot"]);
  for (const [name, place] of [["top", TOP], ["bodyhi", BODY_HI], ["body", BODY], ["box", FULL_BOX], ["foot", HINTS]]) {
    const { x, y, w, h } = part(page, name);
    assert.deepEqual({ x, y, w, h }, { x: place.x, y: place.y, w: place.w, h: place.h });
  }
  assert.equal(BODY.w, 576);
  assert.equal(TOP.y, 0);
  assert.equal(HINTS.y + HINTS.h, 288);
  // The connection's pages too, so coming back from one is text in place.
  assert.deepEqual(render(createUI(), withLink(createModel(), "connecting", NOW), NOW).containers.map((c) => [c.name, c.x, c.y, c.w, c.h].join()), shapes[0]);
});

/// The display check's rows are longer than the display on purpose.
function check0(page) {
  return page.key === "ruler" ? page : check(page);
}

test("the sidebar groups tabs by project, in the Mac's order", () => {
  const model = withMessage(connected([ada(), otto(), cy(), zsh()], NOW, [shopOrchestrator()]), TOOLS, NOW);
  assert.deepEqual(sidebarRows(model).map((row) => row.id), ["g:p1", "o:p1", "p:" + ADA, "p:" + OTTO, "g:p2", "p:" + CY, "p:" + ZSH, "tools"]);
  const side = sidebarText(at("p:" + OTTO), model, NOW);
  assert.equal(side.bright, ["TELLURION ●1", "", "", "     ● Ada 1m", ">"].join("\n"));
  assert.equal(side.dim, ["", "   ▽ shop", "     ◆ Orchestrator", "", "     ▶ Otto 3m", "   ▽ site", "     ★ Cy", "     $ zsh", "   ◇ Tools", "5h 42% · Wk 61%"].join("\n"));
  assert.equal(plain(render(at("p:" + OTTO), model, NOW)).split("\n")[4], "> ▶ Otto 3m");
});

test("projects come in the order of their first tab; no folder yet goes last", () => {
  const loose = otto({ id: "loose", name: "New", proj: undefined });
  const model = connected([cy(), loose, ada(), zsh()], NOW, [{ id: "p9", name: "idle", status: "Not started", log: [] }]);
  assert.deepEqual(groups(model).map((group) => [group.name, group.panes.map((pane) => pane.name)]),
    [["site", ["Cy", "zsh"]], ["shop", ["Ada"]], ["idle", []], ["Other", ["New"]]]);
  assert.deepEqual(sidebarRows(model).map((row) => row.id).slice(-5), ["g:p9", "o:p9", "g:other", "p:loose", "tools"]);
});

test("a folded project hides its rows and still says it needs you", () => {
  const model = connected([ada(), otto(), cy()], NOW, [shopOrchestrator()]);
  const ui = at("g:p1", { folded: ["p1"] });
  assert.deepEqual(sidebarRows(model, ui.folded).map((row) => row.id), ["g:p1", "g:p2", "p:" + CY, "tools"]);
  assert.equal(sidebarText(ui, model, NOW).bright, "TELLURION ●1\n> ▷ shop ●1");
  assert.equal(part(render(ui, model, NOW), "foot").text, "swipe · tap unfold · hold talk · 2×tap exit");
  const calm = sidebarText(ui, connected([otto(), cy()]), NOW);
  assert.equal(calm.bright, "TELLURION\n>");
  assert.match(calm.dim, /^\n {3}▷ shop\n/);
});

test("a row's glyph says its state", () => {
  const model = connected();
  const row = (pane) => rowLabel({ kind: "pane", pane }, model, NOW);
  assert.equal(row(ada()), "● Ada 1m");
  assert.equal(row(ada({ act: "input" })), "○ Ada 1m");
  assert.equal(row(otto()), "▶ Otto 3m");
  assert.equal(row(cy()), "★ Cy");
  assert.equal(row(cy({ unseen: false })), "☆ Cy");
  assert.equal(row(otto({ act: "failed" })), "▲ Otto");
  assert.equal(row(otto({ act: "ready" })), "□ Otto");
  assert.equal(row(zsh()), "$ zsh");
});

test("more rows than fit: the ones around the chosen one show", () => {
  const model = connected(Array.from({ length: 14 }, (_, i) => otto({ id: "id" + i, name: "Agent " + i })));
  const top = sidebarText(at("g:p1"), model, NOW);
  assert.equal(top.bright.split("\n")[0], "TELLURION ↓");
  assert.equal(top.dim.split("\n").length, SIDE_ROWS + 1);
  const deep = sidebarText(at("p:id9"), model, NOW);
  assert.ok(deep.dim.includes("Agent 9") && !deep.dim.includes("shop"));
  assert.equal(deep.bright.split("\n")[0], "TELLURION ↑↓");
  assert.equal(sidebarText(at("tools"), model, NOW).bright.split("\n")[0], "TELLURION ↑");
});

test("the short look follows the chosen row", () => {
  let model = withMessage(connected([ada(), otto({ budget: { f: 0.83, s: "warning" }, conflicts: 2 }), cy(), zsh()], NOW, [shopOrchestrator()]), TOOLS, NOW);
  model = screen(model, ZSH, "$ git status");
  const shown = (sel) => check(render(at(sel), model, NOW));
  // Too long for the line: its kind, which comes last, is what's cut.
  assert.match(part(shown("p:" + OTTO), "head").text, /^Otto · working 3m · budget 83% · 2 conf.*\.\.\.$/);
  const shell = shown("p:" + ZSH);
  assert.equal(part(shell, "head").text, "zsh · terminal");
  assert.equal(part(shell, "pane").text, "$ git status");
  // Nobody to talk to there: the hints don't offer it.
  assert.equal(part(shell, "foot").text, "swipe · tap open · 2×tap exit");
  // A tab whose screen hasn't come yet says so, rather than showing another's.
  assert.equal(part(shown("p:" + CY), "pane").text, "...");
  const orchestrator = shown("o:p1");
  assert.equal(part(orchestrator, "head").text, "Orchestrator · shop");
  assert.equal(part(orchestrator, "pane").text, "Waiting on you: Ada\nGoal: Ship the login flow\nSays: Otto is on the tests.\nTeam: Ada, Otto");
  const project = shown("g:p1");
  assert.equal(part(project, "pane").text, "~/code/shop\n2 agents · 1 needs you\nOrchestrator: Turn 2 of 12 · 1 working\nGoal: Ship the login flow\nServer: localhost:5173");
  assert.equal(part(shown("tools"), "head").text, "Tools · 1 needs you · 1 working");
  assert.equal(part(shown("tools"), "foot").text, "swipe · tap open · hold say · 2×tap exit");
});

test("the short look shows a pending prompt, and a screen cleaned for reading", () => {
  const busy = "● Working on it\n\n   name        status\n✻ Baking… (3s · esc to interrupt)\n──────────\n> \n──────────\n  ? for shortcuts";
  const model = screen(screen(connected(), ADA, busy), OTTO, busy);
  const asking = check(render(at("p:" + ADA), model, NOW));
  assert.equal(lines(asking, "box")[1], "● Allow?  Bash: rm -rf build");
  // It can't be answered from here: the hints say what a tap does, which is go in.
  assert.equal(part(asking, "foot").text, "swipe · tap open · hold talk · 2×tap exit");
  assert.equal(part(render(at("p:" + OTTO), model, NOW), "pane").text, "Task: Write the tests\n\n● Working on it\n\n   name  status");
  assert.equal(part(render(at("p:" + OTTO), model, NOW), "box").text, "");
});

test("a project at a glance, and Tools at a glance", () => {
  const model = withMessage(connected([cy(), zsh()]), TOOLS, NOW);
  assert.deepEqual(groupLines(model, groups(model)[0]), ["~/code/site", "1 agent · 1 terminal", "Check failed: Cy (2 failed)"]);
  const far = connected([cy({ proj: { id: "p2", name: "site", path: "~/code/a/very/long/way/down/into/the/folders/of/this/project/site" } })]);
  assert.match(groupLines(far, groups(far)[0])[0], /^~\/\.\.\.\/.*site$/);
  assert.deepEqual(toolsLines(withMessage(connected(), TOOLS, NOW), NOW), [
    "Claude: 5h 42% (2h 10m) · Wk 61% (3d)", "Server: localhost:5173 · shop", "Review: 2 waiting", "Check failed: Cy", "Budget: Otto at 83%", "No conflicts",
  ]);
  assert.deepEqual(toolsLines(connected(), NOW), ["..."]);
});

test("a tab's terminal takes the whole display, cleaned and wrapped to its width", () => {
  const long = "The quick brown fox jumps over the lazy dog today";
  const model = screen(connected([otto()]), OTTO, "$ run\n" + long + "\n\n\n\n• Working (3m 12s • esc to interrupt)\n› \n  100% context left · ? for shortcuts");
  const page = check(render(at("p:" + OTTO, { stack: [term(OTTO)] }), model, NOW));
  assert.equal(page.key, "term");
  assert.equal(part(page, "top").text, "Otto · working 3m · Codex");
  // One line here; the short look beside the sidebar needs two for it.
  assert.equal(part(page, "body").text, "$ run\n" + long);
  assert.equal(part(render(at("p:" + OTTO), model, NOW), "pane").text.split("\n").length, 5);
  assert.equal(part(page, "box").text, "");
  assert.equal(part(page, "foot").text, "tap menu · hold talk · 2×tap back");
  // A plain terminal: nothing to tap or say.
  const shell = render(at("p:" + ZSH, { stack: [term(ZSH)] }), screen(connected([zsh()]), ZSH, "$ ls"), NOW);
  assert.equal(part(shell, "foot").text, "2×tap back");
  // More than a screenful: a swipe reads back, and the hints say so.
  const tall = screen(connected([otto()]), OTTO, Array.from({ length: 20 }, (_, i) => "line " + i).join("\n"));
  const full = render(at("p:" + OTTO, { stack: [term(OTTO)] }), tall, NOW);
  assert.equal(lines(full, "body").length, FULL_LINES);
  assert.ok(part(full, "body").text.endsWith("line 19"));
  assert.equal(part(full, "foot").text, "swipe read · tap menu · hold talk · 2×tap back");
  assert.match(part(render(at("p:" + OTTO, { stack: [term(OTTO, { off: 6 })] }), tall, NOW), "top").text, /^↑ Otto/);
});

test("a permission prompt shows in its own terminal, with the command", () => {
  const model = screen(connected(), ADA, Array.from({ length: 12 }, (_, i) => "line " + i).join("\n"));
  const page = check(render(at("p:" + ADA, { stack: [term(ADA)] }), model, NOW));
  const box = lines(page, "box");
  assert.match(box[0], /^─+$/);
  assert.equal(box[1], "● Allow?  Bash: rm -rf build");
  assert.equal(part(page, "foot").text, HINT_PROMPT);
  assert.equal(lines(page, "body").length, FULL_LINES - BOX_LINES);
  assert.ok(part(page, "body").text.endsWith("line 11"));
  // Not in another tab's terminal, not scrolled back, and not once it's answered from here.
  assert.equal(part(render(at("p:" + OTTO, { stack: [term(OTTO)] }), model, NOW), "box").text, "");
  assert.equal(part(render(at("p:" + ADA, { stack: [term(ADA, { off: 3 })] }), model, NOW), "box").text, "");
  assert.equal(part(render(at("p:" + ADA, { stack: [term(ADA)], answered: ["p-ada-1"] }), model, NOW), "box").text, "");
  const asks = render(at("p:" + ADA, { stack: [term(ADA)] }), connected([ada({ act: "input", prompt: undefined, detail: "Which database?" })]), NOW);
  assert.equal(lines(asks, "box")[1], "○ Asks: Which database?");
  assert.equal(part(asks, "foot").text, "tap menu · hold talk · 2×tap back");
});

test("speech and the menu show in the box without leaving the screen", () => {
  const model = screen(connected([otto()]), OTTO, "text");
  const voice = (phase, extra = {}) => ({ phase, target: { kind: "agent", id: OTTO, name: "Otto" }, via: "hold", text: "", error: "", at: 0, ...extra });
  for (const stack of [[], [term(OTTO)]]) {
    const shown = (v) => check(render(at("p:" + OTTO, { stack, voice: v }), model, NOW));
    const listening = shown(voice("listening"));
    assert.equal(lines(listening, "box").slice(1).join("\n"), "Listening... → Otto\nSpeak now.");
    assert.equal(part(listening, "foot").text, "let go when you're done");
    const heard = shown(voice("heard", { text: "run the tests again" }));
    assert.equal(lines(heard, "box")[1], "Heard, for Otto: run the tests again");
    assert.equal(part(heard, "foot").text, HINT_SEND);
    assert.equal(part(shown(voice("error", { error: "Your Mac didn't answer." })), "foot").text, "tap back");
  }
  const ids = (pane) => menuItems(pane).map((item) => item.id);
  assert.deepEqual(ids(otto()), ["talk", "key:enter", "key:escape", "key:ctrl-c", "key:up", "key:down", "key:tab", "key:y", "key:n", "output"]);
  // No keys while it asks for permission: that's answered as a prompt.
  assert.deepEqual(ids(ada()), ["talk", "output"]);
  assert.deepEqual(ids(zsh()), []);
  const menu = check(render(at("p:" + OTTO, { stack: [term(OTTO, { menu: { sel: "key:enter" } })] }), model, NOW));
  assert.match(part(menu, "box").text, /Talk {3}\[Enter\] {3}Esc/);
  assert.equal(part(menu, "foot").text, "swipe choose · tap do · 2×tap close");
});

test("the orchestrator's screen: status, goal, the team, the latest", () => {
  const model = connected([ada(), otto(), cy()], NOW, [shopOrchestrator()]);
  const project = model.projects[0];
  assert.equal(orchestratorStatus(project), "Waiting on you: Ada");
  assert.equal(orchestratorStatus(shopOrchestrator({ members: [] })), "Turn 2 of 12 · 1 working");
  assert.deepEqual(orchestratorRows(model, project).map((row) => row.id), ["ask:" + ADA, "goal", "m:" + ADA, "m:" + OTTO, "latest", "last"]);
  const page = check(render(inside(orch()), model, NOW));
  assert.equal(page.key, "orch");
  assert.equal(part(page, "top").text, "shop · Waiting on you: Ada");
  // Whoever asks comes first, with its name and what for; it and the latest word are bright.
  assert.deepEqual(lines(page, "bodyhi"), ["> ● Ada asks: Bash: rm -rf build - tap to open", "", "   ● Ada · Coder · Bash: rm -rf build", "", "   Says: Otto is on the tests."]);
  assert.deepEqual(lines(page, "body"), ["", "   Goal: Ship the login flow", "", "   ▶ Otto · Tester · writing login tests", "", "   Last: Asked Otto to write the tests"]);
  assert.equal(part(page, "foot").text, "swipe move · tap open · hold command · 2×tap back");
  assert.equal(part(render(inside(orch({ sel: "goal" })), model, NOW), "foot").text, "swipe move · tap actions · hold command · 2×tap back");
  assert.equal(part(render(inside(orch({ sel: "latest" })), model, NOW), "foot").text, "swipe move · tap log · hold command · 2×tap back");
  // Nobody asking, nobody wired, nothing said yet.
  const bare = connected([otto()], NOW, [{ id: "p1", name: "shop", status: "Not started", log: [], members: [] }]);
  assert.deepEqual(plain(render(inside(orch()), bare, NOW)).split("\n"),
    ["shop · Not started", "> No goal yet. Hold to give it one.", "   Nobody is wired yet.", "   Nothing in its log yet.", "swipe move · tap actions · hold command · 2×tap back"]);
});

test("the orchestrator's actions are asked about before they're sent", () => {
  const model = connected([otto()], NOW, [shopOrchestrator()]);
  const menu = check(render(inside(orch({ sel: "goal", menu: { sel: "go" } })), model, NOW));
  assert.equal(lines(menu, "box")[1], "Stop   [Carry on]   Wire all   Clear");
  const sure = check(render(inside(orch({ sel: "goal", menu: { sel: "wire" }, confirm: "wire" })), model, NOW));
  assert.equal(lines(sure, "box")[1], "Wire every agent in this project?");
  assert.equal(part(sure, "foot").text, HINT_CONFIRM);
  const log = check(render(inside({ name: "log", id: "p1", off: 0 }), model, NOW));
  assert.equal(part(log, "top").text, "Orchestrator log");
  assert.equal(part(log, "body").text, "You: ship it\nAsked Otto to write the tests");
  assert.equal(part(log, "foot").text, "hold command · 2×tap back");
});

test("Tools lists the Mac's tools in its order, with a line about the chosen one", () => {
  const model = withMessage(connected(), TOOLS, NOW);
  const page = check(render(inside({ name: "tools", sel: null, confirm: false }), model, NOW));
  assert.equal(part(page, "top").text, "Tools 1/7");
  // The one with something to say is bright; the cursor is on it.
  assert.deepEqual(lines(page, "bodyhi"), ["> Mission Control"]);
  assert.deepEqual(lines(page, "body"), ["", "   Review changes", "   Search sessions", "   Localhost"]);
  assert.equal(lines(page, "box")[1], "Agents · 1 needs you");
  assert.equal(part(page, "foot").text, "swipe move · tap open · 2×tap back");
  // A tool with no page here opens on the Mac, after being asked.
  const skills = render(inside({ name: "tools", sel: "skills", confirm: false }), model, NOW);
  assert.match(part(skills, "body").text, /Skills → Mac/);
  assert.equal(lines(skills, "box")[1], "Project · Opens on your Mac");
  assert.equal(part(skills, "foot").text, "swipe move · tap open on Mac · 2×tap back");
  const sure = check(render(inside({ name: "tools", sel: "skills", confirm: true }), model, NOW));
  assert.equal(lines(sure, "box")[1], "Open Skills on your Mac?");
  assert.equal(part(sure, "foot").text, HINT_CONFIRM);
  assert.equal(part(render(inside({ name: "tools", sel: null, confirm: false }), connected(), NOW), "body").text, "...");
});

test("a tool's page: its rows, a line about the chosen one, its actions", () => {
  const base = withMessage(connected(), TOOLS, NOW);
  const waiting = render(inside(tool("review")), base, NOW);
  assert.equal(part(waiting, "top").text, "Review changes");
  assert.equal(part(waiting, "body").text, "...");
  const model = withMessage(base, REVIEW_PAGE, NOW);
  const page = check(render(inside(tool("review")), model, NOW));
  assert.equal(part(page, "top").text, "Review changes 1/2");
  assert.equal(part(page, "bodyhi").text, ">");
  assert.equal(part(page, "body").text, "   Otto · shop · 3 files +40 -12\n   Cy · site · 1 file +2 -2");
  assert.equal(lines(page, "box")[1], "Write the tests");
  assert.equal(part(page, "foot").text, "swipe move · tap actions · 2×tap back");
  const menu = render(inside(tool("review", { sel: "r1", menu: { sel: "open" } })), model, NOW);
  assert.equal(lines(menu, "box")[1], "Say feedback   [Open on Mac]");
  const sure = render(inside(tool("review", { sel: "r1", menu: { sel: "open" }, confirm: "open" })), model, NOW);
  assert.equal(lines(sure, "box")[1], "Open this review on your Mac?");
  assert.equal(part(sure, "foot").text, HINT_CONFIRM);
  // Another tool's page isn't shown under this one's name.
  assert.equal(part(render(inside(tool("localhost")), model, NOW), "body").text, "...");
  const search = check(render(inside(tool("search")), withMessage(base, SEARCH_PAGE, NOW), NOW));
  assert.equal(part(search, "body").text, "Hold and say what to look for.");
  assert.equal(part(search, "foot").text, "hold search · 2×tap back");
  const mission = render(inside(tool("mission")), withMessage(base, MISSION_PAGE, NOW), NOW);
  assert.equal(lines(mission, "bodyhi")[0], "> ● Ada · shop · needs permission");
  assert.equal(part(mission, "foot").text, "swipe move · tap open · 2×tap back");
  assert.equal(part(render(inside(tool("mission", { sel: "x" })), withMessage(base, MISSION_PAGE, NOW), NOW), "foot").text, "swipe move · 2×tap back");
});

test("an agent's latest output and the display check", () => {
  let model = withMessage(connected([otto()]), { t: "tail", id: OTTO, src: "answer", text: Array.from({ length: 20 }, (_, i) => "answer " + i).join("\n") }, NOW);
  const output = check(render(inside({ name: "output", id: OTTO, back: 0 }), model, NOW));
  assert.equal(part(output, "top").text, "Otto · latest output 3/3");
  assert.ok(part(output, "body").text.endsWith("answer 19"));
  assert.equal(part(output, "foot").text, "swipe read · tap or 2×tap back");
  // The screen's text isn't taken for the answer.
  model = screen(model, OTTO, "screen text");
  assert.equal(part(render(inside({ name: "output", id: OTTO, back: 0 }), model, NOW), "body").text, "Nothing yet.");
  const ruler = render(inside({ name: "ruler" }), model, NOW);
  assert.match(part(ruler, "body").text, /^n{9}1n{9}2/);
  assert.match(part(ruler, "body").text, /Expected to fit: n \d+ · M \d+ · i \d+$/);
});

test("connection states each say what to do", () => {
  const shown = (state, extra) => plain(check(render(createUI(), withLink(createModel(), state, NOW, extra), NOW + 60_000)));
  assert.match(shown("unpaired"), /Not paired[\s\S]*Pair glasses/);
  assert.match(shown("pairing", { code: "4821" }), /Code {2}4821/);
  assert.match(shown("off"), /Glasses are off/);
  assert.match(shown("connecting"), /Connecting to your Mac/);
  assert.match(shown("lost"), /Can't reach your Mac[\s\S]*asleep or offline, or Tailscale is off on this phone/);
  assert.match(shown("nomac"), /No Mac set/);
});

test("a dropped connection keeps the last screen, dimmed, before it gives up", () => {
  const lost = withLink(connected(), "lost", NOW);
  const soon = check(render(at("p:" + ADA), lost, NOW + 2000));
  assert.equal(soon.key, "main");
  assert.equal(part(soon, "head").text, "Reconnecting...");
  assert.ok(soon.containers.filter((c) => !c.capture).every((c) => c.color === 1));
  const inTerm = render(at("p:" + ADA, { stack: [term(ADA)] }), lost, NOW + 2000);
  assert.equal(part(inTerm, "top").text, "Reconnecting...");
  assert.ok(inTerm.containers.filter((c) => !c.capture).every((c) => c.color === 1));
  assert.equal(render(createUI(), lost, NOW + 20_000).key, "unreachable");
  assert.equal(part(render(at("p:" + ADA), withLink(lost, "ok", NOW + 30_000), NOW + 30_000), "head").color, 4);
});

test("every screen keeps to what the glasses can show, whatever the text", () => {
  const wild = ada({ name: "N".repeat(80), detail: "\u{1F680}".repeat(50) + "W".repeat(400), task: "t".repeat(300), proj: { id: "p1", name: "M".repeat(60), path: "~/" + "w".repeat(300) } });
  let model = connected([wild, ...Array.from({ length: 30 }, (_, i) => otto({ id: "id" + i, name: "Agent number " + i + " with a long name" }))], NOW,
    [shopOrchestrator({ goal: "g".repeat(400), says: "s".repeat(500), log: Array.from({ length: 30 }, () => "log ".repeat(60)),
      members: Array.from({ length: 12 }, (_, i) => ({ id: "id" + i, name: "Agent number " + i, role: "R".repeat(40), act: "working", detail: "d".repeat(200) })) })]);
  const noisy = ("long line ".repeat(40) + "\n").repeat(30) + "╭" + "─".repeat(120) + "╮\n" + "W".repeat(300) + "\n\u001b[31mred\u0007\u001b[0m [0m /a/" + "b/".repeat(200) + "c";
  model = screen(withMessage(model, { ...TOOLS, list: Array.from({ length: 30 }, (_, i) => ({ id: "t" + i, name: "Tool " + "x".repeat(60), section: "S".repeat(40), page: i % 2 === 0, sum: "sum ".repeat(60) })) }, NOW), ADA, noisy);
  model = withMessage(model, { t: "toolpage", id: "t0", title: "T".repeat(90), note: "n".repeat(300),
    rows: Array.from({ length: 25 }, (_, i) => ({ id: "r" + i, text: "row ".repeat(40), sub: "sub ".repeat(80), actions: Array.from({ length: 8 }, (_, k) => ({ id: "a" + k, label: "Action " + k, ask: "ask ".repeat(60) })) })) }, NOW);
  const speech = { phase: "heard", target: { kind: "agent", id: ADA, name: wild.name }, via: "hold", text: "word ".repeat(200), error: "", at: 0 };
  const states = [
    at("p:" + ADA), at("g:p1"), at("o:p1"), at("tools"), at("p:" + ADA, { voice: speech }), at("p:" + ADA, { flash: { text: "F".repeat(200), until: NOW + 1 } }),
    inside(term(ADA)), inside(term(ADA, { off: 9999 })), inside(term("id3", { menu: { sel: "key:n" } })), inside(term(ADA), ), { ...inside(term(ADA)), voice: speech },
    inside(orch()), inside(orch({ sel: "m:id7" })), inside(orch({ sel: "goal", menu: { sel: "clear" } })), inside(orch({ confirm: "clear" })), inside({ name: "log", id: "p1", off: 3 }),
    inside({ name: "tools", sel: "t7", confirm: false }), inside({ name: "tools", sel: "t7", confirm: true }),
    inside(tool("t0", { sel: "r9" })), inside(tool("t0", { sel: "r9", menu: { sel: "a5" } })), inside(tool("t0", { sel: "r9", confirm: "a5" })),
    inside({ name: "output", id: ADA, back: 99 }),
  ];
  for (const ui of states) check(render(ui, model, NOW));
  check(render(at("p:" + ADA), withMessage(model, agents([], NOW), NOW), NOW));
});
