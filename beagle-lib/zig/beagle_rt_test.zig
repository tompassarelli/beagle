//! Runtime-owned tests for the prelude's persistent containers. Kept out of
//! beagle_rt.zig so the prelude the emitted code sees stays the declared cut.

const std = @import("std");
const rt = @import("beagle_rt.zig");

const IntMap = rt.Map(i64);

/// zig 0.17 removed std.time.Timer; monotonic nanos come off the prelude's
/// own Io executor.
fn nowNs() i96 {
    return std.Io.Timestamp.now(rt.io(), .awake).nanoseconds;
}

test "assoc leaves the source map observing its own contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m1 = IntMap.empty(alloc).assoc(alloc, "a", 1).assoc(alloc, "b", 2);
    const m2 = m1.assoc(alloc, "c", 3);
    const m3 = m1.assoc(alloc, "a", 99);

    try std.testing.expectEqual(@as(i64, 2), m1.len());
    try std.testing.expectEqual(@as(i64, 3), m2.len());
    try std.testing.expectEqual(@as(i64, 2), m3.len());

    try std.testing.expectEqual(@as(?i64, 1), m1.get("a"));
    try std.testing.expectEqual(@as(?i64, null), m1.get("c"));
    try std.testing.expectEqual(@as(?i64, 1), m2.get("a"));
    try std.testing.expectEqual(@as(?i64, 3), m2.get("c"));
    try std.testing.expectEqual(@as(?i64, 99), m3.get("a"));
    try std.testing.expectEqual(@as(?i64, 2), m3.get("b"));

    try std.testing.expect(m1.contains("b"));
    try std.testing.expect(!m1.contains("c"));
}

test "aliasing holds across a deep chain of assocs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = 4096;
    var snapshots: [8]IntMap = undefined;
    var m = IntMap.empty(alloc);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const key = std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable;
        m = m.assoc(alloc, key, i);
        if (@mod(i, 512) == 0) snapshots[@intCast(@divTrunc(i, 512))] = m;
    }

    for (snapshots, 0..) |snapshot, s| {
        const at: i64 = @intCast(s * 512);
        try std.testing.expectEqual(at + 1, snapshot.len());
        try std.testing.expectEqual(@as(?i64, 0), snapshot.get("k0"));
        try std.testing.expectEqual(@as(?i64, at), snapshot.get(
            std.fmt.allocPrint(alloc, "k{d}", .{at}) catch unreachable,
        ));
        try std.testing.expectEqual(@as(?i64, null), snapshot.get(
            std.fmt.allocPrint(alloc, "k{d}", .{at + 1}) catch unreachable,
        ));
    }
    try std.testing.expectEqual(@as(i64, n), m.len());
}

test "dissoc removes exactly one key and leaves the source intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m = IntMap.empty(alloc);
    var i: i64 = 0;
    while (i < 300) : (i += 1) {
        m = m.assoc(alloc, std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable, i);
    }

    const dropped = m.dissoc(alloc, "k7").dissoc(alloc, "k299").dissoc(alloc, "absent");
    try std.testing.expectEqual(@as(i64, 300), m.len());
    try std.testing.expectEqual(@as(i64, 298), dropped.len());
    try std.testing.expectEqual(@as(?i64, 7), m.get("k7"));
    try std.testing.expectEqual(@as(?i64, null), dropped.get("k7"));
    try std.testing.expectEqual(@as(?i64, null), dropped.get("k299"));
    try std.testing.expectEqual(@as(?i64, 8), dropped.get("k8"));

    // emptying and refilling round-trips through the collapsed-root path
    var drained = m;
    i = 0;
    while (i < 300) : (i += 1) {
        drained = drained.dissoc(alloc, std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable);
    }
    try std.testing.expectEqual(@as(i64, 0), drained.len());
    try std.testing.expectEqual(@as(?i64, null), drained.get("k0"));
    try std.testing.expectEqual(@as(i64, 1), drained.assoc(alloc, "x", 1).len());
}

