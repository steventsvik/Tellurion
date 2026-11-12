// Puts a page description (see screens.js) on the glasses through the Even app's bridge.
// One call at a time, the newest page winning; text that changed in place is updated in
// place (no flicker), and only a different layout rebuilds the page. A call that fails or
// never answers is given up on and tried again later, so nothing waits on it for ever.

/// What it takes to get from the page that's showing to `next`.
/// { op: "create" } the first time, { op: "rebuild" } for another layout, { op:
/// "upgrade", changes } when only text or brightness differ, { op: "none" } when nothing does.
export function plan(shown, next) {
  if (!shown) return { op: "create" };
  if (layoutKey(shown) !== layoutKey(next)) return { op: "rebuild" };
  const changes = next.containers.filter((container, index) => {
    const before = shown.containers[index];
    return container.type === "text" && (before.text !== container.text || before.color !== container.color);
  });
  return changes.length ? { op: "upgrade", changes } : { op: "none" };
}

/// Everything about a page that can't be changed in place: which containers, where, and a
/// list's rows.
export function layoutKey(description) {
  return description.containers.map((c) => [c.type, c.id, c.x, c.y, c.w, c.h, c.capture ? 1 : 0,
    c.type === "list" ? JSON.stringify(c.items) : ""].join(",")).join("|");
}

/// The page as the bridge takes it: text and list containers, exactly one taking the input.
export function containerPayload(description) {
  const texts = [];
  const lists = [];
  for (const c of description.containers) {
    const base = {
      xPosition: c.x, yPosition: c.y, width: c.w, height: c.h, containerID: c.id, containerName: c.name,
      borderWidth: 0, paddingLength: 4, isEventCapture: c.capture ? 1 : 0,
    };
    if (c.type === "list") {
      lists.push({ ...base, itemContainer: { itemCount: c.items.length, itemWidth: c.w - 8, isItemSelectBorderEn: 1, itemName: c.items } });
    } else {
      texts.push({ ...base, content: c.text, textColor: c.color });
    }
  }
  return { containerTotalNum: texts.length + lists.length, textObject: texts, listObject: lists };
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

  async function apply(next) {
    const step = plan(created ? shown : null, next);
    if (step.op === "none") return;
    if (step.op === "create") {
      let result;
      try { result = await call("createStartUpPageContainer", wrap("create", containerPayload(next))); } catch { result = -1; }
      // Anything but success: a page may be there already (the app was reopened), and that one is rebuilt.
      if (Number(result) !== 0) await rebuild(next);
      created = true;
      return;
    }
    if (step.op === "upgrade") {
      try {
        for (const c of step.changes) {
          const ok = await call("textContainerUpgrade", wrap("upgrade", {
            containerID: c.id, containerName: c.name, contentOffset: 0, contentLength: c.text.length, content: c.text, textColor: c.color,
          }));
          if (ok === false) throw new Error("The text wasn't updated");
        }
        return;
      } catch {
        // Falls through to a rebuild, which sets everything at once.
      }
    }
    await rebuild(next);
  }

  async function pump() {
    if (busy) return;
    busy = true;
    try {
      while (wanted && wanted !== shown) {
        const next = wanted;
        try {
          await apply(next);
          shown = next;
          failures = 0;
          onShown(next);
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
    /// Whether a page has been made, which the microphone needs first.
    get ready() { return created; },
    get shown() { return shown; },
    /// Closes the app on the glasses: 1 asks first, as their menu expects from a double-tap on the first page.
    async exit(mode = 1) {
      try { await call("shutDownPageContainer", mode); } catch (error) { onError(error); }
    },
  };
}
