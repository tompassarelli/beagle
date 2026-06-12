//! Render harness — handwritten indefinitely (the emitter never eats
//! this). One instanced-cube pipeline; terrain lives in PER-CHUNK GPU
//! buffers rebuilt only when a chunk is dirty (so render cost scales
//! with digs, not world size), minds stream every frame. Hand-written
//! GLSL 410, GL core backend.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const cfg = @import("config.zig");
const voxel = @import("voxel.zig");
const world_mod = @import("world.zig");

// per-instance: pos(3) + size(1) + color(3) => 7 f32
const INST_FLOATS: usize = 7;
/// Per-chunk instance capacity. Worst-case exposure of a 16x16 column
/// chunk with cliffs and craters stays well under this; overflow is
/// guarded (truncated + logged), purely a visual artifact.
const CHUNK_CAP: usize = 2048;
const N_CHUNKS: usize = voxel.CHUNKS_X * voxel.CHUNKS_Z;

const vs_src =
    \\#version 410
    \\layout(location=0) in vec3 v_pos;
    \\layout(location=1) in vec3 v_nrm;
    \\layout(location=2) in vec4 i_pos_size;
    \\layout(location=3) in vec3 i_color;
    \\uniform mat4 mvp;
    \\out vec3 nrm;
    \\out vec3 color;
    \\void main() {
    \\  vec3 p = v_pos * i_pos_size.w + i_pos_size.xyz;
    \\  gl_Position = mvp * vec4(p, 1.0);
    \\  nrm = v_nrm;
    \\  color = i_color;
    \\}
;

const fs_src =
    \\#version 410
    \\in vec3 nrm;
    \\in vec3 color;
    \\out vec4 frag;
    \\void main() {
    \\  vec3 l = normalize(vec3(0.45, 1.0, 0.25));
    \\  float d = max(dot(normalize(nrm), l), 0.0);
    \\  vec3 c = color * (0.45 + 0.6 * d);
    \\  frag = vec4(c, 1.0);
    \\}
;

// 36 verts: pos3 + normal3
const cube_verts = [_]f32{
    // +z
    -0.5, -0.5, 0.5,  0,  0,  1,  0.5, -0.5, 0.5,  0,  0,  1,  0.5,  0.5, 0.5,  0,  0,  1,
    -0.5, -0.5, 0.5,  0,  0,  1,  0.5, 0.5,  0.5,  0,  0,  1,  -0.5, 0.5, 0.5,  0,  0,  1,
    // -z
    0.5,  -0.5, -0.5, 0,  0,  -1, -0.5, -0.5, -0.5, 0, 0,  -1, -0.5, 0.5, -0.5, 0,  0,  -1,
    0.5,  -0.5, -0.5, 0,  0,  -1, -0.5, 0.5,  -0.5, 0, 0,  -1, 0.5,  0.5, -0.5, 0,  0,  -1,
    // +x
    0.5,  -0.5, 0.5,  1,  0,  0,  0.5, -0.5, -0.5, 1,  0,  0,  0.5,  0.5, -0.5, 1,  0,  0,
    0.5,  -0.5, 0.5,  1,  0,  0,  0.5, 0.5,  -0.5, 1,  0,  0,  0.5,  0.5, 0.5,  1,  0,  0,
    // -x
    -0.5, -0.5, -0.5, -1, 0,  0,  -0.5, -0.5, 0.5, -1, 0,  0,  -0.5, 0.5, 0.5,  -1, 0,  0,
    -0.5, -0.5, -0.5, -1, 0,  0,  -0.5, 0.5,  0.5, -1, 0,  0,  -0.5, 0.5, -0.5, -1, 0,  0,
    // +y
    -0.5, 0.5,  0.5,  0,  1,  0,  0.5, 0.5,  0.5,  0,  1,  0,  0.5,  0.5, -0.5, 0,  1,  0,
    -0.5, 0.5,  0.5,  0,  1,  0,  0.5, 0.5,  -0.5, 0,  1,  0,  -0.5, 0.5, -0.5, 0,  1,  0,
    // -y
    -0.5, -0.5, -0.5, 0,  -1, 0,  0.5, -0.5, -0.5, 0,  -1, 0,  0.5,  -0.5, 0.5, 0,  -1, 0,
    -0.5, -0.5, -0.5, 0,  -1, 0,  0.5, -0.5,  0.5, 0,  -1, 0,  -0.5, -0.5, 0.5, 0,  -1, 0,
};

// --- tiny column-major mat4 ---------------------------------------------------

pub const Mat4 = [16]f32;

fn matMul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |c| {
        for (0..4) |r| {
            var s: f32 = 0;
            for (0..4) |k| s += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = s;
        }
    }
    return out;
}

