//! World state + the tick loop. Memory model per the brief §2:
//!
//!   - tick arena: every per-tick temporary; reset exactly once per
//!     tick AFTER commit, by this harness, never by kernel code.
//!   - mind state: double-buffered SoA (world[0]/world[1]); the tick
//!     reads `read` immutably, writes next values into `write` at
//!     commit, then swaps.
//!   - voxel grid: third store (scope amendment) — read immutably
//!     during the tick; dig edits accumulate in the tick arena and are
//!     applied in place at commit.
//!
//! In Debug builds the arena's child is the debug allocator and reset
//! uses .free_all, so any pointer retained across a tick is a detected
//! use-after-free. Release builds reset with .retain_capacity.

const std = @import("std");
const builtin = @import("builtin");
const det = @import("determinism.zig");
const sim = @import("sim.zig");
const voxel = @import("voxel.zig");

pub const N_MINDS: usize = 300;
pub const N_WELLS: usize = 4;
pub const WELL_RADIUS: i64 = 18;
pub const SOCIAL_RADIUS: i64 = 6;

pub const Minds = struct {
    x: []i64,
    z: []i64,
    belief: []i64,
    alarm: []i64,

    fn init(alloc: std.mem.Allocator) !Minds {
        return .{
            .x = try alloc.alloc(i64, N_MINDS),
            .z = try alloc.alloc(i64, N_MINDS),
            .belief = try alloc.alloc(i64, N_MINDS),
            .alarm = try alloc.alloc(i64, N_MINDS),
        };
    }

    fn deinit(self: *Minds, alloc: std.mem.Allocator) void {
        alloc.free(self.x);
        alloc.free(self.z);
        alloc.free(self.belief);
        alloc.free(self.alarm);
    }
};

pub const Well = struct { x: i64, z: i64 };

