pub const packages = struct {
    pub const @"N-V-__8AAFzfCQCASN6D5b3L8-QbCR9pCMDgNoKp69omdc4V" = struct {
        pub const build_root = "/home/tom/code/beagle/kernel/zig-pkg/N-V-__8AAFzfCQCASN6D5b3L8-QbCR9pCMDgNoKp69omdc4V";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"sokol-0.1.0-pb1HK4RrNwA1QTln_ZtLaEBne8Dn6zgZH4UVA45cGdnM" = struct {
        pub const build_root = "/home/tom/code/beagle/kernel/zig-pkg/sokol-0.1.0-pb1HK4RrNwA1QTln_ZtLaEBne8Dn6zgZH4UVA45cGdnM";
        pub const build_zig = @import("sokol-0.1.0-pb1HK4RrNwA1QTln_ZtLaEBne8Dn6zgZH4UVA45cGdnM");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "emsdk", "N-V-__8AAFzfCQCASN6D5b3L8-QbCR9pCMDgNoKp69omdc4V" },
            .{ "shdc", "sokolshdc-0.1.0-r2KZDj2ESgPeSsOrxWqONyemz4-250cFO8ZhXkEs4DrZ" },
        };
    };
    pub const @"sokolshdc-0.1.0-r2KZDj2ESgPeSsOrxWqONyemz4-250cFO8ZhXkEs4DrZ" = struct {
        pub const build_root = "/home/tom/code/beagle/kernel/zig-pkg/sokolshdc-0.1.0-r2KZDj2ESgPeSsOrxWqONyemz4-250cFO8ZhXkEs4DrZ";
        pub const build_zig = @import("sokolshdc-0.1.0-r2KZDj2ESgPeSsOrxWqONyemz4-250cFO8ZhXkEs4DrZ");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "sokol", "sokol-0.1.0-pb1HK4RrNwA1QTln_ZtLaEBne8Dn6zgZH4UVA45cGdnM" },
};
