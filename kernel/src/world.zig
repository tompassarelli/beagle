//! World state + the tick loop. Memory model per the brief §2:
//!
//!   - tick arena: every per-tick temporary; reset once per tick AFTER
//!     commit, by this harness, never by kernel code.
//!   - mind state: double-buffered SoA; tick reads `read` immutably,
//!     commit promotes by copy, swap.
//!   - voxel grid: third store — read immutably during the tick; dig
//!     edits applied in deterministic order at commit.
//!
//! Scale semantics v2 (2026-06-13, "way more than thousands"):
//!   - Observation is O(N): per-cell alarm aggregates (cell size
//!     cfg.SOCIAL_CELL); each mind reads its 3x3 cell neighborhood and
//!     subtracts itself. Replaces the exact-radius O(N^2) pair scan.
//!   - RNG is counter-based per (seed, tick, mind): order-independent,
//!     so the pure pass parallelizes across threads while staying
//!     bit-deterministic regardless of scheduling.
//! Script→engine crossing (2026-06-13): the engine layer is GENERATED.
//! sim.zig (emitted from sim_kernel.bgl) now owns the SoA buffers
//! (sim.MindInSoA / sim.StepOutSoA), the gather→step→scatter range
//! loop with the counter-rng policy (sim.tickAllRange), and commit
//! promotion (sim.promoteAll) — all derived from tick-step's typed
//! signature. This harness keeps what is genuinely world-side:
//! resources (grid, wells, precomputed fields), observation gathering,
//! thread spawns, and the conformance fingerprint.
//!
//! In Debug builds the arena's child is the debug allocator and reset
//! uses .free_all, so any pointer retained across a tick is a detected
//! use-after-free. Release builds reset with .retain_capacity.

const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("config.zig");
const det = @import("determinism.zig");
const sim = @import("sim.zig");
const voxel = @import("voxel.zig");

pub const N_MINDS: usize = cfg.N_MINDS;
pub const N_WELLS: usize = cfg.N_WELLS;
pub const WELL_RADIUS: i64 = cfg.WELL_RADIUS;

const CELL: usize = cfg.SOCIAL_CELL;
const CELLS_X: usize = voxel.SIZE_X / CELL + 1;
const CELLS_Z: usize = voxel.SIZE_Z / CELL + 1;

/// Mind state lives in the GENERATED SoA type. Emitted code never
/// frees, so the harness releases the field slices itself.
pub const Minds = sim.MindInSoA;

fn freeMinds(alloc: std.mem.Allocator, m: *Minds) void {
    alloc.free(m.x);
    alloc.free(m.z);
    alloc.free(m.belief);
    alloc.free(m.alarm);
}

pub const Well = struct { x: i64, z: i64 };

