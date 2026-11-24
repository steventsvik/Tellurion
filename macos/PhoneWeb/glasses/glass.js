// Puts a page description (see screens.js) on the glasses through the Even app's bridge.
// One call at a time, the newest page winning; a little text that changed is updated in
// place (no flicker), and a different layout or a lot of changes rebuild the page. A call that fails or
// never answers is given up on and tried again later, so nothing waits on it for ever.

/// Going from one scene to another (into the pane, say) with more text containers than
/// this to change, the page is rebuilt: each change in place is a call of its own, and a
/// rebuild is one. Within a scene nothing is ever rebuilt, so a swipe never flickers.
export const MOST_IN_PLACE = 2;

/// What it takes to get from the page that's showing to `next`.
/// { op: "create" } the first time, { op: "rebuild" } for another layout, { op: "upgrade",
/// changes } when only text or brightness differs (the most urgent container first),
/// { op: "none" } when nothing does.
export function plan(shown, next) {
  if (!shown) return { op: "create" };
  if (layoutKey(shown) !== layoutKey(next)) return { op: "rebuild" };
  const changes = next.containers.filter((container, index) => {
    const before = shown.containers[index];
    return container.type === "text" && (before.text !== container.text || before.color !== container.color);
  });
  if (!changes.length) return { op: "none" };
  if (changes.length > MOST_IN_PLACE && (shown.scene ?? "") !== (next.scene ?? "")) return { op: "rebuild" };
  return { op: "upgrade", changes: [...changes].sort((a, b) => (a.rank ?? 0) - (b.rank ?? 0)) };
}

/// Everything about a page that can't be changed in place: which containers, where, a
/// list's rows, and the glasses' own menu.
export function layoutKey(description) {
  return description.containers.map((c) => [c.type, c.id, c.x, c.y, c.w, c.h, c.capture ? 1 : 0,
    c.type === "list" ? JSON.stringify(c.items) : ""].join(",")).join("|") + "|" + JSON.stringify(description.menu ?? []);
}

/// The page as the bridge takes it: text and list containers, exactly one taking the
/// input, and the rows for the glasses' own menu.
export function containerPayload(description) {
  const texts = [];
  const lists = [];
  description.containers.forEach((c) => {
    const base = {
      xPosition: c.x, yPosition: c.y, width: c.w, height: c.h, containerID: c.id, containerName: c.name,
      borderWidth: c.border ?? 0, borderColor: c.borderColor ?? 0, borderRadius: 0, paddingLength: c.pad ?? 4,
      isEventCapture: c.capture ? 1 : 0,
    };
    if (c.type === "list") {
      lists.push({ ...base, itemContainer: { itemCount: c.items.length, itemWidth: c.w - 8, isItemSelectBorderEn: 1, itemName: c.items } });
    } else {
      texts.push({ ...base, content: c.text, textColor: c.color });
    }
  });
  const payload = { containerTotalNum: texts.length + lists.length, textObject: texts, listObject: lists };
  // Left out, a rebuild clears the menu; so it goes with every page that has one.
  if (description.menu?.length) payload.menuObject = { menuItems: description.menu.map((item) => ({ itemID: item.id, itemName: item.name })) };
  return payload;
}

function timeout(promise, ms, timers) {
  return new Promise((resolve, reject) => {
    const timer = timers.setTimeout(() => reject(new Error("The glasses didn't answer")), ms);
    Promise.resolve(promise).then(
      (value) => { timers.clearTimeout(timer); resolve(value); },
      (error) => { timers.clearTimeout(timer); reject(error); });
  });
}

