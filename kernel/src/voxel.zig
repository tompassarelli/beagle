//! Voxel grid — the third store in the memory model (thread
//! 20260612232001 scope amendment): preallocated chunked storage,
//! mutated IN PLACE but only at commit, never during the tick. During
//! a tick the grid is read immutably; edits accumulate as values in
//! the tick arena and are applied here in deterministic order at
//! commit, marking chunks dirty for instance-list rebuild.
//!
//! v0 keeps a heightfield-shaped world (one solid column per (x,z))
//! which makes exposure trivial, while storing real per-voxel blocks
//! so nothing structural changes when caves arrive.

const std = @import("std");
const det = @import("determinism.zig");
const cfg = @import("config.zig");

pub const SIZE_X: usize = cfg.SIZE_X;
pub const SIZE_Z: usize = cfg.SIZE_Z;
pub const SIZE_Y: usize = cfg.SIZE_Y;
pub const CHUNK: usize = cfg.CHUNK;
pub const CHUNKS_X: usize = SIZE_X / CHUNK;
pub const CHUNKS_Z: usize = SIZE_Z / CHUNK;

pub const Block = enum(u8) {
    air = 0,
    rock = 1,
    dirt = 2,
    grass = 3,
};

pub const Edit = struct {
    x: i64,
    z: i64,
};

pub const Grid = struct {
    blocks: []Block, // x + z*SIZE_X + y*SIZE_X*SIZE_Z
    height: []i64, // column height per (x,z): top solid y + 1
    dirty: [CHUNKS_X * CHUNKS_Z]bool,

    pub fn init(alloc: std.mem.Allocator, seed: u64) !Grid {
        var g = Grid{
            .blocks = try alloc.alloc(Block, SIZE_X * SIZE_Z * SIZE_Y),
            .height = try alloc.alloc(i64, SIZE_X * SIZE_Z),
            .dirty = @splat(true),
        };
        @memset(g.blocks, .air);
        g.generate(seed);
        return g;
    }

    pub fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.blocks);
        alloc.free(self.height);
    }

    fn idx(x: usize, y: usize, z: usize) usize {
        return x + z * SIZE_X + y * SIZE_X * SIZE_Z;
    }

    pub fn block(self: *const Grid, x: i64, y: i64, z: i64) Block {
        if (x < 0 or z < 0 or y < 0) return .air;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        const uz: usize = @intCast(z);
        if (ux >= SIZE_X or uz >= SIZE_Z or uy >= SIZE_Y) return .air;
        return self.blocks[idx(ux, uy, uz)];
    }

    pub fn heightAt(self: *const Grid, x: i64, z: i64) i64 {
        const ux: usize = @intCast(@max(0, @min(x, @as(i64, SIZE_X - 1))));
        const uz: usize = @intCast(@max(0, @min(z, @as(i64, SIZE_Z - 1))));
        return self.height[ux + uz * SIZE_X];
    }

    /// Deterministic heightfield: 2-octave value noise over a seeded
    /// lattice, bilinear-smoothed, heights in [4, 18].
    fn generate(self: *Grid, seed: u64) void {
        const LAT: usize = SIZE_X / 8 + 1; // lattice points, 8-voxel cells
        var lattice_buf: [LAT * LAT]i64 = undefined;
        const lattice = &lattice_buf;
        var rng = det.Splitmix64.init(seed ^ 0x9E37);
        for (lattice) |*p| p.* = @intCast(rng.below(1 << 16));

        var z: usize = 0;
        while (z < SIZE_Z) : (z += 1) {
            var x: usize = 0;
            while (x < SIZE_X) : (x += 1) {
                const cell = 8;
                const lx = x / cell;
                const lz = z / cell;
                const fx: i64 = @intCast(x % cell);
                const fz: i64 = @intCast(z % cell);
                const c: i64 = cell;
                const v00 = lattice[lx + lz * LAT];
                const v10 = lattice[lx + 1 + lz * LAT];
                const v01 = lattice[lx + (lz + 1) * LAT];
                const v11 = lattice[lx + 1 + (lz + 1) * LAT];
                const top = v00 * (c - fx) + v10 * fx;
                const bot = v01 * (c - fx) + v11 * fx;
                const v = @divTrunc(top * (c - fz) + bot * fz, c * c);
                const h = 4 + @divTrunc(v * 14, 1 << 16); // 4..18
                self.height[x + z * SIZE_X] = h;
                var y: usize = 0;
                while (y < @as(usize, @intCast(h))) : (y += 1) {
                    const uy: i64 = @intCast(y);
                    const b: Block = if (uy == h - 1) .grass else if (uy + 3 >= h) .dirt else .rock;
                    self.blocks[idx(x, y, z)] = b;
                }
            }
        }
    }

    fn markDirtyAround(self: *Grid, x: i64, z: i64) void {
        const cx = @divTrunc(x, @as(i64, CHUNK));
        const cz = @divTrunc(z, @as(i64, CHUNK));
        var dz: i64 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i64 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx = cx + dx;
                const nz = cz + dz;
                if (nx >= 0 and nz >= 0 and nx < CHUNKS_X and nz < CHUNKS_Z) {
                    self.dirty[@intCast(nx + nz * @as(i64, CHUNKS_X))] = true;
                }
            }
        }
    }

    /// Commit-phase only. Applies dig edits in the order given (mind
    /// index order — deterministic). A dig lowers the column by one,
    /// re-grassing the new top. Returns the number applied.
    pub fn applyDigs(self: *Grid, edits: []const Edit) usize {
        var applied: usize = 0;
        for (edits) |e| {
            const h = self.heightAt(e.x, e.z);
            if (h <= 1) continue; // bedrock floor stays
            const ux: usize = @intCast(e.x);
            const uz: usize = @intCast(e.z);
            self.blocks[idx(ux, @intCast(h - 1), uz)] = .air;
            if (h - 2 >= 0) {
                self.blocks[idx(ux, @intCast(h - 2), uz)] = .grass;
            }
            self.height[ux + uz * SIZE_X] = h - 1;
            self.markDirtyAround(e.x, e.z);
            applied += 1;
        }
        return applied;
    }

    /// A voxel is rendered iff solid with at least one exposed face.
    pub fn exposed(self: *const Grid, x: i64, y: i64, z: i64) bool {
        if (self.block(x, y, z) == .air) return false;
        return self.block(x + 1, y, z) == .air or
            self.block(x - 1, y, z) == .air or
            self.block(x, y + 1, z) == .air or
            self.block(x, y - 1, z) == .air or
            self.block(x, y, z + 1) == .air or
            self.block(x, y, z - 1) == .air;
    }
};
