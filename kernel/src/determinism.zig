//! Deterministic primitives: Splitmix64 PRNG and the FNV-1a conformance
//! hash. No wall clock, no host RNG, anywhere. The same Splitmix64 will
//! be implemented in the Babashka prelude (unchecked 64-bit ops) so the
//! differential oracle draws identical streams.

pub const Splitmix64 = struct {
    state: u64,

    pub fn init(seed: u64) Splitmix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *Splitmix64) u64 {
        self.state = self.state +% 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform in [0, n) — n must be > 0. Simple modulo (bias is
    /// irrelevant here; determinism is what matters).
    pub fn below(self: *Splitmix64, n: u64) u64 {
        return self.next() % n;
    }
};

/// FNV-1a, 64-bit. The conformance fingerprint: every decision and every
/// voxel edit of every tick folds through this. Identical streams of
/// folds => identical hash, on every backend.
pub const Fnv1a = struct {
    h: u64 = 0xCBF29CE484222325,

    pub fn foldU64(self: *Fnv1a, v: u64) void {
        var x = v;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            self.h = (self.h ^ (x & 0xFF)) *% 0x100000001B3;
            x >>= 8;
        }
    }

    pub fn foldI64(self: *Fnv1a, v: i64) void {
        self.foldU64(@bitCast(v));
    }
};
