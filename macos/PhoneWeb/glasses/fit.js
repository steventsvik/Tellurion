// Fitting text to the glasses: one built-in proportional font, no sizes. Characters the
// font lacks are dropped by the glasses without a word, so they're replaced here first.
//
// How wide text comes out is worked out from GLYPH_PX and the width classes below, read
// off the font the Even simulator draws with. To tune it on real glasses, open Tools >
// Display check there: each row of that page counts its own characters, so where a row
// wraps says how many really fit, and whether GLYPH_PX wants to go up or down.

export const SCREEN = { width: 576, height: 288 };
/// The width of an ordinary lowercase letter ("a", "n"), in pixels. The one number to tune.
export const GLYPH_PX = 11;
/// The height of a line of text, in pixels.
export const LINE_PX = 27;
/// What a text container takes when a page is made or rebuilt, in bytes, with room to spare.
export const MAX_TEXT_BYTES = 900;
/// A list item's limit, in bytes.
export const MAX_ITEM_BYTES = 63;

/// Widths that aren't an ordinary letter's, in elevenths of GLYPH_PX.
const CLASSES = {
  4: "|!':`l",
  5: " ,./;I\\ij·",
  6: "\"()t",
  7: "1[]fr°",
  8: "*J{}",
  9: "L_kz",
  10: "+-<=>^EFTceos±×",
  12: "03456789$?BDGHKNOPQRUZ«»",
  13: "AVXY",
  14: "#%↑↓",
  15: "&w",
  16: "MWm~",
  17: "@←→",
};
const WIDTHS = new Map();
for (const [width, chars] of Object.entries(CLASSES)) for (const char of chars) WIDTHS.set(char, Number(width));

/// One character's width in pixels.
export function charWidth(char) {
  const code = char.codePointAt(0);
  let units = WIDTHS.get(char);
  // Box drawing, blocks, shapes and stars are all the widest; capitals a little over a letter.
  if (units == null) units = code >= 0x2500 ? 20 : code >= 0x41 && code <= 0x5A ? 12 : 11;
  return units * GLYPH_PX / 11;
}

/// How wide `text` comes out on one line, in pixels.
export function textWidth(text) {
  let width = 0;
  for (const char of text) width += charWidth(char);
  return width;
}

/// The room for text in a container `width` wide: less its border and padding on both
/// sides, and a little more for luck. The font's widths aren't whole pixels, so a long
/// line comes out a few pixels wider than the sum here; the luck grows with the line.
export function inner(width, padding = 4, border = 0) {
  return Math.floor((width - 2 * (padding + border)) * 0.97) - 2;
}

/// The room for text across the whole display.
export const LINE_WIDTH = inner(SCREEN.width);
/// About how many characters that is.
export const LINE_CHARS = Math.floor(LINE_WIDTH / GLYPH_PX);

const REPLACE = {
  "…": "...", "–": "-", "—": "-", "−": "-", "‘": "'",
  "’": "'", "“": "\"", "”": "\"", "•": "●", "✓": "+",
  "✔": "+", "✗": "x", "✘": "x", "❯": ">", "›": ">",
  "‹": "<", " ": " ", "\u0009": "  ", "⏺": "●", "⎿": "└",
  "♦": "◆", "░": "▒", "▓": "▒", "▸": "▶", "▾": "▼",
  "║": "┃", "╔": "┏", "╗": "┓", "╚": "┗", "╝": "┛",
  "✻": "*", "✢": "*", "✶": "*", "✽": "*", "✳": "*",
};

// ■ □ ▣ … ◯, ★ ☆ and the few other symbols the font has.
const SHAPES = "■□▣▤▥▦▧▨▩▲△▶▷▼▽◀◁◆◇◈◊"
  + "○◌◎●◐◑◢◣◤◥◯★☆☉☎☏☜☞♠♡♣♤♥♧"
  + "™†※∞⇒⇔";
const MISSING = "¨¯´µ¸";

