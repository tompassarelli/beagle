//! Entry point. `--headless N` runs N ticks windowless and prints the
//! conformance hash (the fingerprint every later backend must match).
//! Otherwise: sokol window, fixed-step simulation, instanced-cube view.

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const world_mod = @import("world.zig");
const render_mod = @import("render.zig");

pub const DEFAULT_SEED: u64 = 0xBEA61E;

/// Differential-oracle mode: generate the same case stream as
/// bb/run_cases.clj (shared Splitmix64) and print one line per case.
fn runDif(n: u64, seed: u64) !void {
    const sim = @import("sim.zig");
    const det = @import("determinism.zig");
    var gen = det.Splitmix64.init(seed);
    var crng = det.Splitmix64.init(seed + 1);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var ctx = sim.Ctx{ .tick = arena_state.allocator(), .rng = &crng };
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const m = sim.MindIn{
            .x = @intCast(gen.below(64)),
            .z = @intCast(gen.below(64)),
            .belief = @intCast(gen.below(1200)),
            .alarm = @intCast(gen.below(1100)),
        };
        const obs = sim.Obs{
            .well_threat = @intCast(gen.below(1001)),
            .social = @intCast(gen.below(1001)),
            .well_dx = @as(i64, @intCast(gen.below(3))) - 1,
            .well_dz = @as(i64, @intCast(gen.below(3))) - 1,
            .wolf_near = @intCast(gen.below(1001)),
            .wolf_dx = @as(i64, @intCast(gen.below(3))) - 1,
            .wolf_dz = @as(i64, @intCast(gen.below(3))) - 1,
            .wolf_here = @intCast(gen.below(2)),
        };
        const out = sim.tickStep(&ctx, m, obs, 64, 64);
        std.debug.print("{d} {d} {d} {d} {d} {d} {d}\n", .{ out.x, out.z, out.belief, out.alarm, out.act, @intFromBool(out.alive), @intFromBool(out.spawn) });
    }
    // wolf-step cases continue the same generator stream (second system,
    // second block of n lines — the oracle compares the whole stream)
    i = 0;
    while (i < n) : (i += 1) {
        const w = sim.WolfIn{
            .x = @intCast(gen.below(64)),
            .z = @intCast(gen.below(64)),
            .energy = @intCast(gen.below(1001)),
            .fed = @intCast(gen.below(200)),
        };
        const wobs = sim.WolfObs{
            .scent = @intCast(gen.below(5001)),
            .prey_dx = @as(i64, @intCast(gen.below(3))) - 1,
            .prey_dz = @as(i64, @intCast(gen.below(3))) - 1,
            .prey_near = @intCast(gen.below(4)),
        };
        const wout = sim.wolfStep(&ctx, w, wobs, 64, 64);
        std.debug.print("{d} {d} {d} {d} {d} {d} {d}\n", .{ wout.x, wout.z, wout.energy, wout.fed, wout.howl, @intFromBool(wout.alive), @intFromBool(wout.spawn) });
    }
}

// --- windowed state (sokol callbacks are global) ------------------------------

const App = struct {
    gpa: std.heap.DebugAllocator(.{}) = .init,
    world: world_mod.World = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    renderer: render_mod.Renderer = undefined,
    seed: u64 = DEFAULT_SEED,
    ticks_per_frame: u64 = 1,
};
var app: App = .{};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    const alloc = app.gpa.allocator();
    app.world = world_mod.World.init(alloc, app.seed) catch @panic("world init");
    app.arena = std.heap.ArenaAllocator.init(alloc);
    app.renderer = render_mod.Renderer.init(alloc) catch @panic("renderer init");
}

export fn frame() void {
    var t: u64 = 0;
    while (t < app.ticks_per_frame) : (t += 1) {
        app.world.tick(app.arena.allocator()) catch @panic("tick");
        if (builtin.mode == .Debug) {
            _ = app.arena.reset(.free_all);
        } else {
            _ = app.arena.reset(.retain_capacity);
        }
    }
    app.renderer.frame(&app.world);
}

export fn cleanup() void {
    sg.shutdown();
    app.arena.deinit();
    app.world.deinit();
    _ = app.gpa.deinit();
}

// zig-master main convention: the runtime hands us args/environ
// explicitly (std.process.Init.Minimal) — no global argv.
pub fn main(init_: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var headless: ?u64 = null;
    var dif: ?u64 = null;
    var seed: u64 = DEFAULT_SEED;
    var it = std.process.Args.Iterator.init(init_.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) {
            const v = it.next() orelse return error.MissingTickCount;
            headless = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--dif")) {
            const v = it.next() orelse return error.MissingCaseCount;
            dif = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const v = it.next() orelse return error.MissingSeed;
            seed = try std.fmt.parseInt(u64, v, 0);
        }
    }

    if (dif) |n| {
        try runDif(n, seed);
        return;
    }

    if (headless) |n| {
        const hash = try world_mod.runHeadless(alloc, seed, n);
        std.debug.print("ticks={d} seed=0x{X} hash=0x{X:0>16}\n", .{ n, seed, hash });
        return;
    }

    app.seed = seed;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 1280,
        .height = 800,
        .sample_count = 4,
        .window_title = "minds — tick kernel",
        .logger = .{ .func = slog.func },
    });
}
