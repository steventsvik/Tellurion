// A terminal's screen made readable on the glasses. Their font is proportional and the
// display narrow, so what a terminal lines up in columns can't line up there, and an
// agent's screen is half furniture: the input box, the status bar, the spinner. This
// keeps what was said and done, and leaves the furniture out. Nothing here knows about
// the glasses' sizes; fit.js wraps what comes out.

/// Escape sequences, whole or with their first byte already gone, and control characters.
export function stripControl(text) {
  return String(text ?? "")
    .replace(/\r\n?/g, "\n")
    // Titles and links: ESC ] ... BEL, or ESC ] ... ESC \.
    .replace(/\u001B\][^\u0007\u001B\n]*(?:\u0007|\u001B\\)?/g, "")
    // Colours and cursor moves: ESC [ ... letter.
    .replace(/\u001B\[[0-9;?<=>!]*[ -/]*[@-~]/g, "")
    .replace(/\u001B[@-Z\\^_=>78()][A-Za-z0-9]?/g, "")
    // The same with the escape itself stripped upstream: "[0m", "[38;5;208m", "]0;title".
    .replace(/\[(?:\d{1,3}(?:;\d{1,3}){0,5})?m/g, "")
    .replace(/\[\?\d{1,4}[hl]/g, "")
    .replace(/^\]\d{1,3};[^\n]*$/gm, "")
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u200B-\u200F\u2028\u2029\uFEFF]/g, "");
}

const DRAWING = /^[\s\u2500-\u257F\u2580-\u259F|+=_~*#.\u00B7-]*$/;
const SPINNER = "\u273B\u273D\u2736\u2733\u2722\u2734\u2735\u00B7*\u2022\u25E6";

/// The furniture of Claude Code's and Codex's screens: status bars, key hints, spinners.
const CHROME = [
  /\?\s+for shortcuts/i,
  /esc to (interrupt|cancel)\s*\)?\s*$/i,
  /\((?:shift\+tab|tab) to cycle\)/i,
  /context left/i,
  /^\s*[\u23F5\u25B6\u00BB>]{1,2}\s*(accept edits|auto-accept|bypass permissions|plan mode)/i,
  /\u23CE\s*send|\u2303J\s+newline|\u2303T\s+transcript|\u2303C\s+quit/,
  /^\s*(ctrl|shift|alt|cmd)\+\S+ to [a-z ]+$/i,
  /^\s*(press )?(enter|tab|return) to [a-z ,]+$/i,
  /^\s*\d+(\.\d+)?[km]? tokens?( used)?\s*$/i,
  /^\s*(\/help for help|\/status for)/i,
];

/// Whether a line is nothing to read: line drawing, a rule, a spinner frame, a status bar.
export function isFurniture(line) {
  const trimmed = line.trim();
  if (!trimmed) return false;
  if (DRAWING.test(trimmed) && !/[A-Za-z0-9]/.test(trimmed) && (trimmed.length > 2 || /[\u2500-\u259F]/.test(trimmed))) return true;
  // A spinner and its word: "* Baking... (12s)", or a lone braille frame.
  if (SPINNER.includes(trimmed[0]) && /^.\s*\S+(\u2026|\.\.\.)(\s*\(.*\))?\s*$/.test(trimmed)) return true;
  if (/^[\u2800-\u28FF]+(\s|$)/.test(trimmed)) return true;
  return CHROME.some((pattern) => pattern.test(line));
}

/// An input box's own line: a prompt mark with nothing, or with what's being typed.
function isPromptLine(line) {
  return /^\s*[>\u203A\u276F\u258C\u2590](\s|$)/.test(line.replace(/^\s*[\u2502\u2503\u2551]\s?/, ""));
}

/// One line as it reads best: no box sides, no "(ctrl+o to expand)", columns closed up,
/// bars shortened, not too far indented.
export function tidyLine(raw) {
  let line = raw
    .replace(/^(\s*)[\u2502\u2503\u2551]\s?/, "$1")
    .replace(/\s*[\u2502\u2503\u2551]\s*$/, "")
    .replace(/\s*\((?:ctrl|shift|alt)\+\S+ to [a-z ]+\)/gi, "")
    // A bar or a rule inside a line: three of it say as much.
    .replace(/([\u2500-\u257F\u2580-\u259F=#~*_-])\1{5,}/g, "$1$1$1")
    .replace(/\s+$/, "");
  const indent = /^ */.exec(line)[0].length;
  // Columns can't line up in this font: a gap becomes one space, a wide one two.
  line = line.slice(indent).replace(/ {2,}/g, (gap) => (gap.length >= 4 ? "  " : " "));
  return " ".repeat(Math.min(indent, 4)) + line;
}

/// A screen's text as lines worth reading, oldest first. Empty lines never come two in
/// a row, nor first or last.
export function cleanScreen(text) {
  const raw = stripControl(text).split("\n");
  const kept = [];
  let footer = false;
  const nothingBelow = () => kept.every((entry) => !entry.trim());
  // From the bottom up, so what's under the input box tells the box apart from a quote.
  for (let at = raw.length - 1; at >= 0; at -= 1) {
    const line = raw[at];
    if (isFurniture(line)) { if (nothingBelow()) footer = true; continue; }
    // The box's own line, between the status bar and the output: what's being typed.
    if (isPromptLine(line) && nothingBelow() && (footer || !line.replace(/[\u2502\u2503\u2551]/g, "").replace(/^\s*\S/, "").trim())) { footer = false; continue; }
    if (line.trim()) footer = false;
    kept.push(tidyLine(line));
  }
  kept.reverse();
  const lines = [];
  for (const line of kept) {
    if (!line.trim() && (!lines.length || !lines[lines.length - 1].trim())) continue;
    lines.push(line.trim() ? line : "");
  }
  while (lines.length && !lines[lines.length - 1]) lines.pop();
  return lines;
}

/// What to show for a pane: its cleaned screen, or, when that's mostly furniture, the
/// agent's own last words first and then what little the screen had.
export function readable(screenText, lastAnswer = "", few = 3) {
  const lines = cleanScreen(screenText);
  const said = cleanScreen(lastAnswer);
  if (!said.length || lines.filter((line) => line.trim()).length >= few) return lines;
  // Not twice, when the screen already shows the end of it.
  const fresh = lines.filter((line) => line.trim() && !said.includes(line));
  return fresh.length ? [...said, "", ...fresh] : said;
}