pub const World = struct {
    alloc: std.mem.Allocator,
    buffers: [2]Minds,
    read_ix: usize = 0,
    grid: voxel.Grid,
    wells: [N_WELLS]Well,
    rng: det.Splitmix64,
    tick_no: u64 = 0,
    hash: det.Fnv1a = .{},
    // cumulative decision histogram + digs (diagnostics; not hashed)
    act_counts: [5]u64 = .{ 0, 0, 0, 0, 0 },
    digs_applied: u64 = 0,
    // per-tick stats for the render layer
    last_decisions: []i64,

    pub fn init(alloc: std.mem.Allocator, seed: u64) !World {
        var w = World{
            .alloc = alloc,
            .buffers = .{ try Minds.init(alloc), try Minds.init(alloc) },
            .grid = try voxel.Grid.init(alloc, seed),
            .wells = undefined,
            .rng = det.Splitmix64.init(seed),
            .last_decisions = try alloc.alloc(i64, N_MINDS),
        };
        @memset(w.last_decisions, 0);
        for (&w.wells) |*well| {
            well.* = .{
                .x = @intCast(8 + w.rng.below(voxel.SIZE_X - 16)),
                .z = @intCast(8 + w.rng.below(voxel.SIZE_Z - 16)),
            };
        }
        const m = &w.buffers[0];
        for (0..N_MINDS) |i| {
            m.x[i] = @intCast(w.rng.below(voxel.SIZE_X));
            m.z[i] = @intCast(w.rng.below(voxel.SIZE_Z));
            m.belief[i] = 0;
            m.alarm[i] = 0;
        }
        // write buffer starts as a copy
        copyMinds(&w.buffers[1], &w.buffers[0]);
        return w;
    }

    pub fn deinit(self: *World) void {
        self.buffers[0].deinit(self.alloc);
        self.buffers[1].deinit(self.alloc);
        self.grid.deinit(self.alloc);
        self.alloc.free(self.last_decisions);
    }

    pub fn read(self: *const World) *const Minds {
        return &self.buffers[self.read_ix];
    }

    fn write(self: *World) *Minds {
        return &self.buffers[1 - self.read_ix];
    }

    fn copyMinds(dst: *Minds, src: *const Minds) void {
        @memcpy(dst.x, src.x);
        @memcpy(dst.z, src.z);
        @memcpy(dst.belief, src.belief);
        @memcpy(dst.alarm, src.alarm);
    }

    fn clampCoord(v: i64, max: i64) i64 {
        return @max(0, @min(v, max - 1));
    }

    /// Ambient dread at (x,z): max over wells of radius falloff, 0..1000.
    fn wellThreat(self: *const World, x: i64, z: i64) i64 {
        var best: i64 = 0;
        for (self.wells) |well| {
            const d = @max(@abs(x - well.x), @abs(z - well.z));
            const di: i64 = @intCast(d);
            if (di < WELL_RADIUS) {
                const t = @divTrunc((WELL_RADIUS - di) * 1000, WELL_RADIUS);
                if (t > best) best = t;
            }
        }
        return best;
    }

    /// Unit step away from the strongest well (0 if none in range).
    fn awayFromWell(self: *const World, x: i64, z: i64) struct { dx: i64, dz: i64 } {
        var best: i64 = 0;
        var bx: i64 = 0;
        var bz: i64 = 0;
        var found = false;
        for (self.wells) |well| {
            const d: i64 = @intCast(@max(@abs(x - well.x), @abs(z - well.z)));
            if (d < WELL_RADIUS and (!found or d < best)) {
                best = d;
                bx = well.x;
                bz = well.z;
                found = true;
            }
        }
        if (!found) return .{ .dx = 0, .dz = 0 };
        return .{
            .dx = if (x > bx) 1 else if (x < bx) -1 else 0,
            .dz = if (z > bz) 1 else if (z < bz) -1 else 0,
        };
    }

    /// One tick: pure passes over world_read with temporaries in the
    /// tick arena, then commit (apply moves+digs, promote, swap), then
    /// the caller resets the arena.
    pub fn tick(self: *World, tick_alloc: std.mem.Allocator) !void {
        const r = self.read();
        var ctx = sim.Ctx{ .tick = tick_alloc, .rng = &self.rng };

        const beliefs = try tick_alloc.alloc(sim.BeliefOut, N_MINDS);
        const decisions = try tick_alloc.alloc(sim.Decision, N_MINDS);
        var digs = try std.ArrayList(voxel.Edit).initCapacity(tick_alloc, 16);

        // --- belief pass (pure) -------------------------------------------
        for (0..N_MINDS) |i| {
            const m = sim.MindIn{
                .x = r.x[i],
                .z = r.z[i],
                .belief = r.belief[i],
                .alarm = r.alarm[i],
            };
            // observation gathering is harness work
            var social_sum: i64 = 0;
            var social_n: i64 = 0;
            for (0..N_MINDS) |j| {
                if (i == j) continue;
                const d = @max(@abs(r.x[i] - r.x[j]), @abs(r.z[i] - r.z[j]));
                if (@as(i64, @intCast(d)) <= SOCIAL_RADIUS) {
                    social_sum += r.alarm[j];
                    social_n += 1;
                }
            }
            const away = self.awayFromWell(r.x[i], r.z[i]);
            const obs = sim.Obs{
                .well_threat = self.wellThreat(r.x[i], r.z[i]),
                .social = if (social_n > 0) @divTrunc(social_sum, social_n) else 0,
                .well_dx = away.dx,
                .well_dz = away.dz,
            };
            beliefs[i] = sim.beliefUpdate(&ctx, m, obs);
            // decision pass uses the same observation; kept in one loop
            // so rng draws stay in strict mind order.
            decisions[i] = sim.decide(&ctx, m, beliefs[i], obs);
        }

        // --- commit --------------------------------------------------------
        const w = self.write();
        for (0..N_MINDS) |i| {
            var alarm = beliefs[i].alarm;
            if (decisions[i].act == @intFromEnum(sim.Act.dig)) {
                try digs.append(tick_alloc, .{ .x = r.x[i], .z = r.z[i] });
                alarm = sim.digRelief(alarm);
            }
            w.x[i] = clampCoord(r.x[i] + decisions[i].dx, voxel.SIZE_X);
            w.z[i] = clampCoord(r.z[i] + decisions[i].dz, voxel.SIZE_Z);
            w.belief[i] = beliefs[i].belief;
            w.alarm[i] = alarm;
            self.last_decisions[i] = decisions[i].act;
            self.act_counts[@intCast(decisions[i].act)] += 1;
        }
        const applied = self.grid.applyDigs(digs.items);
        self.digs_applied += applied;
        self.read_ix = 1 - self.read_ix;
        self.tick_no += 1;

        // --- conformance fingerprint ----------------------------------------
        self.hash.foldU64(self.tick_no);
        const nr = self.read();
        for (0..N_MINDS) |i| {
            self.hash.foldI64(self.last_decisions[i]);
            self.hash.foldI64(nr.alarm[i]);
            self.hash.foldI64(nr.x[i]);
            self.hash.foldI64(nr.z[i]);
        }
        self.hash.foldU64(applied);
    }
};

/// Headless conformance run: N ticks, no window, debug-allocator-backed
/// arena in Debug builds, prints the final hash.
pub fn runHeadless(base_alloc: std.mem.Allocator, seed: u64, n_ticks: u64) !u64 {
    var world = try World.init(base_alloc, seed);
    defer world.deinit();

    var arena = std.heap.ArenaAllocator.init(base_alloc);
    defer arena.deinit();

    var t: u64 = 0;
    while (t < n_ticks) : (t += 1) {
        try world.tick(arena.allocator());
        // Debug: hand every tick's memory back to the debug allocator so
        // cross-tick retention becomes use-after-free. Release: keep pages.
        if (builtin.mode == .Debug) {
            _ = arena.reset(.free_all);
        } else {
            _ = arena.reset(.retain_capacity);
        }
    }
    std.debug.print(
        "acts: idle={d} wander={d} avoid={d} flee={d} dig={d} digs_applied={d}\n",
        .{ world.act_counts[0], world.act_counts[1], world.act_counts[2], world.act_counts[3], world.act_counts[4], world.digs_applied },
    );
    return world.hash.h;
}