pub const World = struct {
    alloc: std.mem.Allocator,
    buffers: [2]Minds,
    read_ix: usize = 0,
    grid: voxel.Grid,
    wells: []Well,
    seed: u64,
    rng: det.Splitmix64, // init-time only (placement); ticks use counter rng
    tick_no: u64 = 0,
    hash: det.Fnv1a = .{},
    act_counts: [5]u64 = .{ 0, 0, 0, 0, 0 },
    digs_applied: u64 = 0,
    last_decisions: []i64,
    // Static-well fields, precomputed once: threat + away-step per
    // column. Same values wellThreat/awayFromWell produced per call —
    // pure precompute, bit-identical results (hash-verified).
    threat_field: []i64,
    away_x: []i8,
    away_z: []i8,

    pub fn init(alloc: std.mem.Allocator, seed: u64) !World {
        var w = World{
            .alloc = alloc,
            .buffers = .{ try Minds.alloc(alloc, N_MINDS), try Minds.alloc(alloc, N_MINDS) },
            .grid = try voxel.Grid.init(alloc, seed),
            .wells = try alloc.alloc(Well, N_WELLS),
            .seed = seed,
            .rng = det.Splitmix64.init(seed),
            .last_decisions = try alloc.alloc(i64, N_MINDS),
            .threat_field = try alloc.alloc(i64, voxel.SIZE_X * voxel.SIZE_Z),
            .away_x = try alloc.alloc(i8, voxel.SIZE_X * voxel.SIZE_Z),
            .away_z = try alloc.alloc(i8, voxel.SIZE_X * voxel.SIZE_Z),
        };
        @memset(w.last_decisions, 0);
        for (w.wells) |*well| {
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
        w.buffers[1].copyFrom(&w.buffers[0], N_MINDS);
        // precompute the dread fields
        var fz: i64 = 0;
        while (fz < voxel.SIZE_Z) : (fz += 1) {
            var fx: i64 = 0;
            while (fx < voxel.SIZE_X) : (fx += 1) {
                const o: usize = @intCast(fx + fz * @as(i64, voxel.SIZE_X));
                w.threat_field[o] = w.wellThreat(fx, fz);
                const away = w.awayFromWell(fx, fz);
                w.away_x[o] = @intCast(away.dx);
                w.away_z[o] = @intCast(away.dz);
            }
        }
        return w;
    }

    pub fn deinit(self: *World) void {
        freeMinds(self.alloc, &self.buffers[0]);
        freeMinds(self.alloc, &self.buffers[1]);
        self.grid.deinit(self.alloc);
        self.alloc.free(self.wells);
        self.alloc.free(self.last_decisions);
        self.alloc.free(self.threat_field);
        self.alloc.free(self.away_x);
        self.alloc.free(self.away_z);
    }

    pub fn read(self: *const World) *const Minds {
        return &self.buffers[self.read_ix];
    }

    fn write(self: *World) *Minds {
        return &self.buffers[1 - self.read_ix];
    }

    /// Ambient dread at (x,z): max over wells of radius falloff, 0..1000.
    fn wellThreat(self: *const World, x: i64, z: i64) i64 {
        var best: i64 = 0;
        for (self.wells) |well| {
            const d: i64 = @intCast(@max(@abs(x - well.x), @abs(z - well.z)));
            if (d < WELL_RADIUS) {
                const t = @divTrunc((WELL_RADIUS - d) * 1000, WELL_RADIUS);
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

    const CellAgg = struct {
        sum: []i64,
        cnt: []i64,
    };

    /// One thread's slice of the tick: gather observations for
    /// [lo, hi) (harness concern — world resources), then hand the
    /// range to the GENERATED engine loop, which owns iteration, the
    /// counter-rng policy, and the SoA gather/scatter. obs[i] feeds
    /// only mind i, so both passes share one range with no barrier.
    fn worker(
        self: *const World,
        r: *const Minds,
        agg: CellAgg,
        obs: []sim.Obs,
        out: *sim.StepOutSoA,
        lo: usize,
        hi: usize,
        tick_alloc: std.mem.Allocator,
    ) void {
        var i = lo;
        while (i < hi) : (i += 1) {
            const cx: i64 = @divTrunc(r.x[i], @as(i64, CELL));
            const cz: i64 = @divTrunc(r.z[i], @as(i64, CELL));
            var social_sum: i64 = -r.alarm[i]; // exclude self
            var social_n: i64 = -1;
            var dz: i64 = -1;
            while (dz <= 1) : (dz += 1) {
                var dx: i64 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = cx + dx;
                    const nz = cz + dz;
                    if (nx >= 0 and nz >= 0 and nx < CELLS_X and nz < CELLS_Z) {
                        const ci: usize = @intCast(nx + nz * @as(i64, CELLS_X));
                        social_sum += agg.sum[ci];
                        social_n += agg.cnt[ci];
                    }
                }
            }
            const fo: usize = @intCast(r.x[i] + r.z[i] * @as(i64, voxel.SIZE_X));
            obs[i] = .{
                .well_threat = self.threat_field[fo],
                .social = if (social_n > 0) @divTrunc(social_sum, social_n) else 0,
                .well_dx = self.away_x[fo],
                .well_dz = self.away_z[fo],
            };
        }
        sim.tickAllRange(tick_alloc, self.seed, self.tick_no, r, obs, voxel.SIZE_X, voxel.SIZE_Z, out, lo, hi);
    }

    pub fn tick(self: *World, tick_alloc: std.mem.Allocator) !void {
        const r = self.read();

        // --- O(N) observation prep: per-cell alarm aggregates --------------
        const agg = CellAgg{
            .sum = try tick_alloc.alloc(i64, CELLS_X * CELLS_Z),
            .cnt = try tick_alloc.alloc(i64, CELLS_X * CELLS_Z),
        };
        @memset(agg.sum, 0);
        @memset(agg.cnt, 0);
        for (0..N_MINDS) |i| {
            const cx: usize = @intCast(@divTrunc(r.x[i], @as(i64, CELL)));
            const cz: usize = @intCast(@divTrunc(r.z[i], @as(i64, CELL)));
            agg.sum[cx + cz * CELLS_X] += r.alarm[i];
            agg.cnt[cx + cz * CELLS_X] += 1;
        }

        // --- pure pass (parallel at scale; deterministic by counter rng) ---
        // Output SoA lives in the tick arena; the generated engine loop
        // does gather→step→scatter per range.
        const obs = try tick_alloc.alloc(sim.Obs, N_MINDS);
        var out = try sim.StepOutSoA.alloc(tick_alloc, N_MINDS);
        if (cfg.N_THREADS <= 1 or N_MINDS < 4096) {
            self.worker(r, agg, obs, &out, 0, N_MINDS, tick_alloc);
        } else {
            var threads: [cfg.N_THREADS]std.Thread = undefined;
            const per = (N_MINDS + cfg.N_THREADS - 1) / cfg.N_THREADS;
            for (0..cfg.N_THREADS) |t| {
                const lo = @min(t * per, N_MINDS);
                const hi = @min(lo + per, N_MINDS);
                threads[t] = std.Thread.spawn(.{}, worker, .{
                    self, r, agg, obs, &out, lo, hi, tick_alloc,
                }) catch @panic("thread spawn");
            }
            for (0..cfg.N_THREADS) |t| threads[t].join();
        }

        // --- commit: transients harness-side, then GENERATED promotion -----
        var digs = try std.ArrayList(voxel.Edit).initCapacity(tick_alloc, 64);
        const w = self.write();
        for (0..N_MINDS) |i| {
            if (out.act[i] == sim.ACT_DIG) {
                try digs.append(tick_alloc, .{ .x = r.x[i], .z = r.z[i] });
            }
            self.last_decisions[i] = out.act[i];
            self.act_counts[@intCast(out.act[i])] += 1;
        }
        sim.promoteAll(&out, w, N_MINDS);
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
