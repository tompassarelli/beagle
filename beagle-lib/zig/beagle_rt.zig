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

/// Versioned logical keyword ABI. Namespace and name remain distinct UTF-8
/// byte slices, so `:name`, `:ns/name`, and the strings `"name"` /
/// `"ns/name"` never collapse onto one native key.
pub const Keyword = struct {
    pub const abi_version: u16 = 1;

    namespace: []const u8,
    name: []const u8,

    pub fn eql(self: Keyword, other: Keyword) bool {
        return std.mem.eql(u8, self.namespace, other.namespace) and
            std.mem.eql(u8, self.name, other.name);
    }

    pub fn hashValue(self: Keyword) i32 {
        return mixHash(9, mixHash(hash32(self.namespace), hash32(self.name)));
    }
};

pub fn keyword(namespace: []const u8, name: []const u8) Keyword {
    return .{ .namespace = namespace, .name = name };
}

fn eqSame(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;
                for (a, b) |left, right| {
                    if (!eq(left, right)) break :blk false;
                }
                break :blk true;
            },
            else => a == b,
        },
        .array => blk: {
            for (a, b) |left, right| {
                if (!eq(left, right)) break :blk false;
            }
            break :blk true;
        },
        .optional => if (a == null or b == null)
            a == null and b == null
        else
            eq(a.?, b.?),
        .@"struct" => if (@hasDecl(T, "eql")) a.eql(b) else std.meta.eql(a, b),
        else => a == b,
    };
}

/// clojure = : content equality. Strings compare by bytes (slice == would
/// compare fat-pointers, and a string literal isn't even a slice type);
/// vectors, maps, sets, and keywords compare recursively by logical value.
/// Comptime-dispatched so emit stays syntax-directed.
pub fn eq(a: anytype, b: anytype) bool {
    if (comptime (isByteString(@TypeOf(a)) and isByteString(@TypeOf(b)))) {
        const sa: []const u8 = a;
        const sb: []const u8 = b;
        return std.mem.eql(u8, sa, sb);
    } else if (comptime @TypeOf(a) == @TypeOf(b)) {
        return eqSame(@TypeOf(a), a, b);
    } else {
        return false;
    }
}

fn mixHash(h: i32, c: i32) i32 {
    return h *% 31 +% c;
}

fn hash32(value: anytype) i32 {
    const T = @TypeOf(value);
    if (comptime isByteString(T)) {
        const bytes: []const u8 = value;
        var out: i32 = 2;
        for (bytes) |byte| out = mixHash(out, @as(i32, byte));
        return out;
    }
    return switch (@typeInfo(T)) {
        .int, .comptime_int => blk: {
            const narrowed: i32 = @truncate(value);
            break :blk mixHash(1, narrowed) ^ (narrowed *% -1640531535);
        },
        .float, .comptime_float => blk: {
            const narrowed: i32 = @intFromFloat(value);
            break :blk mixHash(1, narrowed) ^ (narrowed *% -1640531535);
        },
        .bool => if (value) 3 else 4,
        .pointer => |p| switch (p.size) {
            .slice => blk: {
                var out: i32 = 5;
                for (value) |item| out = mixHash(out, hash32(item));
                break :blk out;
            },
            else => mixHash(8, 0),
        },
        .array => blk: {
            var out: i32 = 5;
            for (value) |item| out = mixHash(out, hash32(item));
            break :blk out;
        },
        .optional => if (value) |present| hash32(present) else 0,
        .@"struct" => if (@hasDecl(T, "hashValue"))
            value.hashValue()
        else
            mixHash(8, 0),
        else => mixHash(8, 0),
    };
}

