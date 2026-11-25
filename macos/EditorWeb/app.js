// Tellurion code editor: a VS Code–style workbench around Monaco.
// File access goes through the native `fs` message handler (EditorWebView.swift).
'use strict';

const fs = (op, args = {}) => window.webkit.messageHandlers.fs.postMessage({ op, ...args });
const log = (message) => fs('log', { message: String(message) }).catch(() => {});
window.addEventListener('error', (e) => log(`${e.message} @ ${e.filename}:${e.lineno}`));
window.addEventListener('unhandledrejection', (e) => log(`unhandled: ${e.reason?.stack || e.reason}`));
const $ = (id) => document.getElementById(id);

const state = {
  root: null,        // absolute folder path
  children: new Map(), // dir path -> [{name, path, isDir}]
  expanded: new Set(),
  selected: null,
  tabs: [],          // {path, model, viewState, savedVersion, mtime, conflict}
  active: null,      // path
  files: null,       // cached list for quick open
};
let editor = null;
let monacoRef = null;

// ---------- Icons ----------------------------------------------------------

const ICONS = {
  js: ['symbol-method', '#cbcb41'], mjs: ['symbol-method', '#cbcb41'], cjs: ['symbol-method', '#cbcb41'],
  jsx: ['symbol-method', '#519aba'], ts: ['symbol-method', '#519aba'], tsx: ['symbol-method', '#519aba'],
  json: ['json', '#cbcb41'], md: ['markdown', '#519aba'], py: ['symbol-method', '#4b8bbe'],
  swift: ['symbol-method', '#e37933'], zig: ['symbol-method', '#f7a41d'], rs: ['symbol-method', '#dea584'],
  go: ['symbol-method', '#519aba'], rb: ['ruby', '#cc3e44'], java: ['symbol-method', '#cc3e44'],
  c: ['symbol-method', '#519aba'], h: ['symbol-method', '#a074c4'], cpp: ['symbol-method', '#519aba'],
  css: ['symbol-color', '#519aba'], scss: ['symbol-color', '#f55385'], html: ['code', '#e37933'],
  sh: ['terminal', '#4d5a5e'], zsh: ['terminal', '#4d5a5e'], yml: ['settings', '#a074c4'], yaml: ['settings', '#a074c4'],
  toml: ['settings', '#6d8086'], lock: ['lock', '#6d8086'], png: ['file-media', '#a074c4'], jpg: ['file-media', '#a074c4'],
  svg: ['file-media', '#e37933'], gif: ['file-media', '#a074c4'], sql: ['database', '#f55385'], txt: ['file', '#cccccc'],
};
function iconFor(name) {
  if (name === 'package.json') return ['json', '#8dc149'];
  if (name.startsWith('.git')) return ['source-control', '#41535b'];
  if (name.startsWith('.env')) return ['settings', '#cbcb41'];
  const ext = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
  return ICONS[ext] || ['file', '#9d9d9d'];
}
function iconEl(name) {
  const [icon, color] = iconFor(name);
  const i = document.createElement('i');
  i.className = `codicon codicon-${icon} icon`;
  i.style.color = color;
  return i;
}
const basename = (p) => p.split('/').pop();
// macOS reports /tmp and /var as /private/tmp and /private/var; treat them as the same place.
const canonical = (p) => p.replace(/^\/private\/(tmp|var)\//, '/$1/');
const samePath = (a, b) => a === b || (a && b && canonical(a) === canonical(b));
const relative = (p) => {
  if (!state.root) return p;
  const [root, path] = [canonical(state.root), canonical(p)];
  return path.startsWith(root + '/') ? path.slice(root.length + 1) : p;
};

// ---------- Explorer -------------------------------------------------------

async function loadDir(path) {
  const entries = await fs('list', { path });
  state.children.set(path, entries);
  return entries;
}

function renderTree() {
  const tree = $('tree');
  const frag = document.createDocumentFragment();
  const walk = (dir, depth) => {
    for (const entry of state.children.get(dir) || []) {
      const row = document.createElement('div');
      row.className = 'row' + (state.selected === entry.path ? ' selected' : '');
      row.style.paddingLeft = `${8 + depth * 8}px`;
      row.dataset.path = entry.path;
      const twistie = document.createElement('i');
      twistie.className = 'twistie codicon ' +
        (entry.isDir ? (state.expanded.has(entry.path) ? 'codicon-chevron-down' : 'codicon-chevron-right') : '');
      row.append(twistie);
      if (!entry.isDir) row.append(iconEl(entry.name));
      const label = document.createElement('span');
      label.className = 'label';
      label.textContent = entry.name;
      row.append(label);
      if (!entry.isDir && state.tabs.some(t => t.path === entry.path && isDirty(t))) row.classList.add('modified');
      row.onclick = () => onRowClick(entry);
      frag.append(row);
      if (entry.isDir && state.expanded.has(entry.path)) walk(entry.path, depth + 1);
    }
  };
  if (state.root) walk(state.root, 0);
  tree.replaceChildren(frag);
  paintHeat();
}

async function onRowClick(entry) {
  state.selected = entry.path;
  if (entry.isDir) {
    if (state.expanded.has(entry.path)) {
      state.expanded.delete(entry.path);
    } else {
      state.expanded.add(entry.path);
      if (!state.children.has(entry.path)) await loadDir(entry.path);
    }
    renderTree();
  } else {
    renderTree();
    openFile(entry.path);
  }
}

async function refreshExplorer() {
  if (!state.root) return;
  const dirs = [state.root, ...state.expanded];
  await Promise.all(dirs.map(d => loadDir(d).catch(() => { state.expanded.delete(d); })));
  state.files = null;
  renderTree();
}

// ---------- Tabs & models --------------------------------------------------

const isDirty = (tab) => tab.model.getAlternativeVersionId() !== tab.savedVersion;

let reloading = false;      // true while we apply disk content (not the user typing)
let lastUserEdit = 0;

/**
 * Opens a file in a tab. `preview` tabs (files the agent only looks at) reuse a single
 * italic tab, as in VS Code, so following a codebase scan doesn't pile up tabs.
 * `quiet` skips error alerts (for follow mode, where a guessed path may not exist).
 */
async function openFile(path, { line, focus = true, preview = false, quiet = false, activate: show = true } = {}) {
  let tab = state.tabs.find(t => samePath(t.path, path));
  if (tab) path = tab.path;
  if (!tab) {
    let result;
    try { result = await fs('read', { path }); } catch (e) { return quiet ? null : showError(e); }
    if (result.error) return quiet ? null : showError(result.error);
    const uri = monacoRef.Uri.file(path);
    const model = monacoRef.editor.getModel(uri) || monacoRef.editor.createModel(result.content, undefined, uri);
    tab = { path, model, viewState: null, savedVersion: model.getAlternativeVersionId(), mtime: result.mtime,
            conflict: false, preview };
    model.onDidChangeContent(() => {
      if (!reloading) { tab.preview = false; lastUserEdit = Date.now(); }
      renderTabs();
    });
    if (preview) {
      const old = state.tabs.find(t => t.preview && !isDirty(t));
      if (old) replaceTab(old, tab); else state.tabs.push(tab);
    } else {
      state.tabs.push(tab);
    }
  } else if (!preview && tab.preview) {
    tab.preview = false;
  }
  if (show) activate(path, { focus });
  else renderTabs();
  if (line) { editor.revealLineInCenter(line); editor.setPosition({ lineNumber: line, column: 1 }); }
  return tab;
}

/** Swaps a preview tab for another in the same slot, without prompting. */
function replaceTab(old, tab) {
  const index = state.tabs.indexOf(old);
  state.tabs.splice(index, 1, tab);
  if (state.active === old.path) state.active = null;
  old.model.dispose();
}

function activate(path, { focus = true } = {}) {
  const current = state.tabs.find(t => t.path === state.active);
  if (current) current.viewState = editor.saveViewState();
  state.active = path;
  const tab = state.tabs.find(t => t.path === path);
  $('watermark').classList.toggle('hidden', !!tab);
  if (tab) {
    editor.setModel(tab.model);
    if (turn.files.has(canonical(tab.path))) applyTurnMarks(tab.path, tab.model);
    if (tab.viewState) editor.restoreViewState(tab.viewState);
    if (focus) editor.focus();
    state.selected = path;
  } else {
    editor.setModel(null);
  }
  renderTabs();
  renderBreadcrumbs();
  renderStatus();
  renderTree();
}

async function closeTab(path) {
  const index = state.tabs.findIndex(t => t.path === path);
  if (index < 0) return;
  const tab = state.tabs[index];
  if (isDirty(tab) && !confirm(`Do you want to save the changes you made to ${basename(path)}?\n\nOK saves, Cancel discards.`)) {
    // Discard.
  } else if (isDirty(tab)) {
    await save(tab);
  }
  state.tabs.splice(index, 1);
  tab.model.dispose();
  if (state.active === path) {
    const next = state.tabs[Math.min(index, state.tabs.length - 1)];
    state.active = null;
    activate(next ? next.path : null);
  } else {
    renderTabs();
  }
}

function renderTabs() {
  const bar = $('tabs');
  const counts = {};
  state.tabs.forEach(t => { const n = basename(t.path); counts[n] = (counts[n] || 0) + 1; });
  bar.replaceChildren(...state.tabs.map(tab => {
    const el = document.createElement('div');
    el.className = 'tab' + (tab.path === state.active ? ' active' : '') + (isDirty(tab) ? ' dirty' : '') +
      (tab.conflict ? ' conflict' : '') + (tab.preview ? ' preview' : '');
    el.ondblclick = () => { tab.preview = false; renderTabs(); };
    el.title = tab.conflict ? `${tab.path}\nChanged on disk while you have unsaved edits` : tab.path;
    el.append(iconEl(basename(tab.path)));
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = basename(tab.path);
    el.append(name);
    if (counts[basename(tab.path)] > 1) {
      const desc = document.createElement('span');
      desc.className = 'desc';
      desc.textContent = relative(tab.path).split('/').slice(-2, -1)[0] || '';
      el.append(desc);
    }
    const close = document.createElement('span');
    close.className = 'close';
    close.innerHTML = '<i class="codicon codicon-close"></i>';
    close.onclick = (e) => { e.stopPropagation(); closeTab(tab.path); };
    el.append(close);
    el.onclick = () => activate(tab.path);
    el.onauxclick = (e) => { if (e.button === 1) closeTab(tab.path); };
    return el;
  }));
  bar.querySelector('.tab.active')?.scrollIntoView({ inline: 'nearest' });
}

function renderBreadcrumbs() {
  const el = $('breadcrumbs');
  if (!state.active) { el.replaceChildren(); return; }
  const parts = relative(state.active).split('/');
  const nodes = [];
  parts.forEach((part, i) => {
    if (i > 0) { const c = document.createElement('i'); c.className = 'codicon codicon-chevron-right'; nodes.push(c); }
    if (i === parts.length - 1) nodes.push(iconEl(part));
    const s = document.createElement('span');
    s.textContent = part;
    nodes.push(s);
  });
  el.replaceChildren(...nodes);
}

// ---------- Saving & disk sync ----------------------------------------------

async function save(tab = state.tabs.find(t => t.path === state.active)) {
  if (!tab) return;
  const result = await fs('write', { path: tab.path, content: tab.model.getValue() });
  if (result.error) return showError(result.error);
  tab.savedVersion = tab.model.getAlternativeVersionId();
  tab.mtime = result.mtime;
  tab.conflict = false;
  renderTabs();
  renderTree();
}

// Agents edit files constantly; keep open files in sync with the disk.
async function syncWithDisk() {
  if (!state.tabs.length || document.hidden) return;
  const mtimes = await fs('stat', { paths: state.tabs.map(t => t.path) });
  for (const tab of state.tabs) {
    const mtime = mtimes[tab.path];
    if (mtime == null || mtime === tab.mtime) continue;
    if (isDirty(tab)) { tab.conflict = true; continue; }
    const result = await fs('read', { path: tab.path });
    if (result.error) continue;
    tab.mtime = result.mtime;
    if (result.content !== tab.model.getValue()) {
      const isActive = tab.path === state.active;
      const view = isActive ? editor.saveViewState() : null;
      reloading = true;
      tab.model.pushEditOperations([], [{ range: tab.model.getFullModelRange(), text: result.content }], () => null);
      reloading = false;
      tab.savedVersion = tab.model.getAlternativeVersionId();
      if (isActive && view) editor.restoreViewState(view);
    }
  }
  renderTabs();
}

// ---------- Status bar ------------------------------------------------------

let branch = '';
function renderStatus() {
  $('sb-branch').innerHTML = branch ? `<i class="codicon codicon-source-control"></i>${escapeHTML(branch)}` : '';
  const model = editor?.getModel();
  if (!model) { ['sb-position', 'sb-indent', 'sb-eol', 'sb-language'].forEach(id => $(id).textContent = ''); return; }
  const pos = editor.getPosition();
  const sel = editor.getSelection();
  const selected = sel && !sel.isEmpty() ? ` (${model.getValueInRange(sel).length} selected)` : '';
  $('sb-position').textContent = pos ? `Ln ${pos.lineNumber}, Col ${pos.column}${selected}` : '';
  const opts = model.getOptions();
  $('sb-indent').textContent = opts.insertSpaces ? `Spaces: ${opts.tabSize}` : `Tab Size: ${opts.tabSize}`;
  $('sb-eol').textContent = model.getEOL() === '\n' ? 'LF' : 'CRLF';
  const lang = monacoRef.languages.getLanguages().find(l => l.id === model.getLanguageId());
  $('sb-language').textContent = lang?.aliases?.[0] || model.getLanguageId();
}
const escapeHTML = (s) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// ---------- Quick open (⌘P) ------------------------------------------------

let qoItems = [];
let qoIndex = 0;

async function quickOpen() {
  if (!state.root) return;
  $('quickopen').classList.remove('hidden');
  const input = $('qo-input');
  input.value = '';
  input.focus();
  if (!state.files) state.files = await fs('files');
  filterQuickOpen();
}

function fuzzy(query, text) {
  // Subsequence match; rewards consecutive and word-start hits.
  let score = 0, ti = 0, streak = 0; const hits = [];
  const q = query.toLowerCase(), t = text.toLowerCase();
  for (const ch of q) {
    const found = t.indexOf(ch, ti);
    if (found < 0) return null;
    streak = found === ti ? streak + 1 : 0;
    score += 1 + streak * 2 + (found === 0 || '/._-'.includes(text[found - 1]) ? 3 : 0);
    hits.push(found);
    ti = found + 1;
  }
  return { score: score - text.length * 0.01, hits };
}

function filterQuickOpen() {
  const query = $('qo-input').value.trim();
  const files = state.files || [];
  let results;
  if (!query) {
    const recent = state.tabs.map(t => relative(t.path));
    results = [...recent, ...files.filter(f => !recent.includes(f))].slice(0, 60).map(f => ({ f, hits: [] }));
  } else {
    results = [];
    for (const f of files) {
      const name = f.split('/').pop();
      const m = fuzzy(query, name) || fuzzy(query, f);
      if (m) results.push({ f, hits: fuzzy(query, name)?.hits || [], score: m.score + (fuzzy(query, name) ? 10 : 0) });
    }
    results.sort((a, b) => b.score - a.score);
    results = results.slice(0, 60);
  }
  qoItems = results;
  qoIndex = 0;
  renderQuickOpen();
}

function renderQuickOpen() {
  $('qo-list').replaceChildren(...qoItems.map((r, i) => {
    const el = document.createElement('div');
    el.className = 'qo-item' + (i === qoIndex ? ' active' : '');
    const name = r.f.split('/').pop();
    const nameEl = document.createElement('span');
    nameEl.className = 'name';
    nameEl.innerHTML = [...name].map((c, ci) => r.hits.includes(ci) ? `<b>${escapeHTML(c)}</b>` : escapeHTML(c)).join('');
    const dir = document.createElement('span');
    dir.className = 'dir';
    dir.textContent = r.f.includes('/') ? r.f.slice(0, r.f.lastIndexOf('/')) : '';
    el.append(iconEl(name), nameEl, dir);
    el.onmousedown = (e) => { e.preventDefault(); qoIndex = i; acceptQuickOpen(); };
    return el;
  }));
  $('qo-list').children[qoIndex]?.scrollIntoView({ block: 'nearest' });
}

function acceptQuickOpen() {
  const item = qoItems[qoIndex];
  closeQuickOpen();
  if (item) openFile(state.root + '/' + item.f);
}
function closeQuickOpen() {
  $('quickopen').classList.add('hidden');
  if (editor?.getModel()) editor.focus();
}

$('qo-input').addEventListener('input', filterQuickOpen);
$('qo-input').addEventListener('keydown', (e) => {
  if (e.key === 'ArrowDown') { qoIndex = Math.min(qoIndex + 1, qoItems.length - 1); renderQuickOpen(); e.preventDefault(); }
  else if (e.key === 'ArrowUp') { qoIndex = Math.max(qoIndex - 1, 0); renderQuickOpen(); e.preventDefault(); }
  else if (e.key === 'Enter') { acceptQuickOpen(); e.preventDefault(); }
  else if (e.key === 'Escape') { closeQuickOpen(); e.preventDefault(); }
});
$('qo-input').addEventListener('blur', () => setTimeout(closeQuickOpen, 100));

// ---------- Layout ----------------------------------------------------------

(() => {
  const sash = $('sash');
  const explorer = $('explorer');
  sash.addEventListener('mousedown', (e) => {
    sash.classList.add('active');
    const startX = e.clientX, startW = explorer.offsetWidth;
    const move = (ev) => { explorer.style.width = `${Math.max(140, Math.min(500, startW + ev.clientX - startX))}px`; };
    const up = () => { sash.classList.remove('active'); removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
    addEventListener('mousemove', move);
    addEventListener('mouseup', up);
  });
})();

function toggleExplorer() {
  const hidden = $('explorer').classList.toggle('collapsed');
  $('sash').classList.toggle('hidden', hidden);
  const button = $('toggle-explorer');
  button.className = `codicon codicon-layout-sidebar-left${hidden ? '-off' : ''}`;
  button.title = `${hidden ? 'Show' : 'Hide'} Explorer (⌘B)`;
}
$('toggle-explorer').onclick = toggleExplorer;

$('refresh').onclick = refreshExplorer;
$('collapse').onclick = () => { state.expanded.clear(); renderTree(); };

// Shortcuts that should work anywhere in the panel, not only inside the editor.
document.addEventListener('keydown', (e) => {
  if (!e.metaKey) return;
  const key = e.key.toLowerCase();
  if (key === 'p' && !e.shiftKey) { e.preventDefault(); quickOpen(); }
  else if (key === 's') { e.preventDefault(); save(); }
  else if (key === 'w') { e.preventDefault(); if (state.active) closeTab(state.active); }
  else if (key === 'b') { e.preventDefault(); toggleExplorer(); }
}, true);

function showError(message) {
  log(message);
  alert(String(message));
}

// ---------- Terminal theme ----------------------------------------------------

const hex = (c) => c.replace('#', '');
const toRGB = (c) => { const h = hex(c); return [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16)); };
const toHex = (rgb) => '#' + rgb.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('');
const mix = (a, b, t) => { const [x, y] = [toRGB(a), toRGB(b)]; return toHex(x.map((v, i) => v + (y[i] - v) * t)); };
const luminance = (c) => {
  const [r, g, b] = toRGB(c).map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const contrast = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
/** Moves a palette color toward the foreground until it's readable on the background. */
function readable(color, bg, fg, min = 3.2) {
  let c = color;
  for (let i = 0; i < 12 && contrast(c, bg) < min; i++) c = mix(c, fg, 0.18);
  return c;
}

let terminalTheme = null;

function applyTheme(t) {
  if (!monacoRef) { terminalTheme = t; return; }
  const bg = t.background, fg = t.foreground, p = t.palette;
  const dark = luminance(bg) < 0.4;
  const pick = (...indices) => readable(p[indices.find(i => p[i]) ?? 7] || fg, bg, fg);

  // Workbench: shades of the terminal background, like the terminal's own chrome.
  const vars = {
    '--bg-editor': bg,
    '--bg-side': mix(bg, fg, dark ? 0.035 : 0.05),
    '--bg-tab-inactive': mix(bg, fg, dark ? 0.035 : 0.05),
    '--bg-hover': mix(bg, fg, 0.08),
    '--bg-selected': mix(bg, fg, 0.14),
    '--bg-input': mix(bg, fg, 0.1),
    '--border': mix(bg, '#967446', 0.32),
    '--fg': fg,
    '--fg-muted': mix(fg, bg, 0.35),
    '--fg-dim': mix(fg, bg, 0.55),
    // Tellurion: gold accent and bronze hairlines on the terminal's own background.
    '--accent': '#deb86e',
    '--font-ui': '"JetBrains Mono", Menlo, monospace',
    '--modified': pick(11, 3),
    '--font-mono': `${t.fontFamily ? `"${t.fontFamily}", ` : ''}"JetBrains Mono", Menlo, monospace`,
  };
  for (const [k, v] of Object.entries(vars)) document.documentElement.style.setProperty(k, v);

  // Syntax colors from the ANSI palette (bright variants first, as terminal themes intend).
  const c = {
    keyword: pick(13, 5, 12), string: pick(10, 2, 11), number: pick(11, 3, 14), type: pick(14, 6, 12),
    func: pick(12, 4, 14), tag: pick(9, 1), attr: pick(11, 3), regexp: pick(9, 1),
    comment: mix(fg, bg, 0.5), delimiter: mix(fg, bg, 0.2),
  };
  const rule = (token, color, fontStyle) => ({ token, foreground: hex(color), ...(fontStyle ? { fontStyle } : {}) });
  monacoRef.editor.defineTheme('terminal', {
    base: dark ? 'vs-dark' : 'vs',
    inherit: true,
    rules: [
      rule('', fg), rule('comment', c.comment, 'italic'), rule('keyword', c.keyword), rule('storage', c.keyword),
      rule('string', c.string), rule('string.escape', c.number), rule('number', c.number), rule('constant', c.number),
      rule('type', c.type), rule('type.identifier', c.type), rule('namespace', c.type), rule('predefined', c.func),
      rule('function', c.func), rule('identifier', fg), rule('variable', fg), rule('delimiter', c.delimiter),
      rule('operator', c.delimiter), rule('tag', c.tag), rule('attribute.name', c.attr),
      rule('attribute.value', c.string), rule('regexp', c.regexp), rule('annotation', c.attr),
      rule('string.key.json', c.func), rule('string.value.json', c.string), rule('key', c.func),
    ],
    colors: {
      'editor.background': bg,
      'editor.foreground': fg,
      'editorCursor.foreground': t.cursor || fg,
      'editor.selectionBackground': (t.selectionBackground || mix(bg, fg, 0.25)) + 'aa',
      'editor.inactiveSelectionBackground': (t.selectionBackground || mix(bg, fg, 0.25)) + '55',
      'editor.lineHighlightBackground': mix(bg, fg, 0.05),
      'editor.lineHighlightBorder': mix(bg, fg, 0.05),
      'editorLineNumber.foreground': mix(fg, bg, 0.62),
      'editorLineNumber.activeForeground': fg,
      'editorIndentGuide.background1': mix(bg, fg, 0.1),
      'editorIndentGuide.activeBackground1': mix(bg, fg, 0.25),
      'editorGutter.background': bg,
      'editorWidget.background': mix(bg, fg, 0.05),
      'editorWidget.border': mix(bg, fg, 0.15),
      'editorSuggestWidget.selectedBackground': mix(bg, fg, 0.14),
      'editor.findMatchBackground': (t.selectionBackground || c.number) + '88',
      'editor.findMatchHighlightBackground': c.number + '33',
      'minimap.background': bg,
      'scrollbarSlider.background': mix(bg, fg, 0.18) + '88',
      'scrollbarSlider.hoverBackground': mix(bg, fg, 0.28) + 'aa',
      'focusBorder': vars['--accent'],
    },
  });
  monacoRef.editor.setTheme('terminal');
  const fontSize = t.fontSize || 13;
  editor.updateOptions({ fontFamily: vars['--font-mono'], fontSize, lineHeight: Math.round(fontSize * 1.55) });
  document.fonts.ready.then(() => monacoRef.editor.remeasureFonts());
}

// ---------- Agent panel -------------------------------------------------------

const ACTIONS = {
  read: ['eye', 'Read', '--act-read'], edit: ['edit', 'Edit', '--act-edit'], write: ['new-file', 'Write', '--act-write'],
  run: ['terminal', 'Run', '--act-run'], search: ['search', 'Search', '--act-search'], web: ['globe', 'Web', '--act-web'],
  agent: ['hubot', 'Agent', '--act-agent'], todo: ['checklist', 'Todos', '--act-todo'], other: ['tools', '', '--fg-muted'],
};
const AGENT_BRANDS = {
  claude: ['#D97757', 'claude.svg'], codex: ['#000000', 'openai.svg'], gemini: ['#4285F4', 'gemini_cli.svg'],
  opencode: ['#808080', 'opencode.svg'], amp: ['#F34E3F', 'amp.svg'], copilot: ['#8534F3', 'copilot.svg'],
  cursor: ['#26251E', 'cursor.svg'], droid: ['#FFFFFF', 'droid.svg'], goose: ['#101010', 'goose.svg'],
  qwen: ['#615CED', 'qwen.svg'], kimi: ['#101010', 'kimi.svg'], mistral: ['#FA520F', 'mistral.svg'],
  kiro: ['#7940FF', 'kiro.svg'], antigravity: ['#4285F4', 'antigravity.svg'], hermes: ['#7C3AED', 'hermes.png'],
  aider: ['#14965A', null], crush: ['#6B50FF', null], local: ['#4EC9A0', null],
};

/** Another agent's color in a shared tab (its lane, comet and tags): its brand, lifted
 *  when the brand is too dark to see on the editor's dark background. */
function peerColor(kind) {
  const hex = (AGENT_BRANDS[kind] || ['#9aa0a6'])[0];
  const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 70 ? '#9aa0a6' : hex;
}

/** The tag on a sub-agent's or another agent's item in the timeline. */
function subTag(item) {
  if (!item.peer) return Object.assign(el('span', 'sub-tag', `↳ ${item.sub}`), { title: `Sub-agent: ${item.sub}` });
  const tag = Object.assign(el('span', 'sub-tag peer', `● ${item.sub}`), { title: `Another agent in this tab: ${item.peer}` });
  tag.style.color = peerColor(item.peerKind);
  return tag;
}
const agent = { status: null, tools: new Map(), follow: true, atBottom: true };

function agentAbs(path) {
  if (!path) return null;
  return path.startsWith('/') ? path : (state.root ? `${state.root}/${path}` : null);
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

/** Inline `code` spans in agent text; everything else stays plain text. */
function richText(text) {
  const frag = document.createDocumentFragment();
  text.split(/(`[^`\n]+`)/).forEach(part => {
    if (part.startsWith('`') && part.endsWith('`') && part.length > 2) frag.append(el('code', null, part.slice(1, -1)));
    else frag.append(part);
  });
  return frag;
}

function codeBlock(lines, cls, max = 10) {
  const box = el('div', 'code' + (cls ? ' ' + cls : ''));
  lines.slice(0, max).forEach(([kind, text]) => box.append(el('div', kind, text || ' ')));
  if (lines.length > max) box.append(el('div', 'more', `… ${lines.length - max} more lines`));
  return box;
}

function renderItem(item) {
  const node = el('div', 'item ' + item.kind);
  if (item.kind === 'prompt') {
    if (!item.sub && item.time) node.dataset.time = Date.parse(item.time) || '';
    if (item.peer) node.append(subTag(item));
    node.append(el('div', 'label', 'YOU'));
    const t = el('div', 'text');
    t.append(richText(item.text));
    node.append(t);
  } else if (item.kind === 'thinking') {
    node.append(el('div', 'label', 'THINKING'));
    const t = el('div', 'text', item.text || 'Reasoning hidden by the agent');
    t.onclick = () => node.classList.toggle('open');
    node.append(t);
  } else if (item.kind === 'message') {
    if (item.sub) node.append(subTag(item));
    const t = el('div', 'text'); t.append(richText(item.text)); node.append(t);
  } else if (item.kind === 'tool') {
    const [icon, verb, color] = ACTIONS[item.action] || ACTIONS.other;
    node.style.setProperty('--c', `var(${color})`);
    const head = el('div', 'head');
    if (item.sub) head.append(subTag(item));
    const chip = el('span', 'chip');
    chip.append(el('i', `codicon codicon-${icon}`), verb || item.tool);
    head.append(chip);
    const path = agentAbs(item.path);
    if (path) {
      const target = el('span', 'target link', relative(path));
      target.title = path;
      target.onclick = () => openFile(path);
      head.append(target);
    } else if (item.pattern || item.query || item.description) {
      head.append(el('span', 'target', item.pattern || item.query || item.description));
    }
    const mark = el('span', 'pending');
    head.append(mark);
    node.append(head);
    if (item.command) node.append(codeBlock(item.command.split('\n').map(l => ['', l]), 'cmd', 6));
    if (item.patch) {
      const lines = item.patch.split('\n').filter(l => /^[+-]/.test(l) && !/^(\+\+\+|---)/.test(l))
        .map(l => [l[0] === '+' ? 'add' : 'del', l.slice(1)]);
      node.append(codeBlock(lines, '', 14));
    } else if (item.old != null || item.new != null) {
      const lines = [
        ...(item.old ? item.old.split('\n').map(l => ['del', l]) : []),
        ...(item.new ? item.new.split('\n').map(l => ['add', l]) : []),
      ];
      node.append(codeBlock(lines, '', 14));
    }
    if (item.todos) {
      const list = el('div', 'todos');
      item.todos.forEach(t => {
        const mark = t.status === 'completed' ? '✓' : t.status === 'in_progress' ? '◐' : '○';
        list.append(el('div', t.status, `${mark} ${t.text}`));
      });
      node.append(list);
    }
    agent.tools.set(item.id, { node, mark, item });
  } else if (item.kind === 'result') {
    const tool = agent.tools.get(item.id);
    if (!tool) return null;
    tool.mark.className = item.error ? 'codicon codicon-error err-mark' : 'codicon codicon-check done-mark';
    tool.node.classList.remove('live');
    const text = (item.text || '').trim();
    const showOutput = item.error || tool.item.action === 'run' || tool.item.action === 'search';
    if (text && showOutput) {
      const lines = text.split('\n');
      const out = el('div', 'result' + (item.error ? ' error' : ''),
        lines.slice(0, 8).join('\n') + (lines.length > 8 ? `\n… ${lines.length - 8} more lines` : ''));
      tool.node.append(out);
    }
    return null;
  }
  return node;
}

function agentItems(items, reset) {
  const feed = $('agent-feed');
  if (reset) { feed.replaceChildren(); agent.tools.clear(); }
  if (window.pov) { if (reset) window.pov.reset(items); else items.forEach(i => window.pov.item(i, false)); }
  window.starmap?.items(items, reset);
  const stick = feed.scrollHeight - feed.scrollTop - feed.clientHeight < 40;
  for (const item of items) {
    const node = renderItem(item);
    if (node) {
      if (agent.status?.kind === 'codex') feed.querySelector('.agent-empty')?.remove();
      feed.append(node);
    }
    if (!reset && item.kind === 'prompt' && !item.sub) clearTurn();
    if (!reset && agent.follow && panelVisible && (item.kind === 'tool' || item.kind === 'result')) followAction(item);
  }
  if (reset && agent.follow && panelVisible) {
    // Opened mid-turn: pick up the action the agent is in the middle of.
    const open = [...agent.tools.values()].filter(t => !t.mark.className.includes('mark'));
    const current = open[open.length - 1];
    if (current && current.item.action !== 'edit' && current.item.action !== 'write') followAction(current.item);
    for (const t of open) if (t.item.action === 'edit' || t.item.action === 'write') {
      const path = agentAbs(t.item.path);
      if (path) laneFor(t.item).editing.set(canonical(path), Date.now());
    }
  }
  // Only the newest item shimmers while the agent works.
  feed.querySelectorAll('.item.live').forEach(n => n.classList.remove('live'));
  if (agent.status?.badge === 'working') feed.lastElementChild?.classList.add('live');
  if (!feed.children.length) {
    feed.append(Object.assign(el('div', 'agent-empty'), { innerHTML: 'Waiting for the agent…' }));
  }
  if (stick || reset) feed.scrollTop = feed.scrollHeight;
  $('agent').classList.remove('empty');
  decoratePrompts();
}

// Turns the app snapshotted when they started (see TurnCheckpoints): [{id, time, title}].
let checkpoints = [];

function setCheckpoints(list) {
  checkpoints = list || [];
  decoratePrompts();
}

// "Restore to before this" on each of your prompts that has a checkpoint: the one taken
// within half a minute of the prompt.
function decoratePrompts() {
  for (const node of $('agent-feed').querySelectorAll('.item.prompt[data-time]')) {
    const time = Number(node.dataset.time);
    let best = null;
    for (const c of checkpoints) {
      const gap = Math.abs(c.time - time);
      if (gap < 30000 && (!best || gap < Math.abs(best.time - time))) best = c;
    }
    let button = node.querySelector('.restore');
    if (!best) { button?.remove(); continue; }
    if (!button) {
      button = el('button', 'restore');
      button.append(el('i', 'codicon codicon-discard'), 'Restore to before this');
      button.title = 'Put your files back to how they were before this prompt (asks first)';
      node.append(button);
    }
    button.onclick = (e) => { e.stopPropagation(); fs('restore', { id: best.id }); };
  }
}

function agentStatus(status) {
  agent.status = status;
  window.pov?.status(status);
  window.starmap?.status(status);
  const logo = $('agent-logo'), pill = $('agent-pill');
  if (!status) {
    logo.style.display = 'none';
    $('agent-name').textContent = 'AGENT';
    pill.className = 'pill';
    $('agent-task').textContent = '';
    return;
  }
  const [brand, file] = AGENT_BRANDS[status.kind] || ['#777', null];
  document.documentElement.style.setProperty('--agent-brand', brand === '#000000' ? '#8a8a8a' : brand);
  document.documentElement.style.setProperty('--agent-label', JSON.stringify(status.name.replace(/ Code$/, '')));
  logo.style.display = 'inline-flex';
  logo.style.background = brand;
  logo.classList.toggle('dark-glyph', status.kind === 'droid');
  logo.replaceChildren(...(file ? [Object.assign(el('img'), { src: `logos/${file}` })] : []));
  $('agent-name').textContent = status.name.toUpperCase();
  const colors = { working: '--act-think', permission: '--act-todo', input: '--act-todo', done: '--act-write', error: '--act-error' };
  const color = colors[status.badge];
  pill.textContent = status.activity;
  pill.className = 'pill' + (status.activity ? ' show' : '') + (status.badge === 'working' ? ' working' : '');
  pill.style.color = color ? `var(${color})` : 'var(--fg-muted)';
  pill.style.background = color ? `color-mix(in srgb, var(${color}) 16%, transparent)` : 'var(--bg-hover)';
  $('agent-task').textContent = status.detail || status.task || '';
  const feed = $('agent-feed');
  feed.querySelectorAll('.item.live').forEach(n => n.classList.remove('live'));
  if (status.badge === 'working') feed.lastElementChild?.classList.add('live');
  if (status.live === 'no' && !agent.tools.size && feed.querySelector('.agent-empty')) {
    feed.querySelector('.agent-empty').innerHTML =
      `${escapeHTML(status.name)} is running. Its live activity appears after your next prompt.`;
  }
}

// ---------- Follow mode: show the agent's actions in the editor ------------------
//
// Every agent — the main one and each sub-agent — gets a lane with its own queue, so they
// animate in parallel. With one active lane, actions play in the main editor (preview
// tabs). With two or more, the editor splits into a live grid: one read-only pane per
// agent, each jumping to exactly the code that agent is reading or changing.
// Reads show as soon as the agent issues them; edits animate as soon as they land on disk.

const agentMarks = new Map(); // path -> timeout for the tab/explorer marker

function markFile(path, kind) {
  noteHeat(path, kind);
  clearTimeout(agentMarks.get(path));
  const apply = () => document.querySelectorAll('.tab, .row').forEach(n => {
    if (samePath(n.title, path) || samePath(n.dataset.path, path)) { n.classList.remove('agent-read', 'agent-edit'); n.classList.add(`agent-${kind}`); }
  });
  apply();
  requestAnimationFrame(apply);
  agentMarks.set(path, setTimeout(() => {
    document.querySelectorAll('.agent-read, .agent-edit').forEach(n => {
      if (samePath(n.title, path) || samePath(n.dataset.path, path)) n.classList.remove('agent-read', 'agent-edit');
    });
  }, 5000));
}

// ---------- Heat trail -----------------------------------------------------
// Files glow in the Explorer by how recently and how much the agent touched them: edits
// burn ember-orange, reads glow faint cyan, and both cool over a few minutes. Folders show
// a spark when something inside is hot, and the last five files touched are numbered, so
// the agent's path through the code stays visible.

const heat = new Map(); // canonical path -> { path, edits, reads, lines, last, seq, flash }
let heatSeq = 0;

function heatEntry(path) {
  const key = canonical(path);
  let entry = heat.get(key);
  if (!entry) { entry = { path, edits: 0, reads: 0, lines: 0, last: 0, seq: 0, flash: false }; heat.set(key, entry); }
  return entry;
}

function noteHeat(path, kind) {
  if (!path) return;
  const entry = heatEntry(path);
  if (kind === 'edit') entry.edits++; else entry.reads++;
  entry.last = Date.now();
  entry.seq = ++heatSeq;
  entry.flash = true;
  paintHeat();
}

function heatLines(path, lines) {
  if (path && lines > 0) heatEntry(path).lines += lines;
}

/** 0…1: hot right after a big change, cooling over a few minutes. */
function heatLevel(entry, now) {
  const recency = Math.exp(-(now - entry.last) / 240000);
  const amount = Math.min(1, entry.edits * 0.3 + entry.lines / 60 + entry.reads * 0.1);
  return Math.max(0, Math.min(1, recency * (0.45 + 0.55 * amount)));
}

function paintHeat() {
  const now = Date.now();
  const trail = [...heat.values()].filter(e => heatLevel(e, now) > 0.05).sort((a, b) => b.seq - a.seq).slice(0, 5);
  const rank = new Map(trail.map((e, i) => [canonical(e.path), i + 1]));
  // A folder is as hot as the hottest thing inside it.
  const folders = new Map();
  const root = state.root ? canonical(state.root) : null;
  for (const entry of heat.values()) {
    const level = heatLevel(entry, now) * (entry.edits ? 1 : 0.45);
    let dir = canonical(entry.path);
    while (dir.includes('/') && (!root || dir.length > root.length)) {
      dir = dir.slice(0, dir.lastIndexOf('/'));
      folders.set(dir, Math.max(folders.get(dir) || 0, level));
    }
  }
  document.querySelectorAll('#tree .row').forEach(row => {
    const key = canonical(row.dataset.path || '');
    const entry = heat.get(key);
    const level = entry ? heatLevel(entry, now) : (folders.get(key) || 0) * 0.8;
    row.classList.remove('heat-edit', 'heat-read', 'heat-dir');
    let badge = row.querySelector('.trail');
    if (level < 0.04) { row.style.removeProperty('--heat'); badge?.remove(); return; }
    row.style.setProperty('--heat', level.toFixed(3));
    row.classList.add(entry ? (entry.edits ? 'heat-edit' : 'heat-read') : 'heat-dir');
    const place = entry && rank.get(key);
    if (place) {
      if (!badge) { badge = el('span', 'trail'); row.append(badge); }
      badge.textContent = place;
      badge.title = `${place === 1 ? 'Most recently' : `#${place} most recently`} touched by ${agentName()}`
        + (entry.edits ? ` · ${entry.edits} edit${entry.edits === 1 ? '' : 's'}` : '')
        + (entry.lines ? ` · ${entry.lines} lines` : '');
    } else {
      badge?.remove();
    }
    if (entry?.flash) {
      row.classList.remove('heat-flash');
      void row.offsetWidth;
      row.classList.add('heat-flash');
    }
  });
  for (const entry of heat.values()) entry.flash = false;
}

setInterval(paintHeat, 10000);

/** Stagger classes (.agent-d-N / .agent-w-N) so animations can run line by line. */
(() => {
  const rules = [];
  for (let i = 0; i < 120; i++) rules.push(`.agent-d-${i}{animation-delay:${i * 38}ms!important}`);
  for (let i = 0; i < 48; i++) rules.push(`.agent-w-${i}{animation-delay:${i * 40}ms!important}`);
  document.head.append(Object.assign(document.createElement('style'), { textContent: rules.join('\n') }));
})();

const agentName = () => (agent.status?.name || 'Agent').replace(/ Code$/, '');

/** Don't pull the file out from under someone typing in the editor, or who just picked a
 *  file to look at (from the map), unless it's that pick being shown. */
let userPickedAt = 0, showingPick = false;
const userIsEditing = () => !showingPick
  && ((editor?.hasTextFocus() && Date.now() - lastUserEdit < 6000) || Date.now() - userPickedAt < 12000);

/** Opens a file the user picked, holding off follow mode for a moment so it stays put. */
async function openPicked(path, change) {
  userPickedAt = Date.now();
  showingPick = true;
  try {
    if (change) await revisitChange(change); else await openFile(path);
  } finally {
    showingPick = false;
    userPickedAt = Date.now();
  }
}

/** Opens a file the user picked at a line (a symbol on the map, a code reference). */
async function openPickedAt(path, line) {
  userPickedAt = Date.now();
  showingPick = true;
  try { await openFile(path, { line }); } finally { showingPick = false; userPickedAt = Date.now(); }
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const LANE_COLORS = ['--act-think', '--act-read', '--act-edit', '--act-write', '--act-agent', '--act-search'];
const lanes = new Map(); // key -> lane
let split = null;        // { grid } while the split view is showing
let viewSeq = 0;

// ----- Where an action looks at code -----------------------------------------

async function looksFor(item) {
  const base = item.cwd || state.root;
  const abs = (p) => {
    if (!p) return null;
    p = p.replace(/^['"]|['"]$/g, '');
    if (p.startsWith('~') || p.includes('$')) return null;
    const full = p.startsWith('/') ? p : (base ? `${base}/${p.replace(/^\.\//, '')}` : null);
    // Claude's own scratch files (saved tool output) aren't the user's code.
    return full && !full.includes('/.claude/projects/') ? full : null;
  };
  const looks = [];
  if (item.action === 'read' && item.path) {
    const start = Math.max(1, item.offset || 1);
    const path = abs(item.path);
    if (path) looks.push({ path, start, end: item.limit ? start + item.limit - 1 : null });
    return looks;
  }
  if (item.tool === 'Grep' && item.pattern && item.path && /\.[A-Za-z0-9]+$/.test(item.path)) {
    const path = abs(item.path);
    if (path) looks.push({ path, grep: item.pattern });
    return looks;
  }
  if (!item.command) return looks;

  const FILE = String.raw`([^\s|;&<>()]+\.[A-Za-z0-9_]+|[^\s|;&<>()]*/[^\s|;&<>()]+)`;
  const addFiles = async (tokens, range) => {
    for (const token of tokens) {
      for (const file of await expandGlob(token, base)) {
        const path = abs(file);
        if (path) looks.push({ path, ...range });
      }
    }
  };
  // Loops like `for f in a.js dir/*.js; do cat -n $f; done` read every listed file.
  for (const m of item.command.matchAll(/for\s+(\w+)\s+in\s+([^;]+?);\s*do\b([\s\S]*?)\bdone/g)) {
    const [, , list, body] = m;
    const range = body.match(/sed\s+-n\s+['"]?(\d+),(\d+)p/);
    await addFiles(list.trim().split(/\s+/), range ? { start: +range[1], end: +range[2] } : { start: 1, end: null });
  }
  const command = item.command.replace(/for\s+\w+\s+in\s+[^;]+?;\s*do\b[\s\S]*?\bdone/g, ' ');
  for (const segment of command.split(/;|&&|\|\||\n/)) {
    let m;
    if ((m = segment.match(new RegExp(String.raw`nl\s+(?:-\w+\s+)*${FILE}\s*\|\s*sed\s+-n\s+['"]?(\d+),(\d+)p`)))) {
      await addFiles([m[1]], { start: +m[2], end: +m[3] });
    } else if ((m = segment.match(new RegExp(String.raw`sed\s+-n\s+['"]?(\d+),(\d+)p['"]?\s+${FILE}`)))) {
      await addFiles([m[3]], { start: +m[1], end: +m[2] });
    } else if ((m = segment.match(new RegExp(String.raw`head\s+(?:-n\s*|-)(\d+)\s+${FILE}`)))) {
      await addFiles([m[2]], { start: 1, end: +m[1] });
    } else if ((m = segment.match(new RegExp(String.raw`tail\s+(?:-n\s*|-)(\d+)\s+${FILE}`)))) {
      await addFiles([m[2]], { start: -m[1], end: null });
    } else if ((m = segment.match(/(?:^|\s)(?:rg|grep)\s+((?:-[\w-]+\s+)*)(?:-e\s+)?("[^"]*"|'[^']*'|\S+)\s+([^|]+)/))) {
      const pattern = m[2].replace(/^['"]|['"]$/g, '');
      const targets = m[3].trim().split(/\s+/).filter(t => /\.[A-Za-z0-9]+$|\*/.test(t) && !t.startsWith('-'));
      await addFiles(targets.slice(0, 6), { grep: pattern });
    } else if ((m = segment.match(/(?:^|\s)(?:cat|bat|less)\s+((?:-\w+\s+)*)([^|<>]+)/))) {
      const files = m[2].trim().split(/\s+/).filter(t => /\.[A-Za-z0-9]+$|\//.test(t));
      const head = segment.match(/\|\s*head\s+(?:-n\s*|-)(\d+)/);
      await addFiles(files.slice(0, 8), { start: 1, end: head ? +head[1] : null });
    }
  }
  return looks.slice(0, 10);
}

async function expandGlob(token, base) {
  if (!token.includes('*')) return [token];
  if (!state.root || (base && !samePath(base, state.root))) return [];
  if (!state.files) state.files = await fs('files');
  const re = new RegExp('^' + token.replace(/^\.\//, '').replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\u0000/g, '.*') + '$');
  return state.files.filter(f => re.test(f)).slice(0, 8);
}

/** Lines of `model` matching a grep pattern (basic regex syntax translated). */
function grepLines(model, pattern) {
  let re;
  try { re = new RegExp(pattern.replace(/\\\|/g, '|').replace(/\\([(){}+?])/g, '$1'), 'i'); }
  catch { re = new RegExp(pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'); }
  const lines = [];
  for (let n = 1, count = model.getLineCount(); n <= count && lines.length < 200; n++) {
    if (re.test(model.getLineContent(n))) lines.push(n);
  }
  return lines;
}

// ----- Lanes -----------------------------------------------------------------

function laneFor(item) {
  const key = item.sub || 'main';
  let lane = lanes.get(key);
  if (!lane) {
    lane = { key, label: item.sub || agentName(), color: LANE_COLORS[lanes.size % LANE_COLORS.length],
             hex: item.peer && !item.sub.includes(' · ') ? peerColor(item.peerKind) : null,
             queue: [], busy: false, lastActive: 0, pending: new Map(), editing: new Map(), view: null };
    lanes.set(key, lane);
  }
  return lane;
}

// Edits are animated from what actually changed on disk (app.agentChange), which catches
// every edit however it was made. The transcript's edit items only tell us which agent is
// editing which file, and are the fallback when no disk change arrives (a file outside the
// watched project).
const diskChanges = new Map(); // path -> time of its last disk change

function followAction(item) {
  const lane = laneFor(item);
  if (item.kind === 'tool') {
    if (item.action === 'edit' || item.action === 'write') {
      const path = agentAbs(item.path);
      if (path) lane.editing.set(canonical(path), Date.now());
      const since = Date.now();
      const fallback = () => {
        lane.pending.delete(item.id);
        if (!path || (diskChanges.get(canonical(path)) || 0) < since) enqueue(lane, { edit: item });
      };
      lane.pending.set(item.id, { item, since, fallback, timer: setTimeout(fallback, 4000) });
    } else {
      looksFor(item).then(looks => looks.forEach(look => enqueue(lane, { look, item })));
    }
  } else if (item.kind === 'result') {
    const entry = lane.pending.get(item.id);
    if (entry) {
      clearTimeout(entry.timer);
      lane.pending.delete(item.id);
      // Give the disk change a moment to arrive before falling back to the transcript.
      if (!item.error) setTimeout(entry.fallback, 1500);
    }
  }
}

/** The lane (agent or sub-agent) that most recently said it was editing `path`. */
function laneEditing(path) {
  const key = canonical(path);
  let best = null, bestTime = 0;
  for (const lane of lanes.values()) {
    const time = lane.editing.get(key) || 0;
    if (time > bestTime && Date.now() - time < 60000) { best = lane; bestTime = time; }
  }
  return best || laneFor({});
}

function agentChange(change) {
  const key = canonical(change.path);
  diskChanges.set(key, Date.now());
  if (change.live) {
    heatLines(change.path, (change.hunks || []).reduce((n, h) => n + (h.count || 0) + (h.removed?.length || 0), 0));
  }
  // New and deleted files show up in (or leave) the Explorer right away.
  if (change.created || change.deleted) refreshExplorer();
  if (change.live) window.starmap?.change(change);
  if (change.live && !panelVisible) {
    // The editor is closed: remember the change; it's revealed when the editor opens.
    rememberTurnChange(change);
    markFile(change.path, 'edit');
    if (!change.deleted) pendingReveal = change;
    const open = state.tabs.find(t => samePath(t.path, change.path));
    if (open) reloadFromDisk(open);
    return;
  }
  if (!change.live) {
    // No agent working: keep open tabs current, but don't animate.
    const open = state.tabs.find(t => samePath(t.path, change.path));
    if (open) reloadFromDisk(open);
    return;
  }
  rememberTurnChange(change);
  window.pov?.diskChange(change);
  if (!agent.follow) { markFile(change.path, 'edit'); return; }
  enqueue(laneEditing(change.path), { change });
}

function enqueue(lane, action) {
  lane.lastActive = Date.now();
  lane.queue.push(action);
  // When an agent gets ahead, skip to its latest looks (edits are always shown).
  while (lane.queue.length > 3) {
    const index = lane.queue.findIndex(a => a.look);
    if (index < 0) break;
    lane.queue.splice(index, 1);
  }
  updateSplit();
  runLane(lane);
}

async function runLane(lane) {
  if (lane.busy) return;
  lane.busy = true;
  try {
    while (lane.queue.length) {
      const action = lane.queue.shift();
      lane.lastActive = Date.now();
      const view = viewFor(lane);
      if (!view) continue;
      if (action.look) {
        await showLook(view, action.look);
        await sleep(lane.queue.length ? 380 : 650);
      } else if (action.edit) {
        await showEdit(view, action.edit);
        await sleep(lane.queue.length ? 500 : 900);
      } else if (action.change) {
        await showChange(view, action.change, { hurry: lane.queue.length > 2 });
        await sleep(lane.queue.length ? 300 : 700);
      }
    }
  } catch (e) {
    log(`follow: ${e?.stack || e}`);
  } finally {
    lane.busy = false;
  }
}

// ----- Views: the main editor, or one pane per lane in split view -------------------

function mainView() {
  if (!mainView.view) mainView.view = { id: 'main', main: true, editor: () => editor, deco: {} };
  return mainView.view;
}

function viewFor(lane) {
  if (split) return lane.view || null;
  return mainView();
}

const ACTIVE_WINDOW = 20000;
const activeLanes = () => [...lanes.values()].filter(l => Date.now() - l.lastActive < ACTIVE_WINDOW);

function updateSplit() {
  const active = activeLanes();
  if (active.length >= 2) {
    if (!split) enterSplit();
    for (const lane of active) if (!lane.view) addPane(lane);
    layoutSplit();
  }
}

function enterSplit() {
  const grid = el('div', 'agent-grid');
  const exit = el('div', 'agent-grid-exit');
  exit.innerHTML = '<i class="codicon codicon-close"></i> Exit split view';
  exit.onclick = () => exitSplit(true);
  grid.append(exit);
  $('editor-part').append(grid);
  clearMainDecorations();
  split = { grid, dismissedAt: 0 };
}

function exitSplit(manual) {
  if (!split) return;
  const { grid } = split;
  for (const lane of lanes.values()) {
    if (lane.view) { lane.view.monaco.dispose(); lane.view = null; }
  }
  monacoRef.editor.getModels().filter(m => m.uri.scheme === 'agentview').forEach(m => m.dispose());
  grid.classList.add('closing');
  setTimeout(() => grid.remove(), 180);
  split = null;
  if (manual) lanes.forEach(l => { l.lastActive = 0; });
}

function addPane(lane) {
  const pane = el('div', 'agent-pane');
  pane.style.setProperty('--c', lane.hex || `var(${lane.color})`);
  const head = el('div', 'agent-pane-head');
  const dot = el('span', 'agent-pane-dot');
  const title = el('span', 'agent-pane-title', lane.key === 'main' ? agentName() : lane.label);
  const action = el('span', 'agent-pane-action', 'starting…');
  const file = el('span', 'agent-pane-file');
  head.append(dot, title, action, file);
  const body = el('div', 'agent-pane-body');
  pane.append(head, body);
  split.grid.append(pane);
  const instance = monacoRef.editor.create(body, {
    readOnly: true, domReadOnly: true, model: null, automaticLayout: true,
    fontFamily: editor.getOption(monacoRef.editor.EditorOption.fontFamily), fontSize: 12, lineHeight: 18,
    minimap: { enabled: false }, scrollBeyondLastLine: false, renderLineHighlight: 'none', folding: false,
    lineNumbersMinChars: 3, glyphMargin: false, stickyScroll: { enabled: false }, smoothScrolling: true,
    scrollbar: { verticalScrollbarSize: 6, horizontalScrollbarSize: 6 }, contextmenu: false,
  });
  lane.view = { id: `pane${++viewSeq}`, main: false, monaco: instance, editor: () => instance, deco: {},
                pane, action, file, lane };
}

function layoutSplit() {
  if (!split) return;
  const panes = split.grid.querySelectorAll('.agent-pane').length;
  const columns = panes <= 2 ? panes : panes <= 4 ? 2 : 3;
  split.grid.style.gridTemplateColumns = `repeat(${columns}, 1fr)`;
  split.grid.style.gridTemplateRows = `repeat(${Math.ceil(panes / columns)}, 1fr)`;
  // No empty cell: the last pane spans whatever is left of its row.
  const all = [...split.grid.querySelectorAll('.agent-pane')];
  all.forEach(p => { p.style.gridColumn = ''; });
  const leftover = panes % columns;
  if (leftover) all[all.length - 1].style.gridColumn = `span ${columns - leftover + 1}`;
}

// Panes of agents that went quiet fade out; the split closes when one agent is left.
setInterval(() => {
  if (!split) return;
  const active = new Set(activeLanes());
  for (const lane of lanes.values()) {
    if (lane.view && !active.has(lane) && !lane.queue.length) {
      const { pane, monaco } = lane.view;
      pane.classList.add('closing');
      setTimeout(() => { monaco.dispose(); pane.remove(); layoutSplit(); }, 200);
      lane.view = null;
    }
  }
  if (active.size < 2) exitSplit(false);
}, 2000);

/** Model for a view: the tab's model in the main editor, a private copy in a pane. */
async function modelFor(view, path, { preview }) {
  if (view.main) {
    if (userIsEditing()) return null;
    const tab = await openFile(path, { focus: false, preview, quiet: true });
    if (!tab || !samePath(state.active, tab.path)) return null;
    await reloadFromDisk(tab);
    return tab.model;
  }
  const result = await fs('read', { path });
  if (result.error) return null;
  const uri = monacoRef.Uri.from({ scheme: 'agentview', path });
  let model = monacoRef.editor.getModel(uri);
  if (!model) model = monacoRef.editor.createModel(result.content, undefined, uri);
  else if (model.getValue() !== result.content) model.setValue(result.content);
  const instance = view.editor();
  if (instance.getModel() !== model) {
    instance.setModel(model);
    view.switched = true;  // jump, don't glide, when a pane changes files
  }
  view.file.textContent = relative(path);
  view.file.title = path;
  return model;
}

function clearView(view) {
  const instance = view.editor();
  const d = view.deco;
  (d.timers || []).forEach(clearTimeout);
  d.timers = [];
  d.look?.clear(); d.look = null;
  d.edit?.clear(); d.edit = null;
  if (d.widget) { instance.removeContentWidget(d.widget); d.widget = null; }
  if (d.zone) { const zone = d.zone; instance.changeViewZones(acc => acc.removeZone(zone)); d.zone = null; }
  if (d.zones?.length) { const zones = d.zones; instance.changeViewZones(acc => zones.forEach(z => acc.removeZone(z))); }
  d.zones = [];
}

function clearMainDecorations() { if (mainView.view) clearView(mainView.view); }

function addLabel(view, line, text, cls) {
  const node = document.createElement('div');
  node.className = `agent-label ${cls}`;
  node.textContent = text;
  view.deco.widget = {
    getId: () => `agent.label.${view.id}`,
    getDomNode: () => node,
    getPosition: () => ({ position: { lineNumber: line, column: 1 },
      preference: [monacoRef.editor.ContentWidgetPositionPreference.ABOVE, monacoRef.editor.ContentWidgetPositionPreference.BELOW] }),
  };
  view.editor().addContentWidget(view.deco.widget);
}

/**
 * Scrolls a view to lines first..last: centered if they fit, else from the top. A pane
 * that just switched files (or was just created) jumps; otherwise it glides.
 */
function revealLines(view, first, last) {
  const instance = view.editor();
  const reveal = () => {
    const { Smooth, Immediate } = monacoRef.editor.ScrollType;
    const type = view.switched ? Immediate : Smooth;
    view.switched = false;
    const height = instance.getLayoutInfo().height;
    const lineHeight = instance.getOption(monacoRef.editor.EditorOption.lineHeight);
    const fits = (last - first + 3) * lineHeight < height;
    if (fits) instance.revealRangeInCenter(new monacoRef.Range(first, 1, last, 1), type);
    else instance.revealLineNearTop(first, type);
  };
  // A pane created a moment ago may not have its size yet.
  if (!instance.getLayoutInfo().height) { instance.layout(); requestAnimationFrame(reveal); }
  else reveal();
}

// ----- Reading ---------------------------------------------------------------

async function showLook(view, look) {
  markFile(look.path, 'read');
  const model = await modelFor(view, look.path, { preview: true });
  if (!model) return;
  const instance = view.editor();
  const count = model.getLineCount();
  clearView(view);

  let lines, label;
  if (look.grep) {
    lines = grepLines(model, look.grep);
    label = `searching “${look.grep.length > 28 ? look.grep.slice(0, 27) + '…' : look.grep}” · ${lines.length} match${lines.length === 1 ? '' : 'es'}`;
  } else {
    const first = look.start < 0 ? Math.max(1, count + look.start + 1) : Math.min(look.start, count);
    const last = Math.min(look.end ?? count, count);
    lines = [];
    for (let n = first; n <= Math.min(last, first + 300); n++) lines.push(n);
    label = first === 1 && last === count ? 'reading the file' : `reading lines ${first}–${last}`;
  }
  if (!lines.length) lines = [1];
  view.deco.look = instance.createDecorationsCollection(lines.map((line, i) => ({
    range: new monacoRef.Range(line, 1, line, 1),
    options: { isWholeLine: true, className: `agent-look-line agent-w-${i % 48}`, linesDecorationsClassName: 'agent-look-gutter' },
  })));
  const name = view.main ? agentName() : view.lane.label;
  addLabel(view, lines[0], view.main ? `${name} · ${label}` : label, 'read');
  if (view.action) { view.action.textContent = label; view.pane.dataset.state = 'read'; }

  revealLines(view, lines[0], lines[lines.length - 1]);
  view.deco.timers.push(setTimeout(() => clearView(view), view.main ? 7000 : 12000));
}

// ----- Editing ---------------------------------------------------------------

async function showEdit(view, item) {
  const path = agentAbs(item.path);
  if (!path || path.includes('/.claude/projects/')) return;
  markFile(path, 'edit');
  if (view.main) {
    const open = state.tabs.find(t => samePath(t.path, path));
    if (userIsEditing()) { if (open) await reloadFromDisk(open); return; }
  }
  const model = await modelFor(view, path, { preview: false });
  if (!model) return;
  let added = item.new || '';
  let removed = item.old || '';
  if (item.patch) {
    const lines = item.patch.split('\n');
    added = lines.filter(l => l.startsWith('+') && !l.startsWith('+++')).map(l => l.slice(1)).join('\n');
    removed = lines.filter(l => l.startsWith('-') && !l.startsWith('---')).map(l => l.slice(1)).join('\n');
  }
  animateChange(view, model, added, removed, item.action === 'write');
}

function animateChange(view, model, added, removed, isNewFile) {
  const instance = view.editor();
  let range;
  if (isNewFile) {
    range = new monacoRef.Range(1, 1, Math.min(model.getLineCount(), 400), 1);
  } else {
    if (!added.trim()) return;
    const firstLine = added.split('\n').find(l => l.trim()) || added;
    const match = model.findMatches(added.length < 5000 ? added : firstLine, false, false, true, null, false)[0]
      || model.findMatches(firstLine, false, false, true, null, false)[0];
    if (!match) return;
    range = match.range;
  }
  clearView(view);

  const decorations = [];
  for (let line = range.startLineNumber, i = 0; line <= range.endLineNumber; line++, i++) {
    const delay = `agent-d-${Math.min(i, 119)}`;
    decorations.push({
      range: new monacoRef.Range(line, 1, line, model.getLineMaxColumn(line)),
      options: { isWholeLine: true, className: `agent-write-line ${delay}`, inlineClassName: `agent-write-text ${delay}`,
                 linesDecorationsClassName: 'agent-added-gutter' },
    });
  }
  const lastLine = range.endLineNumber;
  decorations.push({
    range: new monacoRef.Range(lastLine, model.getLineMaxColumn(lastLine), lastLine, model.getLineMaxColumn(lastLine)),
    options: { afterContentClassName: 'agent-caret' },
  });
  view.deco.edit = instance.createDecorationsCollection(decorations);

  const gone = removed && !isNewFile ? removed.split('\n').slice(0, 30) : [];
  instance.changeViewZones(acc => {
    if (gone.length) {
      const dom = el('div', 'agent-removed-zone');
      dom.textContent = gone.join('\n');
      dom.style.lineHeight = `${instance.getOption(monacoRef.editor.EditorOption.lineHeight)}px`;
      view.deco.zone = acc.addZone({ afterLineNumber: range.startLineNumber - 1, heightInLines: gone.length, domNode: dom });
    }
  });
  const label = isNewFile ? 'writing a new file' : `editing lines ${range.startLineNumber}–${range.endLineNumber}`;
  if (!view.main) addLabel(view, range.startLineNumber, label, 'edit');
  if (view.action) { view.action.textContent = label; view.pane.dataset.state = 'edit'; }
  revealLines(view, range.startLineNumber, range.endLineNumber);

  const lines = range.endLineNumber - range.startLineNumber + 1;
  view.deco.timers.push(setTimeout(() => {
    if (view.deco.zone) { const zone = view.deco.zone; instance.changeViewZones(acc => acc.removeZone(zone)); view.deco.zone = null; }
  }, 2600 + Math.min(lines, 120) * 38));
  view.deco.timers.push(setTimeout(() => clearView(view), 8000 + Math.min(lines, 120) * 38));
}

// ----- Disk changes: animate exactly the lines that changed ----------------------

/** Groups hunks that are close together so each step shows one area of the file. */
function hunkSteps(hunks) {
  const steps = [];
  for (const h of hunks) {
    const end = h.start + Math.max(h.count, 1) - 1;
    const last = steps[steps.length - 1];
    if (last && h.start - last.end <= 6) { last.hunks.push(h); last.end = Math.max(last.end, end); }
    else steps.push({ hunks: [h], start: h.start, end });
  }
  return steps;
}

async function showChange(view, change, { hurry = false } = {}) {
  const path = change.path;
  if (path.includes('/.claude/projects/')) return;
  markFile(path, 'edit');
  if (change.deleted) return;
  if (view.main && userIsEditing()) {
    const open = state.tabs.find(t => samePath(t.path, path));
    if (open) await reloadFromDisk(open);
    return;
  }
  const model = await modelFor(view, path, { preview: false });
  if (!model) return;
  applyTurnMarks(path, model);
  const steps = hunkSteps(change.hunks || []);
  if (!steps.length) return;
  const shown = hurry ? steps.slice(0, 1) : steps.slice(0, 8);
  for (let i = 0; i < shown.length; i++) {
    const lines = animateStep(view, model, shown[i], { index: i, total: steps.length, created: change.created });
    if (i < shown.length - 1) await sleep(Math.min(2400, 700 + lines * 30));
  }
}

/** Animates one area of a change: new lines type in, removed lines show struck through. */
function animateStep(view, model, step, { index, total, created }) {
  const instance = view.editor();
  const count = model.getLineCount();
  clearView(view);
  const decorations = [];
  let i = 0;
  for (const h of step.hunks) {
    for (let line = h.start; line < h.start + h.count && line <= count; line++, i++) {
      const delay = `agent-d-${Math.min(i, 119)}`;
      decorations.push({
        range: new monacoRef.Range(line, 1, line, model.getLineMaxColumn(line)),
        options: { isWholeLine: true, className: `agent-write-line ${delay}`, inlineClassName: `agent-write-text ${delay}`,
                   linesDecorationsClassName: 'agent-added-gutter' },
      });
    }
  }
  const last = step.hunks.filter(h => h.count > 0).pop();
  if (last) {
    const line = Math.min(last.start + last.count - 1, count);
    decorations.push({
      range: new monacoRef.Range(line, model.getLineMaxColumn(line), line, model.getLineMaxColumn(line)),
      options: { afterContentClassName: 'agent-caret' },
    });
  }
  view.deco.edit = instance.createDecorationsCollection(decorations);

  const lineHeight = instance.getOption(monacoRef.editor.EditorOption.lineHeight);
  instance.changeViewZones(acc => {
    for (const h of step.hunks) {
      const gone = (h.removed || []).slice(0, 30);
      if (!gone.length || created) continue;
      const dom = el('div', 'agent-removed-zone');
      dom.textContent = gone.join('\n') + (h.removed.length > 30 ? `\n… ${h.removed.length - 30} more removed lines` : '');
      dom.style.lineHeight = `${lineHeight}px`;
      view.deco.zones.push(acc.addZone({ afterLineNumber: Math.max(0, h.start - 1),
        heightInLines: Math.min(gone.length, 30) + (h.removed.length > 30 ? 1 : 0), domNode: dom }));
    }
  });

  const first = step.start, end = Math.max(step.start, step.end);
  const added = step.hunks.reduce((n, h) => n + h.count, 0);
  const removed = step.hunks.reduce((n, h) => n + (h.removed?.length || 0), 0);
  let label = created ? 'writing a new file'
    : added ? (first === end ? `editing line ${first}` : `editing lines ${first}–${end}`)
    : `removing ${removed} line${removed === 1 ? '' : 's'}`;
  if (total > 1) label += ` · change ${index + 1} of ${total}`;
  addLabel(view, first, view.main ? `${agentName()} · ${label}` : label, 'edit');
  if (view.action) { view.action.textContent = label; view.pane.dataset.state = 'edit'; }
  revealLines(view, first, end);

  view.deco.timers.push(setTimeout(() => {
    if (view.deco.zones?.length) {
      const zones = view.deco.zones;
      instance.changeViewZones(acc => zones.forEach(z => acc.removeZone(z)));
      view.deco.zones = [];
    }
  }, 2600 + Math.min(i, 120) * 38));
  view.deco.timers.push(setTimeout(() => clearView(view), 8000 + Math.min(i, 120) * 38));
  return Math.max(i, 1);
}

// ----- This turn's changes: gutter markers and the "changed this turn" strip ----------

const turn = { files: new Map(), decorations: new Map() }; // path -> change / decoration ids

function rememberTurnChange(change) {
  if (change.deleted) turn.files.delete(canonical(change.path));
  else {
    const previous = turn.files.get(canonical(change.path));
    turn.files.set(canonical(change.path), { ...change, created: change.created || previous?.created,
                                             time: Date.now() });
  }
  renderTurnStrip();
}

/** Marks the lines changed this turn in a file's gutter (stays while you browse). */
function applyTurnMarks(path, model) {
  const change = turn.files.get(canonical(path));
  const old = turn.decorations.get(canonical(path)) || [];
  if (!change || model.isDisposed()) return;
  const count = model.getLineCount();
  const decorations = (change.hunks || []).flatMap(h => {
    if (h.count > 0) {
      return [{ range: new monacoRef.Range(Math.min(h.start, count), 1, Math.min(h.start + h.count - 1, count), 1),
                options: { isWholeLine: true, linesDecorationsClassName: 'agent-turn-added',
                           overviewRuler: { color: '#73c991', position: monacoRef.editor.OverviewRulerLane.Left } } }];
    }
    const line = Math.max(1, Math.min(h.start, count));
    return [{ range: new monacoRef.Range(line, 1, line, 1),
              options: { linesDecorationsClassName: 'agent-turn-removed' } }];
  });
  turn.decorations.set(canonical(path), model.deltaDecorations(old, decorations));
}

function clearTurn() {
  for (const [path, ids] of turn.decorations) {
    const model = monacoRef?.editor.getModels().find(m => samePath(m.uri.path, path));
    if (model && !model.isDisposed()) model.deltaDecorations(ids, []);
  }
  turn.files.clear();
  turn.decorations.clear();
  renderTurnStrip();
}

function renderTurnStrip() {
  let strip = $('agent-turn');
  if (!strip) {
    strip = el('div');
    strip.id = 'agent-turn';
    $('agent-feed').before(strip);
  }
  const files = [...turn.files.values()].sort((a, b) => b.time - a.time);
  window.starmap?.turnChanged();
  strip.classList.toggle('show', files.length > 0);
  if (!files.length) { strip.replaceChildren(); return; }
  const added = files.reduce((n, f) => n + (f.hunks || []).reduce((m, h) => m + h.count, 0), 0);
  const removed = files.reduce((n, f) => n + (f.hunks || []).reduce((m, h) => m + (h.removed?.length || 0), 0), 0);
  const head = el('span', 'turn-head');
  head.append(el('i', 'codicon codicon-diff'), `${files.length} file${files.length === 1 ? '' : 's'} changed this turn`);
  const stats = el('span', 'turn-stats');
  stats.append(el('span', 'add', `+${added}`), el('span', 'del', `−${removed}`));
  const chips = files.slice(0, 12).map(f => {
    const chip = el('span', 'turn-file' + (f.created ? ' new' : ''), basename(f.path));
    chip.title = relative(f.path);
    chip.onclick = () => revisitChange(f);
    return chip;
  });
  strip.replaceChildren(head, stats, ...chips);
  if (files.length > 12) strip.append(el('span', 'turn-more', `+${files.length - 12} more`));
}

/** Opens a changed file and replays its changes. */
async function revisitChange(change) {
  const view = mainView();
  if (split) exitSplit(true);
  await showChange(view, change);
}

/** The editor opened mid-turn: show everything the agent changed so far, newest first. */
async function agentCatchUp(changes) {
  if (!changes.length) return;
  revealedAt = Date.now();
  pendingReveal = null;
  changes.forEach(c => turn.files.set(canonical(c.path), { ...c, time: c.mtime * 1000 }));
  renderTurnStrip();
  changes.forEach(c => markFile(c.path, 'edit'));
  changes.slice().reverse().forEach(c => window.starmap?.change(c));
  if (!agent.follow || userIsEditing()) return;
  const latest = changes.find(c => !c.deleted);
  if (!latest) return;
  const model = await modelFor(mainView(), latest.path, { preview: false });
  if (!model) return;
  applyTurnMarks(latest.path, model);
  const steps = hunkSteps(latest.hunks || []);
  if (!steps.length) return;
  // Land on the most recent area the agent worked on.
  const step = steps[steps.length - 1];
  animateStep(mainView(), model, step, { index: steps.length - 1, total: steps.length, created: latest.created });
  const view = mainView();
  if (view.deco.widget) { view.editor().removeContentWidget(view.deco.widget); view.deco.widget = null; }
  addLabel(view, step.start, `Caught up · ${agentName()} changed ${changes.length} file${changes.length === 1 ? '' : 's'} so far`, 'edit');
}

async function reloadFromDisk(tab) {
  if (isDirty(tab)) return;
  const result = await fs('read', { path: tab.path });
  if (result.error || result.content === tab.model.getValue()) return;
  tab.mtime = result.mtime;
  reloading = true;
  tab.model.pushEditOperations([], [{ range: tab.model.getFullModelRange(), text: result.content }], () => null);
  reloading = false;
  tab.savedVersion = tab.model.getAlternativeVersionId();
}

// ---------- Opening the panel -----------------------------------------------

// The app keeps this page following the agent while the panel is closed, but only records
// what happens then. Opening the panel reveals where the agent is.
let panelVisible = true;
let pendingReveal = null; // the latest change made while the panel was closed
let revealedAt = 0;       // when a catch-up last showed the agent's changes

async function panelShown() {
  // Let the app's catch-up (sent as the panel opens) land first.
  await sleep(900);
  if (!panelVisible || !agent.follow || userIsEditing()) return;
  if (Date.now() - revealedAt < 3000) return;
  if ([...lanes.values()].some(l => l.busy || l.queue.length)) return;
  if (pendingReveal) {
    const change = pendingReveal;
    pendingReveal = null;
    enqueue(laneEditing(change.path), { change: { ...change, live: true } });
    return;
  }
  if (state.active) return;
  // Nothing changed yet: go to what the agent is looking at or editing.
  for (const { item } of [...agent.tools.values()].reverse()) {
    if (item.action === 'edit' || item.action === 'write') {
      const path = agentAbs(item.path);
      if (path) { await openFile(path, { focus: false }); return; }
      continue;
    }
    const looks = await looksFor(item);
    if (looks.length) { enqueue(laneFor(item), { look: looks[looks.length - 1], item }); return; }
  }
}

$('panel-close').onclick = () => fs('close');

// Panel chrome: resize, collapse, follow toggle, clear.
(() => {
  const root = document.documentElement;
  const setHeight = (h) => root.style.setProperty('--agent-h', h);
  setHeight('38%');
  const sash = $('agent-sash');
  sash.addEventListener('mousedown', (e) => {
    const part = $('editor-part');
    const startY = e.clientY, startH = $('agent').offsetHeight;
    sash.classList.add('active');
    const move = (ev) => setHeight(`${Math.max(60, Math.min(part.offsetHeight - 120, startH - (ev.clientY - startY)))}px`);
    const up = () => { sash.classList.remove('active'); removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
    addEventListener('mousemove', move);
    addEventListener('mouseup', up);
  });
  $('agent-toggle').onclick = () => {
    const collapsed = $('agent').classList.toggle('collapsed');
    $('agent-toggle').className = `codicon codicon-chevron-${collapsed ? 'up' : 'down'}`;
    root.style.setProperty('--agent-h', collapsed ? '30px' : '38%');
    if (!collapsed) window.starmap?.visible();
  };
  const follow = $('agent-follow');
  follow.classList.add('on');
  follow.onclick = () => { agent.follow = !agent.follow; follow.classList.toggle('on', agent.follow); };
  $('agent-clear').onclick = () => { $('agent-feed').replaceChildren(); agent.tools.clear(); };
  const feed = $('agent-feed');
  feed.addEventListener('scroll', () => { agent.atBottom = feed.scrollHeight - feed.scrollTop - feed.clientHeight < 40; });
})();

// ---------- Native entry points ---------------------------------------------

window.app = {
  async openFolder(root, name, gitBranch) {
    if (state.root !== root) {
      state.root = root;
      state.children.clear();
      state.expanded.clear();
      state.files = null;
      $('root-name').textContent = (name || basename(root)).toUpperCase();
      await loadDir(root);
      window.starmap?.folder();
    }
    branch = gitBranch || '';
    renderTree();
    renderStatus();
  },
  /// The open folder's branch, when the app only learns it after opening the folder.
  setBranch(gitBranch) {
    branch = gitBranch || '';
    renderStatus();
  },
  openFile(path, line) { openFile(path, { line }); },
  setTheme(theme) { applyTheme(theme); },
  agentItems(items, reset) { agentItems(items, reset); },
  agentChange(change) { agentChange(change); },
  agentCatchUp(changes) { agentCatchUp(changes); },
  agentStatus(status) { agentStatus(status); },
  setCheckpoints(list) { setCheckpoints(list); },
  setVisible(visible) {
    const was = panelVisible;
    panelVisible = visible;
    if (visible && !was) panelShown();
    if (visible) window.starmap?.visible();
  },
  focus() { (editor?.getModel() ? editor : $('tree')).focus(); },
};

// ---------- Monaco ----------------------------------------------------------

require.config({ paths: { vs: 'vs' } });
require(['vs/editor/editor.main'], () => {
  monacoRef = window.monaco;
  monacoRef.editor.defineTheme('dark-modern', {
    base: 'vs-dark', inherit: true, rules: [],
    colors: {
      'editor.background': '#1f1f1f',
      'editorGutter.background': '#1f1f1f',
      'editorLineNumber.foreground': '#6e7681',
      'editorLineNumber.activeForeground': '#cccccc',
      'editor.lineHighlightBorder': '#282828',
      'editorWidget.background': '#202020',
      'editorWidget.border': '#313131',
      'minimap.background': '#1f1f1f',
      'scrollbarSlider.background': '#79797933',
    },
  });
  editor = monacoRef.editor.create($('editor'), {
    theme: 'dark-modern',
    model: null,
    automaticLayout: true,
    fontFamily: 'Menlo, "SF Mono", Monaco, monospace',
    fontSize: 13,
    lineHeight: 20,
    minimap: { enabled: true, renderCharacters: false, scale: 1 },
    smoothScrolling: true,
    cursorBlinking: 'smooth',
    cursorSmoothCaretAnimation: 'on',
    bracketPairColorization: { enabled: true },
    guides: { bracketPairs: 'active', indentation: true },
    stickyScroll: { enabled: true },
    renderLineHighlight: 'all',
    scrollBeyondLastLine: false,
    padding: { top: 20 },
    fixedOverflowWidgets: true,
  });
  if (terminalTheme) applyTheme(terminalTheme);
  editor.onDidChangeCursorPosition(renderStatus);
  editor.onDidChangeCursorSelection(renderStatus);
  const { KeyMod, KeyCode } = monacoRef;
  editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyS, () => save());
  editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyW, () => state.active && closeTab(state.active));
  editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyP, () => quickOpen());
  editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyB, () => toggleExplorer());

  setInterval(syncWithDisk, 2000);
  window.addEventListener('focus', () => { refreshExplorer(); syncWithDisk(); });
  fs('ready');
});
