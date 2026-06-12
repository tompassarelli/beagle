//! Render harness — handwritten indefinitely (the emitter never eats
//! this). One instanced-cube pipeline drives everything: terrain voxels
//! and minds are the same draw call. Hand-written GLSL 410 (GL core
//! backend only for now; sokol-shdc cross-compilation comes when a
//! second platform does).

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const voxel = @import("voxel.zig");
const world_mod = @import("world.zig");

pub const MAX_INSTANCES: usize = 48 * 1024;

// per-instance: pos(3) + size(1) + color(3) => 7 f32
const INST_FLOATS: usize = 7;

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
    bind: sg.Bindings = .{},
    inst_buf: sg.Buffer = .{},
    instances: []f32, // CPU staging, MAX_INSTANCES * INST_FLOATS
    n_instances: usize = 0,
    angle: f32 = 0,

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        var r = Renderer{ .instances = try alloc.alloc(f32, MAX_INSTANCES * INST_FLOATS) };

        const vbuf = sg.makeBuffer(.{
            .data = sg.asRange(&cube_verts),
        });
        r.inst_buf = sg.makeBuffer(.{
            .usage = .{ .stream_update = true },
            .size = MAX_INSTANCES * INST_FLOATS * @sizeOf(f32),
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

        r.bind.vertex_buffers[0] = vbuf;
        r.bind.vertex_buffers[1] = r.inst_buf;
        return r;
    }

    fn push(self: *Renderer, x: f32, y: f32, z: f32, size: f32, c: [3]f32) void {
        if (self.n_instances >= MAX_INSTANCES) return;
        const o = self.n_instances * INST_FLOATS;
        self.instances[o + 0] = x;
        self.instances[o + 1] = y;
        self.instances[o + 2] = z;
        self.instances[o + 3] = size;
        self.instances[o + 4] = c[0];
        self.instances[o + 5] = c[1];
        self.instances[o + 6] = c[2];
        self.n_instances += 1;
    }

    fn blockColor(b: voxel.Block, x: i64, z: i64) [3]f32 {
        // tiny deterministic per-column jitter so terrain isn't flat-shaded
        const j: f32 = @as(f32, @floatFromInt(@mod(x * 7 + z * 13, 9))) * 0.012;
        return switch (b) {
            .grass => .{ 0.28 + j, 0.62 + j, 0.25 },
            .dirt => .{ 0.45 + j, 0.33 + j, 0.22 },
            .rock => .{ 0.42 + j, 0.43 + j, 0.46 },
            .air => .{ 0, 0, 0 },
        };
    }

    fn mindColor(alarm: i64) [3]f32 {
        if (alarm >= 750) return .{ 0.95, 0.15, 0.12 }; // panic
        if (alarm >= 500) return .{ 0.95, 0.55, 0.12 }; // alarmed
        if (alarm >= 250) return .{ 0.92, 0.86, 0.20 }; // wary
        return .{ 0.25, 0.85, 0.85 }; // calm
    }

    /// Rebuild the full instance list (terrain exposure + minds) and draw.
    pub fn frame(self: *Renderer, w: *const world_mod.World) void {
        self.n_instances = 0;
        const g = &w.grid;
        var z: i64 = 0;
        while (z < voxel.SIZE_Z) : (z += 1) {
            var x: i64 = 0;
            while (x < voxel.SIZE_X) : (x += 1) {
                var y: i64 = 0;
                const h = g.heightAt(x, z);
                while (y < h) : (y += 1) {
                    if (g.exposed(x, y, z)) {
                        self.push(
                            @floatFromInt(x),
                            @floatFromInt(y),
                            @floatFromInt(z),
                            1.0,
                            blockColor(g.block(x, y, z), x, z),
                        );
                    }
                }
            }
        }
        const minds = w.read();
        for (0..world_mod.N_MINDS) |i| {
            const h = g.heightAt(minds.x[i], minds.z[i]);
            self.push(
                @floatFromInt(minds.x[i]),
                @floatFromInt(h),
                @floatFromInt(minds.z[i]),
                0.7,
                mindColor(minds.alarm[i]),
            );
        }

        sg.updateBuffer(self.inst_buf, .{
            .ptr = self.instances.ptr,
            .size = self.n_instances * INST_FLOATS * @sizeOf(f32),
        });

        // slow auto-orbit around world center
        self.angle += 0.0035;
        const cx: f32 = @floatFromInt(voxel.SIZE_X / 2);
        const cz: f32 = @floatFromInt(voxel.SIZE_Z / 2);
        const radius: f32 = 72.0;
        const eye = [3]f32{
            cx + radius * @cos(self.angle),
            52.0,
            cz + radius * @sin(self.angle),
        };
        const view = lookAt(eye, .{ cx, 8.0, cz }, .{ 0, 1, 0 });
        const proj = perspective(55.0, sapp.widthf() / sapp.heightf(), 0.1, 400.0);
        const mvp = matMul(proj, view);

        var pass = sg.Pass{ .swapchain = sglue.swapchain() };
        pass.action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0.07, .g = 0.08, .b = 0.10, .a = 1 },
        };
        sg.beginPass(pass);
        sg.applyPipeline(self.pip);
        sg.applyBindings(self.bind);
        sg.applyUniforms(0, sg.asRange(&mvp));
        sg.draw(0, 36, @intCast(self.n_instances));
        sg.endPass();
        sg.commit();
    }
};
