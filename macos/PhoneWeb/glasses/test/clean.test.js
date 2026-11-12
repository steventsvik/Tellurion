import assert from "node:assert/strict";
import { test } from "node:test";
import { cleanScreen, isFurniture, readable, stripControl, tidyLine } from "../clean.js";
import { elided, textWidth, wrap } from "../fit.js";

// Claude Code, working: output, a spinner, the input box and its status bar.
const CLAUDE = `● I'll remove the old build output first.

● Bash(rm -rf build)
  ⎿  Read 120 lines (ctrl+o to expand)


✻ Baking… (12s · ↓ 1.2k tokens · esc to interrupt)

────────────────────────────────────────────────────────────
> 
────────────────────────────────────────────────────────────
  ⏵⏵ accept edits on (shift+tab to cycle)                 Context left until auto-compact: 12%
  ? for shortcuts`;

// Claude Code's older input box, drawn as a frame, with text being typed.
const CLAUDE_BOX = `● Done. All 14 tests pass.

╭──────────────────────────────────────────────╮
│ > and now the docs                            │
╰──────────────────────────────────────────────╯
  ? for shortcuts`;

// Codex, working: what it ran, a table, a progress bar, its status and input lines.
const CODEX = `• Ran npm test
  └ FAIL src/login.test.ts
    … +12 lines

 Test Files  1 failed | 6 passed (7)
      Tests  1 failed | 31 passed (32)
[██████████████░░░░░░] 70%

• Working (3m 12s • esc to interrupt)

› Write tests for @filename
  100% context left · ? for shortcuts`;

// A permission prompt: the frame goes, what it asks stays.
const PROMPT = `● Bash(rm -rf build)
╭──────────────────────────────────────────────╮
│ Bash command                                 │
│   rm -rf build                               │
│ Do you want to proceed?                      │
│ ❯ 1. Yes                                     │
│   2. No, and tell Claude what to do differently (esc) │
╰──────────────────────────────────────────────╯`;

test("Claude Code's screen keeps what was said and done, not its furniture", () => {
  assert.deepEqual(cleanScreen(CLAUDE), [
    "● I'll remove the old build output first.",
    "",
    "● Bash(rm -rf build)",
    "  ⎿ Read 120 lines",
  ]);
  // What's being typed in its box isn't the agent's output either.
  assert.deepEqual(cleanScreen(CLAUDE_BOX), ["● Done. All 14 tests pass."]);
});

test("Codex's screen: columns closed up, the bar shortened, status and input gone", () => {
  assert.deepEqual(cleanScreen(CODEX), [
    "• Ran npm test",
    "  └ FAIL src/login.test.ts",
    "    … +12 lines",
    "",
    " Test Files 1 failed | 6 passed (7)",
    "    Tests 1 failed | 31 passed (32)",
    "[███░░░] 70%",
  ]);
});

test("a permission prompt loses its frame and keeps its words", () => {
  assert.deepEqual(cleanScreen(PROMPT), [
    "● Bash(rm -rf build)",
    "Bash command",
    "  rm -rf build",
    "Do you want to proceed?",
    "❯ 1. Yes",
    "  2. No, and tell Claude what to do differently (esc)",
  ]);
});

test("a shell's own lines are left alone", () => {
  const shell = "~/code/shop main\n$ git status\nOn branch main\nnothing to commit, working tree clean\n$ ";
  assert.deepEqual(cleanScreen(shell), ["~/code/shop main", "$ git status", "On branch main", "nothing to commit, working tree clean", "$"]);
  // A quoted line in the middle of output isn't an input box.
  assert.deepEqual(cleanScreen("> quoted\nmore output"), ["> quoted", "more output"]);
  assert.deepEqual(cleanScreen(""), []);
  assert.deepEqual(cleanScreen("\n\n  \n"), []);
});

test("no escape sequence or control character gets through, whole or in pieces", () => {
  assert.equal(stripControl("a\u001b[31mred\u001b[0m b"), "ared b");
  assert.equal(stripControl("x\u001b]0;title\u0007y\u001b]8;;http://a\u001b\\z"), "xyz");
  // The escape itself already stripped upstream leaves these behind.
  assert.equal(stripControl("[32mthird[0m [38;5;208mx[m [?25h"), "third x ");
  assert.equal(stripControl("bell\u0007 nul\u0000 del\u007f csi\u009b zero​width"), "bell nul del csi zerowidth");
  assert.equal(stripControl("a\r\nb\rc"), "a\nb\nc");
  // Brackets that are just text stay.
  assert.equal(stripControl("list[0] and [x] and [12]"), "list[0] and [x] and [12]");
  for (const line of cleanScreen("\u001b[1m● Done\u001b[0m\n\u001b[2K\u001b[1G$ ls\u0007")) assert.doesNotMatch(line, /[\u0000-\u001f\u007f-\u009f]/);
});