/// Stable signed 32-bit logical hash widened to Beagle Int. Equal values always
/// return the same result; maps and sets combine entries order-independently.
pub fn hash(value: anytype) i64 {
    return @as(i64, hash32(value));
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
    return switch (@typeInfo(@TypeOf(v))) {
        .pointer => v.len == 0,
        else => v.len() == 0,
    };
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
        pub fn keySet(self: Self) ValueSet([]const u8) {
            var out = ValueSet([]const u8).empty();
            var inner = self.inner;
            var iterator = inner.iterator();
            while (iterator.next()) |entry| {
                out = out.conj(entry.key_ptr.*);
            }
            return out;
        }
        pub fn valueSet(self: Self) ValueSet(V) {
            var out = ValueSet(V).empty();
            var inner = self.inner;
            var iterator = inner.iterator();
            while (iterator.next()) |entry| {
                out = out.conj(entry.value_ptr.*);
            }
            return out;
        }
        pub fn eql(self: Self, other: Self) bool {
            if (self.inner.count() != other.inner.count()) return false;
            var inner = self.inner;
            var iterator = inner.iterator();
            while (iterator.next()) |entry| {
                const other_value = other.inner.get(entry.key_ptr.*) orelse return false;
                if (!eq(entry.value_ptr.*, other_value)) return false;
            }
            return true;
        }
        pub fn hashValue(self: Self) i32 {
            var acc: i32 = 0;
            var inner = self.inner;
            var iterator = inner.iterator();
            while (iterator.next()) |entry| {
                acc +%= mixHash(hash32(entry.key_ptr.*), hash32(entry.value_ptr.*));
            }
            return mixHash(7, acc);
        }
    };
}

/// Persistent target-private map for keyword and compound keys. Linear lookup
/// keeps the implementation small while preserving clojure-value equality,
/// clojure-hash, and immutable assoc semantics.
pub fn ValueMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { key: K, value: V };

        entries: []const Entry,

        pub fn empty() Self {
            return .{ .entries = &.{} };
        }
        pub fn assoc(self: Self, key: K, value: V) Self {
            var found: ?usize = null;
            for (self.entries, 0..) |entry, i| {
                if (eq(entry.key, key)) {
                    found = i;
                    break;
                }
            }
            const out_len = self.entries.len + @intFromBool(found == null);
            const out = cliAlloc().alloc(Entry, out_len) catch @panic("oom");
            @memcpy(out[0..self.entries.len], self.entries);
            if (found) |i| {
                out[i] = .{ .key = key, .value = value };
            } else {
                out[self.entries.len] = .{ .key = key, .value = value };
            }
            return .{ .entries = out };
        }
        pub fn get(self: Self, key: K) ?V {
            for (self.entries) |entry| {
                if (eq(entry.key, key)) return entry.value;
            }
            return null;
        }
        pub fn contains(self: Self, key: K) bool {
            for (self.entries) |entry| {
                if (eq(entry.key, key)) return true;
            }
            return false;
        }
        pub fn len(self: Self) i64 {
            return @intCast(self.entries.len);
        }
        pub fn keySet(self: Self) ValueSet(K) {
            var out = ValueSet(K).empty();
            for (self.entries) |entry| {
                out = out.conj(entry.key);
            }
            return out;
        }
        pub fn valueSet(self: Self) ValueSet(V) {
            var out = ValueSet(V).empty();
            for (self.entries) |entry| {
                out = out.conj(entry.value);
            }
            return out;
        }
        pub fn eql(self: Self, other: Self) bool {
            if (self.entries.len != other.entries.len) return false;
            for (self.entries) |entry| {
                const other_value = other.get(entry.key) orelse return false;
                if (!eq(entry.value, other_value)) return false;
            }
            return true;
        }
        pub fn hashValue(self: Self) i32 {
            var acc: i32 = 0;
            for (self.entries) |entry| {
                acc +%= mixHash(hash32(entry.key), hash32(entry.value));
            }
            return mixHash(7, acc);
        }
    };
}