/// Whether the glasses' font can be trusted to have a character.
function inFont(code) {
  if (code === 0x0A) return true;
  if (code >= 0x20 && code <= 0x7E) return true;
  if (code >= 0xA1 && code <= 0xFF) return !MISSING.includes(String.fromCodePoint(code));
  if (code >= 0x2190 && code <= 0x2199) return true; // arrows
  if (code >= 0x2500 && code <= 0x254B) return !(code >= 0x2504 && code <= 0x250B); // box drawing, not the dashed ones
  if (code === 0x2550 || (code >= 0x256D && code <= 0x2573)) return true;
  if (code >= 0x2581 && code <= 0x258F) return true; // blocks
  if (code === 0x2592 || code === 0x2594 || code === 0x2595) return true;
  return SHAPES.includes(String.fromCodePoint(code));
}

/// Text with only characters the glasses can draw: look-alikes swapped in, the rest dropped.
export function safe(text) {
  let out = "";
  for (const char of String(text ?? "").replace(/\r\n?/g, "\n")) {
    const swapped = REPLACE[char] ?? char;
    for (const piece of swapped) if (inFont(piece.codePointAt(0))) out += piece;
  }
  return out;
}

export function bytes(text) {
  return new TextEncoder().encode(text).length;
}

/// The longest start of `text` within `limit` bytes, never splitting a character.
export function clipBytes(text, limit) {
  if (bytes(text) <= limit) return text;
  let out = "";
  let used = 0;
  for (const char of text) {
    const size = bytes(char);
    if (used + size > limit) break;
    out += char;
    used += size;
  }
  return out;
}

/// One line of at most `max` characters (and `maxBytes` bytes), ending in "..." when cut.
export function clip(text, max = LINE_CHARS, maxBytes = Infinity) {
  const line = safe(text).replace(/\s+/g, " ").trim();
  const chars = Array.from(line);
  if (chars.length <= max && bytes(line) <= maxBytes) return line;
  const room = Math.max(0, Math.min(max, chars.length) - 3);
  let cut = chars.slice(0, room).join("");
  if (maxBytes !== Infinity) cut = clipBytes(cut, Math.max(0, maxBytes - 3));
  return cut.trimEnd() + "...";
}

/// The longest start of `line` that's at most `width` pixels wide.
function startWithin(line, width) {
  let used = 0;
  let out = "";
  for (const char of line) {
    used += charWidth(char);
    if (used > width) break;
    out += char;
  }
  return out;
}

/// One line at most `width` pixels wide, ending in "..." when cut.
export function fitLine(text, width = LINE_WIDTH) {
  const line = safe(text).replace(/\s+/g, " ").trim();
  if (textWidth(line) <= width) return line;
  return startWithin(line, Math.max(0, width - textWidth("..."))).trimEnd() + "...";
}

/// Where a long token may be broken: after one of these.
const BREAKS = "/-_.,:=&?|\\";

/// The start of `token` to put on a line `width` wide: up to a "/", "-", "_" or "."
/// when there's one in its second half, and wherever it has to be otherwise.
function tokenPiece(token, width) {
  const fits = startWithin(token, width) || Array.from(token)[0];
  if (fits.length >= token.length) return fits;
  for (let at = fits.length - 1; at >= Math.floor(fits.length / 2); at -= 1) {
    if (BREAKS.includes(fits[at])) return fits.slice(0, at + 1);
  }
  return fits;
}

