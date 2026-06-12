const std = @import("std");

// Tick kernel — Phase 0 reference implementation (thread 20260612232001).
// `zig build run` opens the sokol window; `zig build run -- --headless N`
// runs N ticks windowless and prints the conformance hash.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "kernel",
        // zig-master's self-hosted ELF linker currently trips on the
        // libGL.so reference archived via sokol's static clib
        // (R_X86_64_JUMP_SLOT). Use the LLVM+LLD pipeline.
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs(); // `zig build run -- --headless N`
    const run_step = b.step("run", "Run the kernel");
    run_step.dependOn(&run_cmd.step);
}