/// `bridge`: the Even app's bridge. `make`: the SDK's classes for a page, a rebuild and a
/// text update (plain objects pass through when left out, as in tests).
export function createGlass({ bridge, make = {}, timers = globalThis, now = () => Date.now(), onShown = () => {}, onError = () => {} }) {
  const wrap = (name, value) => (make[name] ? make[name](value) : value);
  const patience = 4000;
  /// Rebuilds are kept apart, and held back right after a swipe: a list that's rebuilt
  /// under a moving finger loses its place.
  const rebuildGap = 500;
  let shown = null;
  let wanted = null;
  let busy = false;
  let created = false;
  let lastRebuild = -Infinity;
  let quietUntil = -Infinity;
  let retry = null;
  let failures = 0;

  async function call(name, argument) {
    return timeout(bridge[name](argument), patience, timers);
  }

  async function rebuild(next) {
    const wait = Math.max(lastRebuild + rebuildGap, next.containers.some((c) => c.type === "list") ? quietUntil : 0) - now();
    if (wait > 0) await new Promise((resolve) => timers.setTimeout(resolve, wait));
    lastRebuild = now();
    const ok = await call("rebuildPageContainer", wrap("rebuild", containerPayload(next)));
    if (ok === false) throw new Error("The page wasn't rebuilt");
  }

  /// One call towards `next`. Returns what's showing after it: `next` itself, or the page
  /// in between when only one of several containers has been changed so far.
  async function apply(next) {
    // A page that was made but isn't known any more is set whole.
    const step = !created ? { op: "create" } : shown ? plan(shown, next) : { op: "rebuild" };
    if (step.op === "none") return next;
    if (step.op === "create") {
      // Once only, whether or not it works: asking again blocks for seconds.
      created = true;
      let result;
      try { result = await call("createStartUpPageContainer", wrap("create", containerPayload(next))); } catch { result = -1; }
      // Anything but success: a page may be there already (the app was reopened), and that one is rebuilt.
      if (Number(result) !== 0) await rebuild(next);
      return next;
    }
    if (step.op === "upgrade") {
      const c = step.changes[0];
      try {
        const ok = await call("textContainerUpgrade", wrap("upgrade", {
          containerID: c.id, containerName: c.name, contentOffset: 0, contentLength: c.text.length, content: c.text, textColor: c.color,
        }));
        if (ok === false) throw new Error("The text wasn't updated");
        if (step.changes.length === 1) return next;
        // The scene is the new page's from here on: the rest follows in place.
        return { ...shown, scene: next.scene, containers: shown.containers.map((before) => (before.id === c.id ? c : before)) };
      } catch {
        // Falls through to a rebuild, which sets everything at once.
      }
    }
    await rebuild(next);
    return next;
  }

  async function pump() {
    if (busy) return;
    busy = true;
    try {
      // The newest page wanted is looked at again after every call, so a page that was
      // only wanted in between is never finished.
      while (wanted && wanted !== shown) {
        const next = wanted;
        try {
          const now_ = await apply(next);
          shown = now_;
          failures = 0;
          if (now_ === next) onShown(next);
        } catch (error) {
          // Not shown: what's on the glasses is unknown now, so the next try sets all of it.
          shown = null;
          failures += 1;
          onError(error);
          if (retry == null) {
            retry = timers.setTimeout(() => { retry = null; pump(); }, Math.min(8000, 500 * 2 ** Math.min(failures, 4)));
          }
          return;
        }
      }
    } finally {
      busy = false;
    }
  }

  return {
    /// Shows `description`, replacing anything still waiting to be shown.
    show(description) {
      wanted = description;
      if (retry == null) pump();
    },
    /// A swipe just happened: lists aren't rebuilt for a moment.
    noteScroll() { quietUntil = now() + 600; },
    /// The glasses' page is gone (the app was closed): the next page is made from nothing.
    forget() { shown = null; created = false; },
    /// The glasses may have cleared the page (their exit question does): it's set again.
    redraw() {
      if (!created) return;
      shown = null;
      if (wanted) { wanted = { ...wanted }; if (retry == null) pump(); }
    },
    /// Whether a page has been made, which the microphone needs first.
    get ready() { return created; },
    get shown() { return shown; },
    /// Closes the app on the glasses: 1 asks first, as their menu expects from a double-tap on the first page.
    async exit(mode = 1) {
      try { await call("shutDownPageContainer", mode); } catch (error) { onError(error); }
    },
  };
}
