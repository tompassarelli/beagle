//! The kernel-to-be-eaten: every per-mind rule lives here as a pure
//! function — mind in, belief/decision out. Integer math only (i64), so
//! the Babashka differential oracle compares exactly. This file is the
//! Zig emitter's specification: Phase 1 rewrites these functions in
//! Beagle, emits them, and deletes the handwritten versions. Nothing in
//! here may touch the window, the grid store, or any allocator except
//! through Ctx.
//!
//! Mind model (deliberately simple — exercises the architecture, not
//! game design): each mind carries a smoothed threat *belief* and an
//! *alarm* level. Observation = ambient dread (distance to fixed wells)
//! + social contagion (mean alarm of neighbors: minds modeling minds).
//! Alarm escalates while belief is high, decays otherwise. Decisions:
//! idle/wander when calm, avoid when wary, flee when alarmed, and at
//! panic — burrow: dig the voxel underfoot and take cover (relief).

const std = @import("std");
const det = @import("determinism.zig");

pub const Ctx = struct {
    tick: std.mem.Allocator, // arena; reset per tick by the harness, never here
    rng: *det.Splitmix64, // deterministic; drawn in fixed mind order
};

/// Read-only view of one mind from world_read.
pub const MindIn = extern struct {
    x: i64,
    z: i64,
    belief: i64,
    alarm: i64,
};

/// What a mind perceives this tick (computed by the harness pass).
pub const Obs = extern struct {
    well_threat: i64, // ambient dread at this position, 0..1000
    social: i64, // mean alarm of neighbors within radius, 0..1000
    well_dx: i64, // unit-ish step AWAY from the strongest well
    well_dz: i64,
};

/// Next belief + alarm (world-lifetime values; promoted at commit).
pub const BeliefOut = extern struct {
    belief: i64,
    alarm: i64,
};

pub const Act = enum(i64) {
    idle = 0,
    wander = 1,
    avoid = 2,
    flee = 3,
    dig = 4,
};

pub const Decision = extern struct {
    act: i64, // Act
    dx: i64,
    dz: i64,
};

// Tuning constants — mirrored in the Beagle source in Phase 1.
pub const ALARM_MAX: i64 = 1000;
pub const RISE_THRESHOLD: i64 = 220;
pub const DECAY: i64 = 9;
pub const WARY_AT: i64 = 250;
pub const ALARMED_AT: i64 = 500;
pub const PANIC_AT: i64 = 750;
pub const DIG_RELIEF: i64 = 320;

/// Belief pass: exponential moving average toward the observed threat
/// (integer EMA, shift-based), then the alarm escalation state machine.
pub fn beliefUpdate(ctx: *Ctx, m: MindIn, obs: Obs) BeliefOut {
    _ = ctx;
    const observed = obs.well_threat + (obs.social >> 2);
    const belief = m.belief + ((observed - m.belief) >> 3);
    var alarm = m.alarm;
    if (belief > RISE_THRESHOLD) {
        alarm = alarm + (belief >> 4);
    } else {
        alarm = alarm - DECAY;
    }
    if (alarm > ALARM_MAX) alarm = ALARM_MAX;
    if (alarm < 0) alarm = 0;
    return .{ .belief = belief, .alarm = alarm };
}

/// Decision pass: alarm level picks the behavior; rng only for wander.
pub fn decide(ctx: *Ctx, m: MindIn, b: BeliefOut, obs: Obs) Decision {
    _ = m;
    if (b.alarm >= PANIC_AT) {
        return .{ .act = @intFromEnum(Act.dig), .dx = 0, .dz = 0 };
    }
    if (b.alarm >= ALARMED_AT) {
        return .{ .act = @intFromEnum(Act.flee), .dx = obs.well_dx * 2, .dz = obs.well_dz * 2 };
    }
    if (b.alarm >= WARY_AT) {
        return .{ .act = @intFromEnum(Act.avoid), .dx = obs.well_dx, .dz = obs.well_dz };
    }
    const roll: i64 = @intCast(ctx.rng.below(8));
    if (roll < 3) {
        const dx: i64 = @as(i64, @intCast(ctx.rng.below(3))) - 1;
        const dz: i64 = @as(i64, @intCast(ctx.rng.below(3))) - 1;
        return .{ .act = @intFromEnum(Act.wander), .dx = dx, .dz = dz };
    }
    return .{ .act = @intFromEnum(Act.idle), .dx = 0, .dz = 0 };
}

/// Post-dig relief (pure): digging vents alarm.
pub fn digRelief(alarm: i64) i64 {
    const a = alarm - DIG_RELIEF;
    return if (a < 0) 0 else a;
}