test "keys colliding on the leading 5-bit chunks stay distinguishable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Keys whose Wyhash digests agree on the low 10 bits (two chunk levels)
    // are found by search, so the deep-path/merge branches actually run.
    var group = std.ArrayList([]const u8).empty;
    defer group.deinit(alloc);
    const target = std.hash.Wyhash.hash(0, "seed-key") & 0x3ff;
    var probe: usize = 0;
    while (probe < 4_000_000 and group.items.len < 12) : (probe += 1) {
        const key = std.fmt.allocPrint(alloc, "c{d}", .{probe}) catch unreachable;
        if (std.hash.Wyhash.hash(0, key) & 0x3ff == target) {
            group.append(alloc, key) catch unreachable;
        }
    }
    try std.testing.expect(group.items.len >= 8);

    var m = IntMap.empty(alloc);
    for (group.items, 0..) |key, i| m = m.assoc(alloc, key, @intCast(i));
    try std.testing.expectEqual(@as(i64, @intCast(group.items.len)), m.len());
    for (group.items, 0..) |key, i| {
        try std.testing.expectEqual(@as(?i64, @intCast(i)), m.get(key));
    }

    const without = m.dissoc(alloc, group.items[3]);
    try std.testing.expectEqual(@as(i64, @intCast(group.items.len - 1)), without.len());
    try std.testing.expectEqual(@as(?i64, null), without.get(group.items[3]));
    for (group.items, 0..) |key, i| {
        if (i == 3) continue;
        try std.testing.expectEqual(@as(?i64, @intCast(i)), without.get(key));
    }
}

test "randomized insert/remove tracks a reference model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var model = std.StringHashMap(i64).init(std.testing.allocator);
    defer model.deinit();
    var rng = rt.Splitmix64.init(0xB3A6_1E55);

    var m = IntMap.empty(alloc);
    var step: usize = 0;
    while (step < 20_000) : (step += 1) {
        const key = std.fmt.allocPrint(alloc, "r{d}", .{rng.below(2000)}) catch unreachable;
        if (rng.below(3) == 0) {
            m = m.dissoc(alloc, key);
            _ = model.remove(key);
        } else {
            const value: i64 = @intCast(rng.below(1_000_000));
            m = m.assoc(alloc, key, value);
            model.put(key, value) catch unreachable;
        }
        try std.testing.expectEqual(@as(i64, @intCast(model.count())), m.len());
    }

    var it = model.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqual(@as(?i64, entry.value_ptr.*), m.get(entry.key_ptr.*));
    }
    var seen: usize = 0;
    var mine = m.iterator();
    while (mine.next()) |entry| : (seen += 1) {
        try std.testing.expectEqual(@as(?i64, entry.value), model.get(entry.key));
    }
    try std.testing.expectEqual(model.count(), seen);
}

test "equality and hash ignore insertion order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = 500;
    var forward = IntMap.empty(alloc);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        forward = forward.assoc(alloc, std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable, i * 3);
    }
    var backward = IntMap.empty(alloc);
    i = n - 1;
    while (i >= 0) : (i -= 1) {
        backward = backward.assoc(alloc, std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable, i * 3);
    }
    // A shadowed key must not leak the stale value into equality or hash.
    const shadowed = forward.assoc(alloc, "k0", -1).assoc(alloc, "k0", 0);

    try std.testing.expect(forward.eql(backward));
    try std.testing.expect(backward.eql(forward));
    try std.testing.expect(forward.eql(shadowed));
    try std.testing.expect(rt.eq(forward, backward));
    try std.testing.expectEqual(rt.hash(forward), rt.hash(backward));
    try std.testing.expectEqual(rt.hash(forward), rt.hash(shadowed));

    const different = backward.assoc(alloc, "k0", 12345);
    try std.testing.expect(!forward.eql(different));
    try std.testing.expect(!rt.eq(forward, different));

    const shorter = backward.dissoc(alloc, "k0");
    try std.testing.expect(!forward.eql(shorter));
}