/// A path or address too long for a line, with its middle left out: its start, "...",
/// and as many of its last parts as fit ("/private/.../ui/fake.sh"). Null when it isn't
/// one, or when even its last part doesn't fit.
export function elided(token, width) {
  if (textWidth(token) <= width || (token.match(/\//g) ?? []).length < 3) return null;
  const parts = token.split("/");
  const start = parts.slice(0, parts[0] === "" || parts[0].endsWith(":") ? 2 : 1).join("/") + "/.../";
  let end = parts[parts.length - 1];
  if (textWidth(start + end) > width) return null;
  for (let at = parts.length - 2; at > 1; at -= 1) {
    const longer = parts[at] + "/" + end;
    if (textWidth(start + longer) > width) break;
    end = longer;
  }
  return start + end;
}

/// The lines `text` takes when wrapped at `width` pixels: at spaces where it can. A word
/// longer than a line is a path with its middle left out when that fits, and otherwise
/// broken after "/", "-", "_" or "." rather than anywhere. Spaces at the start of a line
/// stay, as a terminal has them.
export function wrap(text, width = LINE_WIDTH) {
  const lines = [];
  const space = charWidth(" ");
  for (const paragraph of safe(text).split("\n")) {
    let line = null;
    let used = 0;
    for (const word of paragraph.split(" ")) {
      let rest = word;
      let size = textWidth(rest);
      if (size > width) {
        const short = elided(rest, width);
        if (short) { rest = short; size = textWidth(rest); }
      }
      while (size > width) {
        // What's left of this line first, when it's worth having.
        const room = line == null ? width : width - used - space;
        if (line != null && room < width / 3) { lines.push(line); line = null; used = 0; continue; }
        const piece = tokenPiece(rest, room);
        lines.push(line == null ? piece : line + " " + piece);
        line = null;
        used = 0;
        rest = rest.slice(piece.length);
        size = textWidth(rest);
      }
      if (line == null) { line = rest; used = size; } else if (line.trim() && used + space + size > width) { lines.push(line); line = rest; used = size; } else { line += " " + rest; used += space + size; }
    }
    lines.push(line ?? "");
  }
  return lines;
}

/// `text` as pages of at most `lines` wrapped lines each. Always at least one page.
export function paginate(text, lines, width = LINE_WIDTH) {
  const all = wrap(text, width);
  while (all.length > 1 && all[all.length - 1] === "") all.pop();
  const pages = [];
  for (let start = 0; start < all.length; start += lines) {
    pages.push(clipBytes(all.slice(start, start + lines).join("\n"), MAX_TEXT_BYTES));
  }
  return pages.length ? pages : [""];
}

/// The first `lines` wrapped lines of `text`, ending in "..." when there was more.
export function head(text, lines, width = LINE_WIDTH) {
  const all = wrap(text, width);
  if (all.length <= lines) return all.join("\n");
  const kept = all.slice(0, lines);
  kept[lines - 1] = startWithin(kept[lines - 1], Math.max(0, width - textWidth("..."))).trimEnd() + "...";
  return kept.join("\n");
}

const FRAME = /^[\s\u2500-\u257F|+=_-]*$/;

/// A terminal's lines made to suit a narrow, proportional display: the boxes programs
/// draw around things lose their sides, and a row of nothing but line drawing becomes one
/// short rule (drawn as wide as the terminal it would wrap three times over).
export function unboxed(text, width = LINE_WIDTH) {
  const lines = [];
  for (const raw of safe(text).split("\n")) {
    if (raw.length > 3 && FRAME.test(raw) && /[\u2500-\u257F=_-]{4}/.test(raw)) {
      const ruled = rule(width);
      if (lines[lines.length - 1] !== ruled) lines.push(ruled);
      continue;
    }
    lines.push(raw.replace(/^(\s*)[\u2502\u2503]\s?/, "$1").replace(/\s*[\u2502\u2503]\s*$/, "").replace(/[\u2500\u2501\u2550]{4,}/g, "\u2500\u2500"));
  }
  return lines.join("\n");
}

/// A row of "─" about `width` pixels wide, never wider.
export function rule(width) {
  return "─".repeat(Math.max(1, Math.floor(width / charWidth("─"))));
}

/// A row of `count` copies of `char` that counts itself: every tenth is the tens digit.
function counted(char, count) {
  return Array.from({ length: count }, (_, i) => ((i + 1) % 10 === 0 ? String(((i + 1) / 10) % 10) : char)).join("");
}

/// The display check's rows, each longer than the display is wide: the last tens digit
/// before a row wraps says how many of that character fit. "n" is an ordinary letter,
/// GLYPH_PX wide; "M" is among the widest and "i" among the narrowest.
export function rulerRows() {
  return [counted("n", 70), counted("M", 50), counted("i", 140)];
}

/// How many of `char` the estimate says fit across the display, to compare with the check.
export function expectedFit(char) {
  return Math.floor(LINE_WIDTH / charWidth(char));
}