test("empty lines never come two in a row", () => {
  assert.deepEqual(cleanScreen("a\n\n\n\nb\n \n\t\nc\n\n"), ["a", "", "b", "", "c"]);
  // Nor where furniture was taken out between them.
  assert.deepEqual(cleanScreen("a\n\n──────────\n\nb"), ["a", "", "b"]);
});

test("furniture is told from words", () => {
  for (const line of ["──────────", "╭────────╮", "═══", "  ? for shortcuts", "✻ Thinking… (3s · esc to interrupt)", "· Pondering…",
    "⠋ Loading", "ctrl+t to hide todos", "⏵⏵ bypass permissions on", "⏎ send   ⌃J newline   ⌃T transcript   ⌃C quit", "+------+------+", "1.2k tokens"]) {
    assert.equal(isFurniture(line), true, line);
  }
  for (const line of ["● Done.", "- a list item", "$ ls", "a -- b", "Tests: 14 passed", "> quoted", "--help", "1. Yes", "…", "* bullet point here"]) {
    assert.equal(isFurniture(line), false, line);
  }
});

test("a line is tidied for a font that can't line columns up", () => {
  assert.equal(tidyLine("name        status      age"), "name  status  age");
  assert.equal(tidyLine("a  b   c"), "a b c");
  assert.equal(tidyLine("            deeply indented"), "    deeply indented");
  assert.equal(tidyLine("  two   "), "  two");
  assert.equal(tidyLine("│ framed line        │"), "framed line");
  assert.equal(tidyLine("progress ████████████████ done"), "progress ███ done");
  assert.equal(tidyLine("==================== summary ===================="), "=== summary ===");
  assert.equal(tidyLine("  ⎿  … +12 lines (ctrl+o to expand)"), "  ⎿ … +12 lines");
});

test("a screen that's mostly furniture gives way to the agent's own last words", () => {
  const idle = "\n\n────────────────────\n> \n────────────────────\n  ? for shortcuts";
  assert.deepEqual(readable(idle, "All 14 tests pass.\n\nNothing else changed."), ["All 14 tests pass.", "", "Nothing else changed."]);
  // A little on screen follows what it said, once.
  assert.deepEqual(readable("● Bash(ls)\n> \n  ? for shortcuts", "Listing files."), ["Listing files.", "", "● Bash(ls)"]);
  assert.deepEqual(readable("Listing files.\n> \n  ? for shortcuts", "Listing files."), ["Listing files."]);
  // Enough on screen: the screen it is.
  assert.deepEqual(readable("one\ntwo\nthree", "an old answer"), ["one", "two", "three"]);
  assert.deepEqual(readable(idle, ""), []);
});

test("a long path loses its middle; other long words break after a separator", () => {
  const path = "/private/tmp/build-501/some/very/long/path/that/keeps/going/scratchpad/ui/fake.sh";
  const short = elided(path, 400);
  assert.match(short, /^\/private\/\.\.\.\/.*ui\/fake\.sh$/);
  assert.ok(textWidth(short) <= 400);
  assert.equal(elided("short/path/here/ok", 400), null);
  assert.equal(elided("no-slashes-in-this-long-word-at-all-really-none-at-all-anywhere", 100), null);
  assert.deepEqual(wrap("open " + path + " now", 400), ["open", short, "now"]);
  assert.match(elided("https://example.com/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/page.html", 300), /^https:\/\/\.\.\.\/|^https:\/\/example\.com\/\.\.\.\//);
  const pieces = wrap("token_with_many_parts-and-more.parts_that-never_end-at_all.really_long-one_here.ok", 300);
  assert.ok(pieces.length >= 2);
  for (const piece of pieces.slice(0, -1)) assert.match(piece, /[-_.]$/, piece);
  for (const piece of pieces) assert.ok(textWidth(piece) <= 300);
  // No separator in reach: wherever it has to.
  for (const piece of wrap("x".repeat(200), 300)) assert.ok(textWidth(piece) <= 300);
});
