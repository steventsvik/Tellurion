// What the tests share: a model as the Mac would describe it.
import { createModel, withLink, withMessage } from "../model.js";

export const ADA = "11111111-1111-4111-8111-111111111111";
export const OTTO = "22222222-2222-4222-8222-222222222222";
export const CY = "33333333-3333-4333-8333-333333333333";

export function agents(list, now = 1_000_000) {
  return { t: "agents", agents: list, needs: list.filter((a) => a.act === "permission" || a.act === "input").length, now: now / 1000 };
}

export const ada = (extra = {}) => ({ id: ADA, name: "Ada", kind: "claude", act: "permission", since: 900, detail: "Bash: rm -rf build", prompt: "p-ada-1", task: "Clean the build", ...extra });
export const otto = (extra = {}) => ({ id: OTTO, name: "Otto", kind: "codex", act: "working", since: 820, task: "Write the tests", ...extra });
export const cy = (extra = {}) => ({ id: CY, name: "Cy", kind: "claude", act: "done", unseen: true, since: 700, check: { s: "failed", sum: "2 failed" }, ...extra });

/// A connected model with these agents, as of `now`.
export function connected(list = [ada(), otto(), cy()], now = 1_000_000, projects = []) {
  let model = withLink(createModel(), "ok", now, { mac: "Studio" });
  model = withMessage(model, agents(list, now), now);
  return withMessage(model, { t: "orch", projects }, now);
}
