//! Build-time configuration. Two profiles:
//!   default      — small world, conformance/dev profile
//!   -Dscale=big  — the ambition profile (512x512, 200k minds)
//! Selected via build options; everything else derives.

const build_options = @import("build_options");

pub const big = build_options.big;

pub const SIZE_X: usize = if (big) 512 else 64;
pub const SIZE_Z: usize = if (big) 512 else 64;
pub const SIZE_Y: usize = 24;
pub const CHUNK: usize = 16;

pub const N_MINDS: usize = if (big) 200_000 else 300;
pub const N_WELLS: usize = if (big) 256 else 4;
pub const WELL_RADIUS: i64 = 18;

/// Social contagion v2: cell-aggregate observation. Minds read the 3x3
/// neighborhood of cells of this size (replaces the exact-radius O(N^2)
/// pair scan — a deliberate, documented semantics change).
pub const SOCIAL_CELL: usize = 6;

/// Tick arena capacity (brief §2.3: sized generously; exhaustion is a
/// config bug). steps + edits + temporaries.
pub const ARENA_BYTES: usize = if (big) 64 * 1024 * 1024 else 4 * 1024 * 1024;

pub const N_THREADS: usize = if (big) 8 else 1;
