import assert from "node:assert/strict";
import { test } from "node:test";
import {
  GLYPH_PX, LINE_CHARS, LINE_WIDTH, MAX_ITEM_BYTES, bytes, charWidth, clip, clipBytes, expectedFit, fitLine, head, inner, paginate, rule, rulerRows,
  safe, textWidth, unboxed, wrap,
} from "../fit.js";

test("characters the glasses lack are swapped or dropped", () => {
  assert.equal(safe("done… — ok ✓"), "done... - ok +");
  assert.equal(safe("“quoted” ‘x’"), "\"quoted\" 'x'");
  assert.equal(safe("rocket \u{1F680} gone"), "rocket  gone");
  assert.equal(safe("● ▶ ★ │ café ·"), "● ▶ ★ │ café ·");
  assert.equal(safe("a\r\nb\tc"), "a\nb  c");
  assert.equal(safe(null), "");
});

test("one line is clipped with an ellipsis, by characters and by bytes", () => {
  assert.equal(clip("short"), "short");
  assert.equal(clip("  several   spaces\nand lines "), "several spaces and lines");
  const long = clip("x".repeat(100), 20);
  assert.equal(long.length, 20);
  assert.ok(long.endsWith("..."));
  const accented = clip("é".repeat(60), 60, MAX_ITEM_BYTES);
  assert.ok(bytes(accented) <= MAX_ITEM_BYTES);
  assert.ok(accented.endsWith("..."));
  assert.equal(clipBytes("ééé", 5), "éé");
});

test("characters the font has are kept, and only those", () => {
  assert.equal(safe("◆ ◇ ▽ ▷ ↗ ╭─╮ ▒ ™"), "◆ ◇ ▽ ▷ ↗ ╭─╮ ▒ ™");
  // Close ones are swapped; the font has no "♦", no dashed lines, no "µ".
  assert.equal(safe("♦ ░ ╔═╗ ✻"), "◆ ▒ ┏═┓ *");
  assert.equal(safe("a┄b µ ⚙ ⏵"), "ab   ");
});

test("widths come from one number and the classes of narrow and wide characters", () => {
  assert.equal(charWidth("n"), GLYPH_PX);
  assert.equal(charWidth("a"), GLYPH_PX);
  assert.ok(charWidth("i") < GLYPH_PX / 2 + 1 && charWidth("l") < charWidth("i") + 1);
  assert.ok(charWidth("M") > GLYPH_PX * 1.3 && charWidth("W") === charWidth("M"));
  assert.ok(charWidth("●") > charWidth("M"), "shapes and line drawing are the widest");
  assert.equal(charWidth("─"), charWidth("●"));
  assert.equal(charWidth(" "), charWidth("."));
  assert.equal(textWidth("nn i"), 2 * GLYPH_PX + charWidth(" ") + charWidth("i"));
  assert.equal(textWidth(""), 0);
  // A container's room is less its border and padding on both sides, and a little more.
  assert.equal(inner(176, 4, 1), Math.floor(166 * 0.97) - 2);
  assert.ok(inner(576) < 576 - 8 && inner(576) > 576 - 8 - 24, "a little luck, and more of it for a longer line");
  assert.equal(LINE_WIDTH, inner(576));
  assert.equal(LINE_CHARS, Math.floor(LINE_WIDTH / GLYPH_PX));
  assert.ok(LINE_CHARS >= 48 && LINE_CHARS <= 56, "about fifty ordinary letters across");
});

test("the display check counts its own characters", () => {
  const [n, m, i] = rulerRows();
  assert.equal(n.slice(0, 20), "nnnnnnnnn1nnnnnnnnn2");
  assert.equal(m[49], "5");
  assert.equal(i[99], "0");
  // Each row is longer than the display, so it shows where the edge is.
  for (const row of [n, m, i]) assert.ok(textWidth(row) > LINE_WIDTH);
  assert.equal(expectedFit("n"), Math.floor(LINE_WIDTH / GLYPH_PX));
  assert.ok(expectedFit("i") > expectedFit("n") && expectedFit("n") > expectedFit("M"));
});

test("a line is cut to a width in pixels", () => {
  assert.equal(fitLine("short", 200), "short");
  const cut = fitLine("W".repeat(40), 200);
  assert.ok(cut.endsWith("..."));
  assert.ok(textWidth(cut) <= 200);
  // Narrow letters get more characters in than wide ones.
  assert.ok(fitLine("i".repeat(80), 200).length > fitLine("M".repeat(80), 200).length);
  assert.equal(fitLine("  two   words\n", 200), "two words");
  assert.ok(textWidth(rule(200)) <= 200 && textWidth(rule(200)) > 170);
});

test("a terminal's boxes lose their sides and their long rules", () => {
  const boxed = ["╭──────────────────────────────╮", "│ Bash command                 │", "│   rm -rf build               │", "╰──────────────────────────────╯", "+------+------+", "a -- b"].join("\n");
  const lines = unboxed(boxed, 200).split("\n");
  assert.deepEqual(lines, [rule(200), "Bash command", "  rm -rf build", rule(200), "a -- b"]);
  assert.equal(unboxed("● Bash(ls) ────────────── done", 200), "● Bash(ls) ── done");
  assert.equal(unboxed("plain | pipe", 200), "plain | pipe");
});

test("text wraps at spaces, and through a word that's too long", () => {
  const w = (count) => count * GLYPH_PX;
  assert.deepEqual(wrap("nnn nnn nnn", w(7) + 5), ["nnn nnn", "nnn"]);
  assert.deepEqual(wrap("nnnnnnnnnn", w(4)), ["nnnn", "nnnn", "nn"]);
  assert.deepEqual(wrap("one\n\ntwo", w(10)), ["one", "", "two"]);
  // Spaces at the start of a line stay, as a terminal has them.
  assert.deepEqual(wrap("  indented", w(12)), ["  indented"]);
  for (const line of wrap("word ".repeat(200))) assert.ok(textWidth(line) <= LINE_WIDTH);
  for (const line of wrap("MW@".repeat(200) + " " + "il.".repeat(300), 300)) assert.ok(textWidth(line) <= 300);
});

test("pages hold so many lines each, and there's always one", () => {
  const pages = paginate(Array.from({ length: 16 }, (_, i) => "line " + i).join("\n"), 7);
  assert.equal(pages.length, 3);
  assert.equal(pages[0].split("\n").length, 7);
  assert.equal(pages[2], "line 14\nline 15");
  assert.deepEqual(paginate("", 7), [""]);
  for (const page of paginate("long words here ".repeat(300), 7)) assert.ok(page.split("\n").length <= 7);
});

test("a head keeps the first lines and says there was more", () => {
  assert.equal(head("a b", 2), "a b");
  const cut = head("word ".repeat(100), 2);
  assert.equal(cut.split("\n").length, 2);
  assert.ok(cut.endsWith("..."));
  for (const line of cut.split("\n")) assert.ok(textWidth(line) <= LINE_WIDTH);
});
