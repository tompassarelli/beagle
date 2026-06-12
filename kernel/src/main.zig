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
    var seed: u64 = DEFAULT_SEED;
    var it = std.process.Args.Iterator.init(init_.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) {
            const v = it.next() orelse return error.MissingTickCount;
            headless = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const v = it.next() orelse return error.MissingSeed;
            seed = try std.fmt.parseInt(u64, v, 0);
        }
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