/// Persistent target-private set. Elements deduplicate by logical value and
/// hash order-independently.
pub fn ValueSet(comptime T: type) type {
    return struct {
        const Self = @This();

        values: []const T,

        pub fn empty() Self {
            return .{ .values = &.{} };
        }
        pub fn conj(self: Self, value: T) Self {
            if (self.contains(value)) return self;
            const out = cliAlloc().alloc(T, self.values.len + 1) catch @panic("oom");
            @memcpy(out[0..self.values.len], self.values);
            out[self.values.len] = value;
            return .{ .values = out };
        }
        pub fn contains(self: Self, value: T) bool {
            for (self.values) |item| {
                if (eq(item, value)) return true;
            }
            return false;
        }
        pub fn len(self: Self) i64 {
            return @intCast(self.values.len);
        }
        pub fn eql(self: Self, other: Self) bool {
            if (self.values.len != other.values.len) return false;
            for (self.values) |item| {
                if (!other.contains(item)) return false;
            }
            return true;
        }
        pub fn hashValue(self: Self) i32 {
            var acc: i32 = 0;
            for (self.values) |item| acc +%= hash32(item);
            return mixHash(6, acc);
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

// --- checked regex contract --------------------------------------------------
// The checker admits a deliberately small, portable subset: concatenation,
// groups, classes, anchors, greedy quantifiers, and the common ASCII escape
// classes. Matching advances by UTF-8 code point; returned values remain byte
// slices into the original string.
pub const Regex = struct {
    pattern: []const u8,
};

pub fn regex(pattern: []const u8) Regex {
    return .{ .pattern = pattern };
}

pub fn RegexMatch(comptime n: usize) type {
    return [n]?[]const u8;
}

const regex_max_captures = 16;
const regex_max_results = 256;

const RegexState = struct {
    pos: usize,
    starts: [regex_max_captures]?usize = @splat(null),
    ends: [regex_max_captures]?usize = @splat(null),
};

const RegexStates = struct {
    values: [regex_max_results]RegexState = undefined,
    len: usize = 0,

    fn add(self: *RegexStates, value: RegexState) void {
        if (self.len == self.values.len) return;
        self.values[self.len] = value;
        self.len += 1;
    }
};

const RegexAtomKind = enum { literal, dot, class, group, anchor_start, anchor_end };

const RegexAtom = struct {
    kind: RegexAtomKind,
    next: usize,
    value: u21 = 0,
    class_start: usize = 0,
    class_end: usize = 0,
    group_start: usize = 0,
    group_end: usize = 0,
    capture: ?usize = null,
};

const RegexQuantifier = struct {
    min: usize,
    max: usize,
    next: usize,
};

const Codepoint = struct {
    value: u21,
    next: usize,
};

fn regexCodepointAt(s: []const u8, pos: usize) ?Codepoint {
    if (pos >= s.len) return null;
    const width = std.unicode.utf8ByteSequenceLength(s[pos]) catch return null;
    const end = pos + width;
    if (end > s.len) return null;
    return .{
        .value = std.unicode.utf8Decode(s[pos..end]) catch return null,
        .next = end,
    };
}

fn regexEscapedClass(ch: u8, cp: u21) ?bool {
    const ascii = cp <= 0x7f;
    const c: u8 = if (ascii) @intCast(cp) else 0;
    return switch (ch) {
        'd' => ascii and std.ascii.isDigit(c),
        'D' => !(ascii and std.ascii.isDigit(c)),
        's' => ascii and std.ascii.isWhitespace(c),
        'S' => !(ascii and std.ascii.isWhitespace(c)),
        'w' => ascii and (std.ascii.isAlphanumeric(c) or c == '_'),
        'W' => !(ascii and (std.ascii.isAlphanumeric(c) or c == '_')),
        else => null,
    };
}

fn regexCaptureIndex(pattern: []const u8, stop: usize) usize {
    var capture_index: usize = 1;
    var i: usize = 0;
    var in_class = false;
    while (i < stop) {
        if (pattern[i] == '\\') {
            i += @min(2, stop - i);
            continue;
        }
        if (pattern[i] == '[') in_class = true;
        if (pattern[i] == ']') in_class = false;
        if (!in_class and pattern[i] == '(' and
            !(i + 2 < pattern.len and pattern[i + 1] == '?' and pattern[i + 2] == ':'))
        {
            capture_index += 1;
        }
        i += 1;
    }
    return capture_index;
}

fn regexGroupEnd(pattern: []const u8, start: usize, end: usize) usize {
    var depth: usize = 1;
    var i = start;
    var in_class = false;
    while (i < end) {
        if (pattern[i] == '\\') {
            i += @min(2, end - i);
            continue;
        }
        if (pattern[i] == '[') {
            in_class = true;
        } else if (pattern[i] == ']') {
            in_class = false;
        } else if (!in_class and pattern[i] == '(') {
            depth += 1;
        } else if (!in_class and pattern[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    unreachable;
}

fn regexAtom(pattern: []const u8, at: usize, end: usize) RegexAtom {
    const ch = pattern[at];
    if (ch == '^') return .{ .kind = .anchor_start, .next = at + 1 };
    if (ch == '$') return .{ .kind = .anchor_end, .next = at + 1 };
    if (ch == '.') return .{ .kind = .dot, .next = at + 1 };
    if (ch == '[') {
        var i = at + 1;
        if (i < end and pattern[i] == '^') i += 1;
        while (i < end and pattern[i] != ']') {
            i += if (pattern[i] == '\\') @min(2, end - i) else 1;
        }
        return .{
            .kind = .class,
            .next = i + 1,
            .class_start = at + 1,
            .class_end = i,
        };
    }
    if (ch == '(') {
        const noncapturing =
            at + 2 < end and pattern[at + 1] == '?' and pattern[at + 2] == ':';
        const body_start = at + (if (noncapturing) @as(usize, 3) else 1);
        const close = regexGroupEnd(pattern, body_start, end);
        return .{
            .kind = .group,
            .next = close + 1,
            .group_start = body_start,
            .group_end = close,
            .capture = if (noncapturing) null else regexCaptureIndex(pattern, at),
        };
    }
    if (ch == '\\') {
        const escaped = pattern[at + 1];
        if (regexEscapedClass(escaped, 0) != null) {
            return .{ .kind = .class, .next = at + 2, .class_start = at, .class_end = at + 2 };
        }
        return .{ .kind = .literal, .next = at + 2, .value = escaped };
    }
    const cp = regexCodepointAt(pattern, at).?;
    return .{ .kind = .literal, .next = cp.next, .value = cp.value };
}

fn regexUnsigned(pattern: []const u8, at: *usize, end: usize) usize {
    var value: usize = 0;
    while (at.* < end and std.ascii.isDigit(pattern[at.*])) : (at.* += 1) {
        value = value * 10 + pattern[at.*] - '0';
    }
    return value;
}

fn regexQuantifier(pattern: []const u8, at: usize, end: usize, source_len: usize) RegexQuantifier {
    if (at >= end) return .{ .min = 1, .max = 1, .next = at };
    return switch (pattern[at]) {
        '?' => .{ .min = 0, .max = 1, .next = at + 1 },
        '*' => .{ .min = 0, .max = source_len + 1, .next = at + 1 },
        '+' => .{ .min = 1, .max = source_len + 1, .next = at + 1 },
        '{' => blk: {
            var i = at + 1;
            const min = regexUnsigned(pattern, &i, end);
            if (i < end and pattern[i] == '}') {
                break :blk .{ .min = min, .max = min, .next = i + 1 };
            }
            i += 1;
            const max = if (i < end and pattern[i] == '}')
                source_len + 1
            else
                regexUnsigned(pattern, &i, end);
            break :blk .{ .min = min, .max = max, .next = i + 1 };
        },
        else => .{ .min = 1, .max = 1, .next = at },
    };
}

fn regexClassMatches(pattern: []const u8, start: usize, end: usize, cp: u21) bool {
    var i = start;
    const negated = i < end and pattern[i] == '^';
    if (negated) i += 1;
    var matched = false;
    while (i < end) {
        if (pattern[i] == '\\') {
            const escaped = pattern[i + 1];
            if (regexEscapedClass(escaped, cp)) |yes| {
                matched = matched or yes;
            } else {
                matched = matched or cp == escaped;
            }
            i += 2;
            continue;
        }
        const range_start = regexCodepointAt(pattern, i).?;
        if (range_start.next < end and pattern[range_start.next] == '-' and range_start.next + 1 < end) {
            const last = regexCodepointAt(pattern, range_start.next + 1).?;
            matched = matched or (cp >= range_start.value and cp <= last.value);
            i = last.next;
        } else {
            matched = matched or cp == range_start.value;
            i = range_start.next;
        }
    }
    return if (negated) !matched else matched;
}

fn regexCollectSequence(
    pattern: []const u8,
    at: usize,
    end: usize,
    source: []const u8,
    state: RegexState,
    out: *RegexStates,
) void {
    if (out.len == regex_max_results) return;
    if (at >= end) {
        out.add(state);
        return;
    }
    const atom = regexAtom(pattern, at, end);
    const quant = regexQuantifier(pattern, atom.next, end, source.len);
    regexCollectRepeat(pattern, atom, quant, quant.next, end, source, state, 0, out);
}

fn regexCollectAtom(
    pattern: []const u8,
    atom: RegexAtom,
    source: []const u8,
    state: RegexState,
    out: *RegexStates,
) void {
    switch (atom.kind) {
        .anchor_start => if (state.pos == 0) out.add(state),
        .anchor_end => if (state.pos == source.len) out.add(state),
        .literal, .dot, .class => {
            const cp = regexCodepointAt(source, state.pos) orelse return;
            const matched = switch (atom.kind) {
                .literal => cp.value == atom.value,
                .dot => cp.value != '\n',
                .class => if (atom.class_start == atom.class_end - 2 and
                    pattern[atom.class_start] == '\\')
                    regexEscapedClass(pattern[atom.class_start + 1], cp.value).?
                else
                    regexClassMatches(pattern, atom.class_start, atom.class_end, cp.value),
                else => unreachable,
            };
            if (matched) {
                var next = state;
                next.pos = cp.next;
                out.add(next);
            }
        },
        .group => {
            var initial = state;
            if (atom.capture) |capture| {
                initial.starts[capture] = state.pos;
                initial.ends[capture] = null;
            }
            var matches = RegexStates{};
            regexCollectSequence(
                pattern,
                atom.group_start,
                atom.group_end,
                source,
                initial,
                &matches,
            );
            for (matches.values[0..matches.len]) |raw| {
                var matched = raw;
                if (atom.capture) |capture| matched.ends[capture] = raw.pos;
                out.add(matched);
            }
        },
    }
}

fn regexCollectRepeat(
    pattern: []const u8,
    atom: RegexAtom,
    quant: RegexQuantifier,
    pattern_next: usize,
    end: usize,
    source: []const u8,
    state: RegexState,
    repetition_count: usize,
    out: *RegexStates,
) void {
    if (repetition_count < quant.max) {
        var next_states = RegexStates{};
        regexCollectAtom(pattern, atom, source, state, &next_states);
        for (next_states.values[0..next_states.len]) |next| {
            if (next.pos != state.pos or quant.max == 1) {
                regexCollectRepeat(
                    pattern,
                    atom,
                    quant,
                    pattern_next,
                    end,
                    source,
                    next,
                    repetition_count + 1,
                    out,
                );
            }
        }
    }
    if (repetition_count >= quant.min) {
        regexCollectSequence(pattern, pattern_next, end, source, state, out);
    }
}

fn regexFindStateFrom(re: Regex, source: []const u8, from: usize) ?RegexState {
    var start = from;
    while (start <= source.len) {
        var initial = RegexState{ .pos = start };
        initial.starts[0] = start;
        var matches = RegexStates{};
        regexCollectSequence(re.pattern, 0, re.pattern.len, source, initial, &matches);
        if (matches.len > 0) {
            var result = matches.values[0];
            result.ends[0] = result.pos;
            return result;
        }
        const cp = regexCodepointAt(source, start) orelse break;
        start = cp.next;
    }
    return null;
}

fn regexMatchesState(re: Regex, source: []const u8) ?RegexState {
    var initial = RegexState{ .pos = 0 };
    initial.starts[0] = 0;
    var matches = RegexStates{};
    regexCollectSequence(re.pattern, 0, re.pattern.len, source, initial, &matches);
    for (matches.values[0..matches.len]) |raw| {
        if (raw.pos == source.len) {
            var result = raw;
            result.ends[0] = source.len;
            return result;
        }
    }
    return null;
}

fn regexSlice(source: []const u8, state: RegexState, index: usize) ?[]const u8 {
    const start = state.starts[index] orelse return null;
    const end = state.ends[index] orelse return null;
    return source[start..end];
}

pub fn re_find0(re: Regex, source: []const u8) ?[]const u8 {
    const state = regexFindStateFrom(re, source, 0) orelse return null;
    return regexSlice(source, state, 0);
}

pub fn re_find(comptime capture_count: usize, re: Regex, source: []const u8) ?RegexMatch(capture_count + 1) {
    const state = regexFindStateFrom(re, source, 0) orelse return null;
    var result: RegexMatch(capture_count + 1) = undefined;
    inline for (0..capture_count + 1) |i| result[i] = regexSlice(source, state, i);
    return result;
}

pub fn re_matches0(re: Regex, source: []const u8) ?[]const u8 {
    const state = regexMatchesState(re, source) orelse return null;
    return regexSlice(source, state, 0);
}

pub fn re_matches(comptime capture_count: usize, re: Regex, source: []const u8) ?RegexMatch(capture_count + 1) {
    const state = regexMatchesState(re, source) orelse return null;
    var result: RegexMatch(capture_count + 1) = undefined;
    inline for (0..capture_count + 1) |i| result[i] = regexSlice(source, state, i);
    return result;
}

pub fn regex_replace(source: []const u8, re: Regex, replacement: []const u8) []const u8 {
    var cursor: usize = 0;
    var size: usize = 0;
    while (regexFindStateFrom(re, source, cursor)) |matched| {
        const start = matched.starts[0].?;
        const end = matched.ends[0].?;
        size += start - cursor + replacement.len;
        if (end == start) {
            const cp = regexCodepointAt(source, end) orelse {
                cursor = end;
                break;
            };
            size += cp.next - end;
            cursor = cp.next;
        } else {
            cursor = end;
        }
    }
    size += source.len - cursor;

    const out = cliAlloc().alloc(u8, size) catch @panic("oom");
    cursor = 0;
    var written: usize = 0;
    while (regexFindStateFrom(re, source, cursor)) |matched| {
        const start = matched.starts[0].?;
        const end = matched.ends[0].?;
        @memcpy(out[written .. written + start - cursor], source[cursor..start]);
        written += start - cursor;
        @memcpy(out[written .. written + replacement.len], replacement);
        written += replacement.len;
        if (end == start) {
            const cp = regexCodepointAt(source, end) orelse {
                cursor = end;
                break;
            };
            @memcpy(out[written .. written + cp.next - end], source[end..cp.next]);
            written += cp.next - end;
            cursor = cp.next;
        } else {
            cursor = end;
        }
    }
    @memcpy(out[written..], source[cursor..]);
    return out;
}

pub fn regex_split(source: []const u8, re: Regex) []const []const u8 {
    var match_count: usize = 0;
    var cursor: usize = 0;
    while (regexFindStateFrom(re, source, cursor)) |matched| {
        match_count += 1;
        const start = matched.starts[0].?;
        const end = matched.ends[0].?;
        if (end == start) {
            const cp = regexCodepointAt(source, end) orelse break;
            cursor = cp.next;
        } else {
            cursor = end;
        }
    }
    const out = cliAlloc().alloc([]const u8, match_count + 1) catch @panic("oom");
    cursor = 0;
    var piece_count: usize = 0;
    while (regexFindStateFrom(re, source, cursor)) |matched| {
        const start = matched.starts[0].?;
        const end = matched.ends[0].?;
        out[piece_count] = source[cursor..start];
        piece_count += 1;
        if (end == start) {
            const cp = regexCodepointAt(source, end) orelse {
                cursor = end;
                break;
            };
            cursor = cp.next;
        } else {
            cursor = end;
        }
    }
    out[piece_count] = source[cursor..];
    piece_count += 1;
    while (piece_count > 0 and out[piece_count - 1].len == 0) piece_count -= 1;
    return out[0..piece_count];
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

// --- stdout (clojure.core println) ------------------------------------------
pub fn println(s: []const u8) void {
    const out = std.Io.File.stdout();
    out.writeStreamingAll(io(), s) catch {};
    out.writeStreamingAll(io(), "\n") catch {};
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
