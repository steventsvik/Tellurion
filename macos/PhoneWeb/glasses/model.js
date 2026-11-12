// What the glasses know about the Mac: built only from the server's messages and the
// connection's state. Every function here returns a new value and touches nothing else.

export function createModel() {
  return {
    /// "boot", "connecting", "pairing", "unpaired", "ok", "lost", "off" or "nomac".
    link: "boot",
    /// When the connection was lost, and a line about why it isn't paired.
    lostAt: 0,
    linkNote: "",
    pairCode: "",
    mac: "",
    agents: [],
    needs: 0,
    /// The Mac's clock minus this one's, in seconds, as of the last agents message.
    skew: 0,
    projects: [],
    tail: null,
    /// Whether the Mac has listed its agents and its orchestrators yet.
    seen: { agents: false, orch: false },
  };
}

/// The connection changed.
export function withLink(model, state, now, extra = {}) {
  const next = { ...model, link: state, linkNote: extra.note ?? "", pairCode: extra.code ?? "" };
  if (extra.mac) next.mac = extra.mac;
  if (state === "lost" || state === "nomac") next.lostAt = model.link === state ? model.lostAt : now;
  return next;
}

/// A message from the server.
export function withMessage(model, message, now) {
  switch (message?.t) {
    case "agents": {
      const agents = Array.isArray(message.agents) ? message.agents.filter((a) => a && typeof a.id === "string") : [];
      const skew = typeof message.now === "number" ? message.now - now / 1000 : model.skew;
      return { ...model, agents, needs: Number(message.needs) || 0, skew, seen: { ...model.seen, agents: true } };
    }
    case "orch":
      return {
        ...model,
        projects: Array.isArray(message.projects) ? message.projects.filter((p) => p && typeof p.id === "string") : [],
        seen: { ...model.seen, orch: true },
      };
    case "tail":
      return { ...model, tail: { id: message.id, text: String(message.text ?? ""), gone: message.gone === true } };
    default:
      return model;
  }
}

export function agentById(model, id) {
  return model.agents.find((agent) => agent.id === id) ?? null;
}

/// The permission prompts waiting, in the order the server lists them.
export function pendingPrompts(model) {
  return model.agents.filter((agent) => agent.act === "permission" && typeof agent.prompt === "string" && agent.prompt);
}

/// Whether this very prompt is still the one the agent shows.
export function promptPending(model, id, prompt) {
  return pendingPrompts(model).some((agent) => agent.id === id && agent.prompt === prompt);
}

const WORDS = {
  permission: "needs permission", input: "needs input", failed: "failed", done: "done", working: "working", ready: "ready",
};

export function stateWords(agent) {
  return WORDS[agent.act] ?? "ready";
}

/// "45s" is noise at a glance: nothing under a minute, then "3m", "2h", "4d".
export function age(seconds) {
  if (!(seconds >= 60)) return "";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h";
  return Math.floor(seconds / 86400) + "d";
}

export function agentAge(model, agent, now) {
  return typeof agent.since === "number" ? age(now / 1000 + model.skew - agent.since) : "";
}

/// "2 need you · 3 working", or what else there is to say.
export function summary(model) {
  const working = model.agents.filter((agent) => agent.act === "working").length;
  const parts = [];
  if (model.needs > 0) parts.push(model.needs === 1 ? "1 needs you" : model.needs + " need you");
  if (working > 0) parts.push(working + " working");
  if (parts.length) return parts.join(" · ");
  return model.agents.length ? "All quiet" : "No agents running";
}

/// The marks worth a word on an agent's line: a failed check, a budget, conflicts.
export function marks(agent) {
  const found = [];
  if (agent.check?.s === "failed") found.push("check failed");
  else if (agent.check?.s === "running") found.push("checking");
  if (agent.budget?.s === "paused") found.push("budget reached");
  else if (agent.budget?.s === "warning" || agent.budget?.s === "reached") found.push("budget " + Math.round((agent.budget.f || 0) * 100) + "%");
  if (agent.conflicts > 0) found.push(agent.conflicts === 1 ? "1 conflict" : agent.conflicts + " conflicts");
  return found;
}
