// What the tests share: a model as the Mac would describe it.
import { createModel, withLink, withMessage } from "../model.js";

export const ADA = "11111111-1111-4111-8111-111111111111";
export const OTTO = "22222222-2222-4222-8222-222222222222";
export const CY = "33333333-3333-4333-8333-333333333333";
export const ZSH = "44444444-4444-4444-8444-444444444444";
export const SHOP = { id: "p1", name: "shop", path: "~/code/shop" };
export const SITE = { id: "p2", name: "site", path: "~/code/site" };

export function agents(list, now = 1_000_000) {
  return { t: "agents", v: 2, agents: list, needs: list.filter((a) => a.act === "permission" || a.act === "input").length, now: now / 1000 };
}

export const ada = (extra = {}) => ({ id: ADA, name: "Ada", kind: "claude", agent: true, act: "permission", since: 900, detail: "Bash: rm -rf build", prompt: "p-ada-1", task: "Clean the build", proj: SHOP, ...extra });
export const otto = (extra = {}) => ({ id: OTTO, name: "Otto", kind: "codex", agent: true, act: "working", since: 820, task: "Write the tests", proj: SHOP, ...extra });
export const cy = (extra = {}) => ({ id: CY, name: "Cy", kind: "claude", agent: true, act: "done", unseen: true, since: 700, check: { s: "failed", sum: "2 failed" }, proj: SITE, ...extra });
export const zsh = (extra = {}) => ({ id: ZSH, name: "zsh", kind: "", agent: false, act: "none", since: 600, proj: SITE, ...extra });
export const shopOrchestrator = (extra = {}) => ({
  id: "p1", name: "shop", status: "Turn 2 of 12 · 1 working", goal: "Ship the login flow", running: true,
  log: ["You: ship it", "Asked Otto to write the tests"], says: "Otto is on the tests.", last: "Asked Otto to write the tests",
  members: [{ id: ADA, name: "Ada", role: "Coder", act: "permission" }, { id: OTTO, name: "Otto", role: "Tester", act: "working", detail: "writing login tests" }],
  ...extra,
});

export const TOOLS = {
  t: "tools",
  usage: [{ name: "Claude", windows: [{ label: "5h", pct: 42, resets: 1000 + 7800 }, { label: "Wk", pct: 61, resets: 1000 + 3 * 86400 }] }],
  servers: [{ name: "shop", url: "localhost:5173", proj: "p1" }],
  review: 2, checks: ["Cy"], budgets: [{ name: "Otto", pct: 83 }], conflicts: 0,
  list: [
    { id: "mission", name: "Mission Control", section: "Agents", page: true, sum: "1 needs you", hi: true },
    { id: "review", name: "Review changes", section: "Agents", page: true, sum: "2 waiting" },
    { id: "search", name: "Search sessions", section: "Agents", page: true, sum: "" },
    { id: "localhost", name: "Localhost", section: "Project", page: true, sum: "1 running" },
    { id: "skills", name: "Skills", section: "Project", page: false, sum: "" },
    { id: "settings", name: "Settings", section: "View", page: false, sum: "" },
    { id: "ruler", name: "Display check", section: "Glasses", page: true, sum: "How many characters fit" },
  ],
};

/// A tool's page as the Mac sends it.
export const REVIEW_PAGE = {
  t: "toolpage", id: "review", title: "Review changes", note: "",
  rows: [
    { id: "r1", text: "Otto · shop · 3 files +40 -12", sub: "Write the tests", actions: [
      { id: "feedback", label: "Say feedback", voice: true, name: "Otto" }, { id: "open", label: "Open on Mac", ask: "Open this review on your Mac?" }] },
    { id: "r2", text: "Cy · site · 1 file +2 -2", sub: "", actions: [{ id: "open", label: "Open on Mac", ask: "Open this review on your Mac?" }] },
  ],
};
export const SEARCH_PAGE = { t: "toolpage", id: "search", title: "Search sessions", note: "Hold and say what to look for.", voice: { action: "query", name: "search", hint: "search" }, rows: [] };
export const MISSION_PAGE = { t: "toolpage", id: "mission", title: "Mission Control", rows: [
  { id: ADA, text: "● Ada · shop · needs permission", sub: "Bash: rm -rf build", hi: true, open: "p:" + ADA },
  { id: "o", text: "◆ Orchestrator · shop", sub: "Turn 2 of 12", open: "o:p1" },
  { id: "x", text: "Nothing else", sub: "" },
] };

/// A connected model with these panes, as of `now`.
export function connected(list = [ada(), otto(), cy()], now = 1_000_000, projects = []) {
  let model = withLink(createModel(), "ok", now, { mac: "Studio" });
  model = withMessage(model, agents(list, now), now);
  return withMessage(model, { t: "orch", projects }, now);
}

/// The Mac's text for a pane's screen.
export function screen(model, id, text, extra = {}) {
  return withMessage(model, { t: "tail", id, src: "screen", before: 0, text, ...extra }, 1_000_000);
}

/// A page's container by name.
export function part(page, name) {
  return page.containers.find((container) => container.name === name);
}
