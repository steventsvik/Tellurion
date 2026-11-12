import assert from "node:assert/strict";
import { test } from "node:test";
import { LINE_CHARS, MAX_ITEM_BYTES, bytes, clip, clipBytes, head, paginate, safe, wrap } from "../fit.js";

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

test("text wraps at spaces, and through a word that's too long", () => {
  assert.deepEqual(wrap("aaa bbb ccc", 7), ["aaa bbb", "ccc"]);
  assert.deepEqual(wrap("abcdefghij", 4), ["abcd", "efgh", "ij"]);
  assert.deepEqual(wrap("one\n\ntwo", 10), ["one", "", "two"]);
  for (const line of wrap("word ".repeat(200))) assert.ok(line.length <= LINE_CHARS);
});

test("pages hold so many lines each, and there's always one", () => {
  const pages = paginate(Array.from({ length: 16 }, (_, i) => "line " + i).join("\n"), 7);
  assert.equal(pages.length, 3);
  assert.equal(pages[0].split("\n").length, 7);
  assert.equal(pages[2], "line 14\nline 15");
  assert.deepEqual(paginate("", 7), [""]);
  for (const page of paginate("long words here ".repeat(300), 7)) assert.ok(page.length <= 420);
});

test("a head keeps the first lines and says there was more", () => {
  assert.equal(head("a b", 2), "a b");
  const cut = head("word ".repeat(100), 2);
  assert.equal(cut.split("\n").length, 2);
  assert.ok(cut.endsWith("..."));
});
