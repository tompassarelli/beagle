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
