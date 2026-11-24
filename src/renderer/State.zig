//! This is the render state that is given to a renderer.

const State = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Io.Mutex,

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// Smooth scrolling state. Protected by `mutex`.
scroll: Scroll = .{},

/// The number of threads currently waiting to acquire `mutex` via
/// `lockDemand`. This is not protected by the mutex; it is read by
/// hot lock/unlock loops (the IO parse thread) in `yieldToDemand` to
/// decide whether to hand the mutex off before relocking it.
demand: std.atomic.Value(u32) = .init(0),

/// Handoff generation counter. Incremented (with a futex wake) by
/// `unlockDemand` after a demanding waiter releases the mutex, so that
/// `yieldToDemand` knows the waiter had its turn.
handoff_gen: std.atomic.Value(u32) = .init(0),

/// How long `yieldToDemand` sleeps waiting for a demanding waiter to
/// take its turn before giving up. This bounds how long the IO parse
/// thread can stall if a wake is lost or the waiter is descheduled; a
/// demanding critical section (the renderer's frame snapshot) is
/// microseconds, so one millisecond is generous.
const handoff_timeout_ns = 1 * std.time.ns_per_ms;

/// Acquire `mutex` while signaling demand for it. Use this instead of
/// locking the mutex directly on threads that must not be starved by
/// a hot lock/unlock loop (the renderer's frame snapshot). Must be
/// released with `unlockDemand`; releasing with `mutex.unlock` keeps
/// the data safe but makes parked `yieldToDemand` callers wait out
/// their full timeout.
///
/// Both `std.Thread.Mutex` and os_unfair_lock are unfair: a running
/// thread that unlocks and immediately relocks beats a sleeping
/// waiter every time, because the waiter must first be woken and
/// scheduled. Under sustained pty output the IO parse thread is
/// exactly such a loop, so without this signal the renderer can
/// starve for as long as the output lasts.
pub fn lockDemand(self: *State, io: std.Io) void {
    _ = self.demand.fetchAdd(1, .monotonic);
    self.mutex.lockUncancelable(io);
    const prev = self.demand.fetchSub(1, .monotonic);
    assert(prev > 0);
}

/// Release `mutex` acquired via `lockDemand` and notify hot loops
/// parked in `yieldToDemand` that the demanding waiter had its turn.
pub fn unlockDemand(self: *State, io: std.Io) void {
    self.mutex.unlock(io);
    _ = self.handoff_gen.fetchAdd(1, .monotonic);
    io.futexWake(u32, &self.handoff_gen.raw, 1);
}

/// Called by hot lock/unlock loops between critical sections, with
/// `mutex` NOT held: if a `lockDemand` waiter exists, sleep until it
/// has acquired and released the mutex (or the timeout passes). This
/// is the handoff that unfair mutexes never do on their own.
///
/// The orderings here are all monotonic because these atomics are a
/// scheduling heuristic, not a synchronization boundary: the mutex
/// itself orders the protected data, and the timeout bounds any
/// staleness.
pub fn yieldToDemand(self: *State, io: std.Io) void {
    if (self.demand.load(.monotonic) == 0) return;

    // Snapshot the generation before rechecking demand: if the waiter
    // acquires and releases between our check and the wait below, the
    // generation no longer matches and timedWait returns immediately.
    const gen = self.handoff_gen.load(.monotonic);
    if (self.demand.load(.monotonic) == 0) return;
    io.futexWaitTimeout(
        u32,
        &self.handoff_gen.raw,
        gen,
        .{ .duration = .{ .raw = .fromNanoseconds(handoff_timeout_ns), .clock = .awake } },
    ) catch {};
}

/// Whether the renderer can draw the grid at a pixel offset. Without it,
/// scrolling moves a whole row at a time.
pub const smooth_scroll = @hasField(
    renderer.Renderer.API.shaders.Uniforms,
    "scroll_offset_y",
);

