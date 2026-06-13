//! beagle zig prelude — the ONLY handwritten Zig the emitted code sees.
//! Hard rules (brief §5.3): takes allocators as parameters, owns no
//! policy, frees nothing, never grows into a runtime.

const std = @import("std");

pub const Splitmix64 = struct {
    state: u64,

    pub fn init(seed: u64) Splitmix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *Splitmix64) u64 {
        self.state = self.state +% 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    pub fn below(self: *Splitmix64, n: u64) u64 {
        return self.next() % n;
    }
};

/// The context every emitted function takes first. v1 carries the tick
/// arena + deterministic rng; the world snapshot joins in Phase 2 when
/// the tick loop itself is emitted (deviation from the brief's sketch,
/// flagged in thread 20260612232001).
pub const Ctx = struct {
    tick: std.mem.Allocator,
    rng: *Splitmix64,
};

/// Splitmix64 finalizer as a pure mix — the counter-rng basis used by
/// the generated engine loop (per-(seed,tick,entity) determinism).
pub fn mix64(v: u64) u64 {
    var z = v +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// (kernel.rt/rng-below ctx n) — deterministic draw in [0, n).
pub fn rng_below(ctx: *Ctx, n: i64) i64 {
    return @intCast(ctx.rng.below(@intCast(n)));
}

/// alloc-or-panic: arena exhaustion is a config bug (brief §2.3).
fn talloc(ctx: *Ctx, comptime T: type, n: usize) []T {
    return ctx.tick.alloc(T, n) catch @panic("tick arena exhausted");
}

pub fn abs_i64(x: i64) i64 {
    return if (x < 0) -x else x;
}

/// Is T a byte-string the runtime treats as a string value? Either a
/// `[]const u8` slice or a string-literal pointer (`*const [N:0]u8`) —
/// both coerce to `[]const u8`. Lets `eq` compare a bound `[]const u8`
/// against a `"literal"` (whose type is `*const [N:0]u8`, not a slice).
fn isByteString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// clojure = : content equality. Strings compare by bytes (slice == would
/// compare fat-pointers, and a string literal isn't even a slice type);
/// everything else by value. Comptime-dispatched so emit stays
/// syntax-directed.
pub fn eq(a: anytype, b: anytype) bool {
    if (comptime (isByteString(@TypeOf(a)) and isByteString(@TypeOf(b)))) {
        const sa: []const u8 = a;
        const sb: []const u8 = b;
        return std.mem.eql(u8, sa, sb);
    } else {
        return a == b;
    }
}

// --- v1 vectors: arena slices ------------------------------------------------

pub fn count(c: anytype) i64 {
    // comptime dispatch: slices carry .len as a field; Map (and other
    // CLI containers) expose .len() — so (count x) is one emit for both.
    return switch (@typeInfo(@TypeOf(c))) {
        .pointer => @intCast(c.len),
        else => c.len(),
    };
}

pub fn nth(v: anytype, i: i64) std.meta.Elem(@TypeOf(v)) {
    return v[@intCast(i)];
}

pub fn first(v: anytype) ?std.meta.Elem(@TypeOf(v)) {
    return if (v.len > 0) v[0] else null;
}
pub fn rest(v: anytype) @TypeOf(v) {
    return if (v.len > 0) v[1..] else v[0..0];
}
pub fn is_empty(v: anytype) bool {
    return v.len == 0;
}

/// O(n) copy-append in the tick arena; evaporates at reset.
pub fn conj(ctx: *Ctx, v: anytype, x: std.meta.Elem(@TypeOf(v))) @TypeOf(v) {
    const T = std.meta.Elem(@TypeOf(v));
    const out = talloc(ctx, T, v.len + 1);
    @memcpy(out[0..v.len], v);
    out[v.len] = x;
    return out;
}

// === CLI runtime ============================================================
// The game kernel above allocates only through ctx.tick and frees nothing.
// A CLI is a different but equally allocation-disciplined shape: it runs
// once and exits, so everything goes through ONE process-lifetime arena,
// reclaimed by the OS at exit. This is for compiling TYPED beagle CLIs to
// native — concrete types only, no dynamic Value boxing.

var cli_arena_state: ?std.heap.ArenaAllocator = null;
pub fn cliAlloc() std.mem.Allocator {
    if (cli_arena_state == null) {
        cli_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return cli_arena_state.?.allocator();
}

// --- filesystem I/O context --------------------------------------------------
// zig 0.17 routes all blocking fs through a threaded `std.Io` instance, not
// the old free-standing `std.fs.cwd()` calls. A CLI does synchronous,
// single-threaded I/O, so one lazily-initialized Threaded executor + its
// `io()` handle backs every slurp/spit/access/stat/list here and in the
// application runtimes (los_rt imports this `io()` so there is one executor).
var io_state: ?std.Io.Threaded = null;
pub fn io() std.Io {
    if (io_state == null) {
        io_state = std.Io.Threaded.init(cliAlloc(), .{});
    }
    return io_state.?.io();
}

/// Typed map for the CLI target. Keyword and string keys both lower to
/// []const u8 keys; the value type V is concrete (records, ints, slices,
/// other maps) — never a dynamic union. `assoc` is immutable (clone+put)
/// to match Clojure semantics; CLI maps are small (per-record
/// frontmatter), so O(n) assoc is fine. `get` returns ?V — exactly
/// beagle's `V?` optional, so it flows straight into nil-narrowing.
pub fn Map(comptime V: type) type {
    return struct {
        const Self = @This();
        inner: std.StringHashMap(V),

        pub fn empty() Self {
            return .{ .inner = std.StringHashMap(V).init(cliAlloc()) };
        }
        pub fn assoc(self: Self, k: []const u8, v: V) Self {
            var m = self.inner.clone() catch @panic("oom");
            m.put(k, v) catch @panic("oom");
            return .{ .inner = m };
        }
        pub fn get(self: Self, k: []const u8) ?V {
            return self.inner.get(k);
        }
        pub fn contains(self: Self, k: []const u8) bool {
            return self.inner.contains(k);
        }
        pub fn len(self: Self) i64 {
            return @intCast(self.inner.count());
        }
    };
}

// --- strings (clojure.string + clojure.core) --------------------------------
const WS = " \t\r\n";
pub fn starts_with(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}
pub fn ends_with(s: []const u8, p: []const u8) bool {
    return std.mem.endsWith(u8, s, p);
}
pub fn includes(s: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, s, needle) != null;
}
pub fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, WS).len == 0;
}
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, WS);
}
pub fn trimr(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, WS);
}
pub fn subs(s: []const u8, start: i64) []const u8 {
    return s[@intCast(start)..];
}
pub fn subs3(s: []const u8, start: i64, end: i64) []const u8 {
    return s[@intCast(start)..@intCast(end)];
}
pub fn lower_case(s: []const u8) []const u8 {
    const out = cliAlloc().alloc(u8, s.len) catch @panic("oom");
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}
pub fn upper_case(s: []const u8) []const u8 {
    const out = cliAlloc().alloc(u8, s.len) catch @panic("oom");
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}
pub fn join(sep: []const u8, parts: []const []const u8) []const u8 {
    return std.mem.join(cliAlloc(), sep, parts) catch @panic("oom");
}
pub fn replace(s: []const u8, needle: []const u8, repl: []const u8) []const u8 {
    if (needle.len == 0) return s;
    const size = std.mem.replacementSize(u8, s, needle, repl);
    const out = cliAlloc().alloc(u8, size) catch @panic("oom");
    _ = std.mem.replace(u8, s, needle, repl, out);
    return out;
}
pub fn split_lines(s: []const u8) []const []const u8 {
    var n: usize = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    const out = cliAlloc().alloc([]const u8, n) catch @panic("oom");
    var it = std.mem.splitScalar(u8, s, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) out[i] = line;
    return out[0..i];
}
/// str (clojure.core) over two args; the common shape. Concatenates.
pub fn str2(a: []const u8, b: []const u8) []const u8 {
    return std.mem.concat(cliAlloc(), u8, &.{ a, b }) catch @panic("oom");
}
/// (str x) — stringify ONE value the way clojure.core/str does: strings
/// pass through, ints format as digits, bools as true/false. Comptime
/// dispatch keeps emit syntax-directed.
pub fn str1(x: anytype) []const u8 {
    const T = @TypeOf(x);
    if (T == []const u8) return x;
    return switch (@typeInfo(T)) {
        .int, .comptime_int => std.fmt.allocPrint(cliAlloc(), "{d}", .{x}) catch @panic("oom"),
        .bool => if (x) "true" else "false",
        .pointer => x, // string literal / slice
        else => std.fmt.allocPrint(cliAlloc(), "{any}", .{x}) catch @panic("oom"),
    };
}