test "iteration order depends on the key set, not the insertion order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = 200;
    var forward = IntMap.empty(alloc);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        forward = forward.assoc(alloc, std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable, i);
    }
    var backward = IntMap.empty(alloc);
    i = n - 1;
    while (i >= 0) : (i -= 1) {
        backward = backward.assoc(alloc, std.fmt.allocPrint(alloc, "k{d}", .{i}) catch unreachable, i);
    }
    try std.testing.expectEqualStrings(forward.prStr(alloc), backward.prStr(alloc));

    const small = IntMap.empty(alloc).assoc(alloc, "a", 1).assoc(alloc, "b", 2);
    try std.testing.expectEqual(@as(i64, 2), rt.count(small));
    try std.testing.expect(!rt.is_empty(small));
    try std.testing.expect(rt.is_empty(IntMap.empty(alloc)));
    try std.testing.expect(rt.is_map(small));
    try std.testing.expectEqual(@as(i64, 2), small.keySet(alloc).len());
    try std.testing.expectEqual(@as(i64, 2), small.valueSet(alloc).len());
    try std.testing.expect(small.keySet(alloc).contains("a"));
    try std.testing.expect(small.valueSet(alloc).contains(@as(i64, 2)));
}

test "nested map values keep structural equality and print" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Inner = rt.Map(i64);
    const Outer = rt.Map(Inner);
    const a = Outer.empty(alloc).assoc(
        alloc,
        "one",
        Inner.empty(alloc).assoc(alloc, "x", 1).assoc(alloc, "y", 2),
    );
    const b = Outer.empty(alloc).assoc(
        alloc,
        "one",
        Inner.empty(alloc).assoc(alloc, "y", 2).assoc(alloc, "x", 1),
    );
    try std.testing.expect(rt.eq(a, b));
    try std.testing.expectEqual(rt.hash(a), rt.hash(b));
    try std.testing.expectEqualStrings(a.prStr(alloc), b.prStr(alloc));
}

// Guards the growth rate, not a wall-clock budget: only the doubling ratio
// catches a regression back toward clone-per-assoc.
test "100k sequential assocs scale sub-quadratically" {
    const n: i64 = 100_000;

    var keys_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer keys_arena.deinit();
    const keys_alloc = keys_arena.allocator();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(keys_alloc);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        keys.append(keys_alloc, std.fmt.allocPrint(keys_alloc, "key{d}", .{i}) catch unreachable) catch unreachable;
    }

    var new_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer new_arena.deinit();
    const new_alloc = new_arena.allocator();
    var started = nowNs();
    var hamt = IntMap.empty(new_alloc);
    for (keys.items, 0..) |key, idx| hamt = hamt.assoc(new_alloc, key, @intCast(idx));
    const hamt_ns = nowNs() - started;
    try std.testing.expectEqual(n, hamt.len());
    try std.testing.expectEqual(@as(?i64, 0), hamt.get("key0"));
    try std.testing.expectEqual(@as(?i64, n - 1), hamt.get(keys.items[@intCast(n - 1)]));

    var scale_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scale_arena.deinit();
    const scale_alloc = scale_arena.allocator();
    started = nowNs();
    var half = IntMap.empty(scale_alloc);
    for (keys.items[0 .. @as(usize, @intCast(n)) / 2], 0..) |key, idx| {
        half = half.assoc(scale_alloc, key, @intCast(idx));
    }
    const half_ns = nowNs() - started;

    std.debug.print(
        "\n  100000 assocs: {d} ms\n   50000 assocs: {d} ms (ratio {d:.2})\n",
        .{
            @divTrunc(hamt_ns, std.time.ns_per_ms),
            @divTrunc(half_ns, std.time.ns_per_ms),
            @as(f64, @floatFromInt(hamt_ns)) / @as(f64, @floatFromInt(half_ns)),
        },
    );

    // Doubling the input must not quadruple the work.
    try std.testing.expect(hamt_ns < half_ns * 3);
}
