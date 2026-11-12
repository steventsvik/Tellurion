// Fitting text to the glasses: one built-in proportional font, no sizes, about 400 to 500
// characters on a full screen. Characters the font lacks are dropped by the glasses without
// a word, so they're replaced here first. Widths are estimates, kept on the safe side.

export const SCREEN = { width: 576, height: 288 };
/// Characters that fit on one full-width line, on the careful side of the average.
export const LINE_CHARS = 44;
/// What a text container takes when a page is made or rebuilt, in bytes, with room to spare.
export const MAX_TEXT_BYTES = 900;
/// A list item's limit, in bytes.
export const MAX_ITEM_BYTES = 63;

const REPLACE = {
  "\u2026": "...", "\u2013": "-", "\u2014": "-", "\u2212": "-", "\u2018": "'",
  "\u2019": "'", "\u201C": "\"", "\u201D": "\"", "\u2022": "\u25CF", "\u2713": "+",
  "\u2714": "+", "\u2717": "x", "\u2718": "x", "\u276F": ">", "\u203A": ">",
  "\u2039": "<", "\u00A0": " ", "\u0009": "  ", "\u23FA": "\u25CF", "\u23BF": "\u2514",
};

/// Whether the glasses' font can be trusted to have a character.
function inFont(code) {
  if (code === 0x0A) return true;
  if (code >= 0x20 && code <= 0x7E) return true;
  if (code >= 0xA1 && code <= 0xFF) return true;
  if (code >= 0x2190 && code <= 0x2193) return true; // arrows
  if (code >= 0x2500 && code <= 0x257F) return true; // box drawing
  if (code >= 0x2581 && code <= 0x2588) return true; // blocks
  // ● ○ ■ □ ▲ △ ▶ ▷ ▼ ▽ ◀ ◁ ★ ☆ ♠ ♣ ♥ ♦
  return [0x25CF, 0x25CB, 0x25A0, 0x25A1, 0x25B2, 0x25B3, 0x25B6, 0x25B7, 0x25BC, 0x25BD, 0x25C0, 0x25C1,
    0x2605, 0x2606, 0x2660, 0x2663, 0x2665, 0x2666].includes(code);
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

/// The lines `text` takes when wrapped at `width` characters: at spaces where it can,
/// through a word where it must.
export function wrap(text, width = LINE_CHARS) {
  const lines = [];
  for (const paragraph of safe(text).split("\n")) {
    let line = "";
    for (const word of paragraph.split(" ")) {
      let rest = word;
      while (Array.from(rest).length > width) {
        if (line) { lines.push(line); line = ""; }
        const chars = Array.from(rest);
        lines.push(chars.slice(0, width).join(""));
        rest = chars.slice(width).join("");
      }
      const joined = line ? line + " " + rest : rest;
      if (Array.from(joined).length > width) { lines.push(line); line = rest; } else { line = joined; }
    }
    lines.push(line);
  }
  return lines;
}

/// `text` as pages of at most `lines` wrapped lines each. Always at least one page.
export function paginate(text, lines, width = LINE_CHARS) {
  const all = wrap(text, width);
  while (all.length > 1 && all[all.length - 1] === "") all.pop();
  const pages = [];
  for (let start = 0; start < all.length; start += lines) {
    pages.push(clipBytes(all.slice(start, start + lines).join("\n"), MAX_TEXT_BYTES));
  }
  return pages.length ? pages : [""];
}

/// The first `lines` wrapped lines of `text`, ending in "..." when there was more.
export function head(text, lines, width = LINE_CHARS) {
  const all = wrap(text, width);
  if (all.length <= lines) return all.join("\n");
  const kept = all.slice(0, lines);
  const last = Array.from(kept[lines - 1]);
  kept[lines - 1] = last.slice(0, Math.max(0, width - 3)).join("").trimEnd() + "...";
  return kept.join("\n");
}