fn perspective(fov_deg: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fov_deg * std.math.pi / 360.0);
    var m = std.mem.zeroes(Mat4);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = (2 * far * near) / (near - far);
    return m;
}

fn lookAt(eye: [3]f32, center: [3]f32, up: [3]f32) Mat4 {
    const fwd = norm3(.{ center[0] - eye[0], center[1] - eye[1], center[2] - eye[2] });
    const s = norm3(cross(fwd, up));
    const u = cross(s, fwd);
    var m = std.mem.zeroes(Mat4);
    m[0] = s[0];
    m[4] = s[1];
    m[8] = s[2];
    m[1] = u[0];
    m[5] = u[1];
    m[9] = u[2];
    m[2] = -fwd[0];
    m[6] = -fwd[1];
    m[10] = -fwd[2];
    m[12] = -dot3(s, eye);
    m[13] = -dot3(u, eye);
    m[14] = dot3(fwd, eye);
    m[15] = 1;
    return m;
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn norm3(v: [3]f32) [3]f32 {
    const l = @sqrt(dot3(v, v));
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

// --- renderer state -------------------------------------------------------------

pub const Renderer = struct {
    pip: sg.Pipeline = .{},
    cube_buf: sg.Buffer = .{},
    chunk_bufs: []sg.Buffer,
    chunk_counts: []u32,
    chunk_staging: []f32, // CHUNK_CAP * INST_FLOATS
    minds_buf: sg.Buffer = .{},
    minds_staging: []f32,
    angle: f32 = 0,
    overflow_warned: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        var r = Renderer{
            .chunk_bufs = try alloc.alloc(sg.Buffer, N_CHUNKS),
            .chunk_counts = try alloc.alloc(u32, N_CHUNKS),
            .chunk_staging = try alloc.alloc(f32, CHUNK_CAP * INST_FLOATS),
            .minds_staging = try alloc.alloc(f32, world_mod.N_MINDS * INST_FLOATS),
        };
        @memset(r.chunk_counts, 0);

        r.cube_buf = sg.makeBuffer(.{ .data = sg.asRange(&cube_verts) });
        for (r.chunk_bufs) |*b| {
            b.* = sg.makeBuffer(.{
                .usage = .{ .stream_update = true },
                .size = CHUNK_CAP * INST_FLOATS * @sizeOf(f32),
            });
        }
        r.minds_buf = sg.makeBuffer(.{
            .usage = .{ .stream_update = true },
            .size = world_mod.N_MINDS * INST_FLOATS * @sizeOf(f32),
        });

        var shd_desc = sg.ShaderDesc{};
        shd_desc.vertex_func.source = vs_src;
        shd_desc.fragment_func.source = fs_src;
        shd_desc.uniform_blocks[0].stage = .VERTEX;
        shd_desc.uniform_blocks[0].size = @sizeOf(Mat4);
        shd_desc.uniform_blocks[0].layout = .NATIVE;
        shd_desc.uniform_blocks[0].glsl_uniforms[0] = .{
            .type = .MAT4,
            .array_count = 1,
            .glsl_name = "mvp",
        };
        const shd = sg.makeShader(shd_desc);

        var pip_desc = sg.PipelineDesc{
            .shader = shd,
            .index_type = .NONE,
            .cull_mode = .BACK,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
        };
        pip_desc.layout.buffers[0].step_func = .PER_VERTEX;
        pip_desc.layout.buffers[1].step_func = .PER_INSTANCE;
        pip_desc.layout.attrs[0] = .{ .format = .FLOAT3, .buffer_index = 0 };
        pip_desc.layout.attrs[1] = .{ .format = .FLOAT3, .buffer_index = 0 };
        pip_desc.layout.attrs[2] = .{ .format = .FLOAT4, .buffer_index = 1 };
        pip_desc.layout.attrs[3] = .{ .format = .FLOAT3, .buffer_index = 1 };
        r.pip = sg.makePipeline(pip_desc);
        return r;
    }

    fn blockColor(b: voxel.Block, x: i64, z: i64) [3]f32 {
        const j: f32 = @as(f32, @floatFromInt(@mod(x * 7 + z * 13, 9))) * 0.012;
        return switch (b) {
            .grass => .{ 0.28 + j, 0.62 + j, 0.25 },
            .dirt => .{ 0.45 + j, 0.33 + j, 0.22 },
            .rock => .{ 0.42 + j, 0.43 + j, 0.46 },
            .air => .{ 0, 0, 0 },
        };
    }

    fn mindColor(alarm: i64) [3]f32 {
        if (alarm >= 750) return .{ 0.95, 0.15, 0.12 };
        if (alarm >= 500) return .{ 0.95, 0.55, 0.12 };
        if (alarm >= 250) return .{ 0.92, 0.86, 0.20 };
        return .{ 0.25, 0.85, 0.85 };
    }

    /// Rebuild one dirty chunk's instance list and upload it.
    fn rebuildChunk(self: *Renderer, g: *const voxel.Grid, ci: usize) void {
        const ccx = ci % voxel.CHUNKS_X;
        const ccz = ci / voxel.CHUNKS_X;
        var n: usize = 0;
        var lz: usize = 0;
        while (lz < voxel.CHUNK) : (lz += 1) {
            var lx: usize = 0;
            while (lx < voxel.CHUNK) : (lx += 1) {
                const x: i64 = @intCast(ccx * voxel.CHUNK + lx);
                const z: i64 = @intCast(ccz * voxel.CHUNK + lz);
                const h = g.heightAt(x, z);
                var y: i64 = 0;
                while (y < h) : (y += 1) {
                    if (!g.exposed(x, y, z)) continue;
                    if (n >= CHUNK_CAP) {
                        if (!self.overflow_warned) {
                            std.debug.print("render: chunk {d} instance overflow (cap {d})\n", .{ ci, CHUNK_CAP });
                            self.overflow_warned = true;
                        }
                        break;
                    }
                    const o = n * INST_FLOATS;
                    const c = blockColor(g.block(x, y, z), x, z);
                    self.chunk_staging[o + 0] = @floatFromInt(x);
                    self.chunk_staging[o + 1] = @floatFromInt(y);
                    self.chunk_staging[o + 2] = @floatFromInt(z);
                    self.chunk_staging[o + 3] = 1.0;
                    self.chunk_staging[o + 4] = c[0];
                    self.chunk_staging[o + 5] = c[1];
                    self.chunk_staging[o + 6] = c[2];
                    n += 1;
                }
            }
        }
        self.chunk_counts[ci] = @intCast(n);
        if (n > 0) {
            sg.updateBuffer(self.chunk_bufs[ci], .{
                .ptr = self.chunk_staging.ptr,
                .size = n * INST_FLOATS * @sizeOf(f32),
            });
        }
    }

    pub fn frame(self: *Renderer, w: *world_mod.World) void {
        const g = &w.grid;
        // terrain: only dirty chunks pay anything
        for (0..N_CHUNKS) |ci| {
            if (g.dirty[ci]) {
                self.rebuildChunk(g, ci);
                g.dirty[ci] = false;
            }
        }
        // minds: streamed every frame
        const minds = w.read();
        for (0..world_mod.N_MINDS) |i| {
            const o = i * INST_FLOATS;
            const h = g.heightAt(minds.x[i], minds.z[i]);
            const c = mindColor(minds.alarm[i]);
            self.minds_staging[o + 0] = @floatFromInt(minds.x[i]);
            self.minds_staging[o + 1] = @floatFromInt(h);
            self.minds_staging[o + 2] = @floatFromInt(minds.z[i]);
            self.minds_staging[o + 3] = 0.7;
            self.minds_staging[o + 4] = c[0];
            self.minds_staging[o + 5] = c[1];
            self.minds_staging[o + 6] = c[2];
        }
        sg.updateBuffer(self.minds_buf, .{
            .ptr = self.minds_staging.ptr,
            .size = world_mod.N_MINDS * INST_FLOATS * @sizeOf(f32),
        });

        // camera scales with the world
        self.angle += 0.0020;
        const wx: f32 = @floatFromInt(voxel.SIZE_X);
        const cx = wx / 2.0;
        const cz: f32 = @floatFromInt(voxel.SIZE_Z / 2);
        const radius: f32 = wx * 1.15;
        const eye = [3]f32{
            cx + radius * @cos(self.angle),
            wx * 0.8,
            cz + radius * @sin(self.angle),
        };
        const view = lookAt(eye, .{ cx, 8.0, cz }, .{ 0, 1, 0 });
        const proj = perspective(55.0, sapp.widthf() / sapp.heightf(), 0.1, wx * 5.0);
        const mvp = matMul(proj, view);

        var pass = sg.Pass{ .swapchain = sglue.swapchain() };
        pass.action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0.07, .g = 0.08, .b = 0.10, .a = 1 },
        };
        sg.beginPass(pass);
        sg.applyPipeline(self.pip);
        sg.applyUniforms(0, sg.asRange(&mvp));
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = self.cube_buf;
        for (0..N_CHUNKS) |ci| {
            const n = self.chunk_counts[ci];
            if (n == 0) continue;
            bind.vertex_buffers[1] = self.chunk_bufs[ci];
            sg.applyBindings(bind);
            sg.draw(0, 36, n);
        }
        bind.vertex_buffers[1] = self.minds_buf;
        sg.applyBindings(bind);
        sg.draw(0, 36, @intCast(world_mod.N_MINDS));
        sg.endPass();
        sg.commit();
    }
};
