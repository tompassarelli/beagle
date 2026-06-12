//! Deterministic primitives. No wall clock, no host RNG, anywhere.
//!
//! Splitmix64 lives in the prelude (beagle_rt.zig) — ONE canonical
//! implementation shared nominally by harness and emitted code through
//! rt.Ctx; the Babashka prelude mirrors it with unchecked 64-bit ops so
//! the differential oracle draws identical streams.

pub const Splitmix64 = @import("beagle_rt.zig").Splitmix64;

/// Splitmix64 finalizer as a pure mixing function — the basis of the
/// counter-based per-(seed,tick,mind) rng (order-independent, so the
/// mind pass parallelizes without losing bit-determinism).
pub fn mix64(v: u64) u64 {
    var z = v +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// FNV-1a, 64-bit. The conformance fingerprint: every decision and every
/// voxel edit of every tick folds through this. Identical streams of
/// folds => identical hash, on every backend.
pub const Fnv1a = struct {
    h: u64 = 0xCBF29CE484222325,

    pub fn foldU64(self: *Fnv1a, v: u64) void {
        // u64-granular FNV-1a variant (one mix per word, not per byte):
        // at 200k minds x 4 folds/tick the byte loop was measurable.
        // Part of the semantics-v2 baseline change.
        self.h = (self.h ^ v) *% 0x100000001B3;
    }

    pub fn foldI64(self: *Fnv1a, v: i64) void {
        self.foldU64(@bitCast(v));
    }
};