/// The position of the viewport between two rows, for pixel-smooth
/// scrolling. The terminal's viewport is always on a row; this is how far
/// the content is drawn past it.
pub const Scroll = struct {
    /// How many pixels the content is shifted up from where the viewport
    /// puts it, in [0, cell height). Only meaningful while there's a row
    /// below the viewport to scroll into view, so it's always zero when
    /// the viewport follows the active area.
    offset: f64 = 0,

    /// Pixels still to scroll (positive is up, into history), played out
    /// over the next frames by the renderer. This is how a mouse wheel,
    /// which reports whole steps, scrolls smoothly.
    pending: f64 = 0,

    /// Forget any partial scroll, so the viewport is drawn on its row.
    pub fn reset(self: *Scroll) void {
        self.* = .{};
    }

    /// Scroll the viewport of the active screen by a number of pixels.
    /// Positive is up, into history. The mutex must be held.
    pub fn apply(
        self: *Scroll,
        t: *terminalpkg.Terminal,
        cell_height: f64,
        px_up: f64,
    ) void {
        if (cell_height < 1 or !std.math.isFinite(px_up)) {
            self.offset = 0;
            return;
        }

        const pages = &t.screens.active.pages;
        const top = pages.getTopLeft(.viewport);

        // A leftover offset means nothing with no row below the viewport.
        // Nor does one that isn't less than a row, after a font change.
        var offset = if (top.down(pages.rows) != null and
            self.offset >= 0 and self.offset < cell_height) self.offset else 0;

        // The scroll position relative to the viewport's row, in pixels
        // going up. The viewport moves to the next row at or above it,
        // and the offset is what's left.
        const pos = px_up - offset;
        const rows_f = std.math.clamp(@ceil(pos / cell_height), -1e6, 1e6);
        offset = rows_f * cell_height - pos;
        const rows: isize = @intFromFloat(rows_f);

        if (rows != 0) {
            // Stopped by the top of the scrollback.
            if (rows > 0 and top.upOverflow(@intCast(rows)) == .overflow) {
                offset = 0;
                self.pending = 0;
            }

            t.scrollViewport(.{ .delta = -rows });
        }

        // Reached (or was stopped by) the bottom.
        if (pages.getTopLeft(.viewport).down(pages.rows) == null) {
            offset = 0;
            if (px_up < 0) self.pending = 0;
        }

        self.offset = if (offset >= 0 and offset < cell_height) offset else 0;
    }

    /// Play out some of `pending` for a frame `dt_ms` after the last one.
    /// Returns true while there is more to play.
    pub fn animate(
        self: *Scroll,
        t: *terminalpkg.Terminal,
        cell_height: f64,
        dt_ms: f64,
    ) bool {
        if (self.pending == 0) return false;

        // Ease out: cover a fixed share of what's left per unit of time,
        // and at least a pixel so it always arrives.
        const share = 1 - @exp(-std.math.clamp(dt_ms, 1, 100) / time_constant_ms);
        const remaining = @abs(self.pending);
        const step = std.math.copysign(
            @min(remaining, @max(@round(remaining * share), 1)),
            self.pending,
        );
        self.pending -= step;
        if (@abs(self.pending) < 0.5) self.pending = 0;

        // `apply` clears `pending` when it hits either end.
        self.apply(t, cell_height, step);
        return self.pending != 0;
    }

    /// Most of a wheel step is covered in about three of these.
    const time_constant_ms = 45;
};

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}

fn testScrollTerminal(alloc: Allocator) !terminalpkg.Terminal {
    var t: terminalpkg.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 10,
        .rows = 5,
        .max_scrollback_bytes = 1_000_000,
    });
    errdefer t.deinit(alloc);

    // 25 lines: 20 rows of history above the 5 active rows.
    for (0..24) |_| try t.printString("line\n");
    try t.printString("line");
    return t;
}

fn testScrollRow(t: *terminalpkg.Terminal) usize {
    return t.screens.active.pages.scrollbar().offset;
}

test "smooth scroll follows pixels and keeps the remainder" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try testScrollTerminal(alloc);
    defer t.deinit(alloc);

    var scroll: Scroll = .{};
    try testing.expectEqual(@as(usize, 20), testScrollRow(&t));

    // A few pixels up: the viewport moves up a row and the content is
    // drawn most of a row above that, which is those few pixels down.
    scroll.apply(&t, 20, 3);
    try testing.expectEqual(@as(usize, 19), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 17), scroll.offset);

    // Many small steps add up exactly, with nothing dropped.
    for (0..37) |_| scroll.apply(&t, 20, 1);
    try testing.expectEqual(@as(usize, 18), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.offset);

    // And back down by the same amount, a fraction at a time.
    for (0..80) |_| scroll.apply(&t, 20, -0.5);
    try testing.expectEqual(@as(usize, 20), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.offset);
}

test "smooth scroll stops at both ends" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try testScrollTerminal(alloc);
    defer t.deinit(alloc);

    var scroll: Scroll = .{};

    // Scrolling down at the bottom does nothing and leaves nothing over.
    scroll.apply(&t, 20, -7);
    try testing.expectEqual(@as(usize, 20), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.offset);

    // Past the top: on the first row exactly.
    scroll.apply(&t, 20, 20 * 20 + 55);
    try testing.expectEqual(@as(usize, 0), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.offset);

    // Down from the top by less than a row keeps the viewport there.
    scroll.apply(&t, 20, -6);
    try testing.expectEqual(@as(usize, 0), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 6), scroll.offset);

    // Past the bottom from anywhere: on the active area exactly.
    scroll.apply(&t, 20, -10_000);
    try testing.expectEqual(@as(usize, 20), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.offset);

    // A leftover offset is ignored once the viewport is at the bottom.
    scroll.offset = 9;
    scroll.apply(&t, 20, 4);
    try testing.expectEqual(@as(usize, 19), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 16), scroll.offset);
}

test "smooth scroll plays out a wheel step" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try testScrollTerminal(alloc);
    defer t.deinit(alloc);

    // Three rows up, as a wheel step asks for.
    var scroll: Scroll = .{ .pending = 60 };
    var frames: usize = 0;
    var last_position: f64 = 0;
    while (scroll.animate(&t, 20, 8)) {
        frames += 1;
        try testing.expect(frames < 200);

        // Always moving up, never jumping a whole row in a frame.
        const position = @as(f64, @floatFromInt(20 - testScrollRow(&t))) * 20 - scroll.offset;
        try testing.expect(position > last_position);
        try testing.expect(position - last_position < 20);
        last_position = position;
    }
    try testing.expect(frames > 5);
    try testing.expectEqual(@as(usize, 17), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.offset);

    // A step past the top ends there instead of running on.
    scroll.pending = 100_000;
    frames = 0;
    while (scroll.animate(&t, 20, 8)) {
        frames += 1;
        try testing.expect(frames < 200);
    }
    try testing.expectEqual(@as(usize, 0), testScrollRow(&t));
    try testing.expectEqual(@as(f64, 0), scroll.pending);
}