// --- file I/O (clojure.core slurp/spit) -------------------------------------
pub fn slurp(p: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), p, cliAlloc(), .unlimited) catch
        @panic("slurp: read failed");
}
pub fn spit(p: []const u8, content: []const u8) void {
    const f = std.Io.Dir.cwd().createFile(io(), p, .{}) catch @panic("spit: create failed");
    defer f.close(io());
    f.writeStreamingAll(io(), content) catch @panic("spit: write failed");
}

// --- paths (babashka.fs) -----------------------------------------------------
/// (fs/parent p) — the parent directory, or null at a filesystem root.
/// Nullable to match clojure's babashka.fs/parent (→ nil for a root) and
/// the checker's String? typing, so source nil-guards lower honestly.
pub fn parent(p: []const u8) ?[]const u8 {
    return std.fs.path.dirname(p);
}
pub fn path(a: []const u8, b: []const u8) []const u8 {
    return std.fs.path.join(cliAlloc(), &.{ a, b }) catch @panic("oom");
}
pub fn exists(p: []const u8) bool {
    std.Io.Dir.cwd().access(io(), p, .{}) catch return false;
    return true;
}

// --- clojure.core numeric/ordering stdlib -----------------------------------
pub fn parse_long(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}
pub fn compare(a: []const u8, b: []const u8) i64 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// --- clojure.core seq ops (sorted/distinct/concat) --------------------------
// Allocate fresh slices in the CLI arena (immutable, like clojure). Element
// type is comptime-inferred from the input slice, so one emit serves Int,
// String, and other scalar slices. Ordering: strings lexicographic (matches
// clojure's compare on strings), numerics by value.
fn lessThan(comptime T: type, _: void, a: T, b: T) bool {
    if (T == []const u8) return std.mem.order(u8, a, b) == .lt;
    return a < b;
}
/// (sort xs) → new sorted slice (ascending). Stable copy in the CLI arena.
pub fn sort(xs: anytype) @TypeOf(xs) {
    const T = std.meta.Elem(@TypeOf(xs));
    const out = cliAlloc().alloc(T, xs.len) catch @panic("oom");
    @memcpy(out, xs);
    std.mem.sort(T, out, {}, struct {
        fn lt(_: void, a: T, b: T) bool {
            return lessThan(T, {}, a, b);
        }
    }.lt);
    return out;
}
/// (distinct xs) → new slice, first occurrence kept, order preserved.
pub fn distinct(xs: anytype) @TypeOf(xs) {
    const T = std.meta.Elem(@TypeOf(xs));
    const out = cliAlloc().alloc(T, xs.len) catch @panic("oom");
    var n: usize = 0;
    outer: for (xs) |x| {
        for (out[0..n]) |y| {
            if (eq(x, y)) continue :outer;
        }
        out[n] = x;
        n += 1;
    }
    return out[0..n];
}
/// (concat a b) → new slice a ++ b (two args; same element type).
pub fn concat(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const T = std.meta.Elem(@TypeOf(a));
    const out = cliAlloc().alloc(T, a.len + b.len) catch @panic("oom");
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}
