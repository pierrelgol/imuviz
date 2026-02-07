const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const History = @import("history.zig").History;
const drawTextFmt = @import("utils.zig").drawTextFmt;

pub const SceneTarget = struct {
    rt: ?rl.RenderTexture2D = null,
    width: i32 = 0,
    height: i32 = 0,
    warned_invalid_rt: bool = false,

    pub fn ensure(self: *SceneTarget, width: i32, height: i32) void {
        if (width < cfg.renderer.min_scene_dim_px or height < cfg.renderer.min_scene_dim_px) return;
        if (self.rt != null and self.width == width and self.height == height) return;

        if (self.rt) |texture| {
            rl.unloadRenderTexture(texture);
            self.rt = null;
        }

        const loaded = rl.loadRenderTexture(width, height) catch |err| {
            std.log.err("client: failed to allocate render texture {}x{}: {}", .{ width, height, err });
            self.rt = null;
            self.width = width;
            self.height = height;
            return;
        };
        self.rt = loaded;

        if (self.rt) |rt| {
            if (!rl.isRenderTextureValid(rt)) {
                if (!self.warned_invalid_rt) {
                    self.warned_invalid_rt = true;
                    std.log.err("client: invalid render texture {}x{} (id={})", .{ width, height, rt.id });
                }
                rl.unloadRenderTexture(rt);
                self.rt = null;
            } else if (self.warned_invalid_rt) {
                self.warned_invalid_rt = false;
                std.log.info("client: render texture valid again {}x{} (id={})", .{ width, height, rt.id });
            }
        }

        self.width = width;
        self.height = height;
    }

    pub fn deinit(self: *SceneTarget) void {
        if (self.rt) |texture| rl.unloadRenderTexture(texture);
        self.* = .{};
    }
};

pub fn draw(target: *SceneTarget, rect: rl.Rectangle, history: *const History) void {
    if (!isDrawableRect(rect)) return;

    const width: i32 = @intFromFloat(@max(rect.width, 1));
    const height: i32 = @intFromFloat(@max(rect.height, 1));
    target.ensure(width, height);

    const rt = target.rt orelse {
        drawUnavailable(rect);
        return;
    };

    rl.beginTextureMode(rt);
    rl.clearBackground(cfg.renderer.scene_bg);

    const camera = rl.Camera3D{
        .position = cfg.scene3d.camera_pos,
        .target = cfg.scene3d.camera_target,
        .up = cfg.scene3d.camera_up,
        .fovy = cfg.scene3d.camera_fovy,
        .projection = .perspective,
    };

    rl.beginMode3D(camera);
    rl.drawGrid(cfg.scene3d.grid_slices, cfg.scene3d.grid_spacing);
    rl.drawSphere(cfg.scene3d.sphere_center, cfg.scene3d.sphere_radius, cfg.renderer.scene_sphere_fill);
    rl.drawSphereWires(cfg.scene3d.sphere_center, cfg.scene3d.sphere_radius, 16, 16, cfg.renderer.scene_sphere_wire);

    const orientation = latestOrientation(history);
    drawReferenceAxes();
    drawImuDirectionArrow(orientation.elevation, orientation.bearing);
    rl.endMode3D();
    rl.endTextureMode();

    const src = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(rt.texture.width),
        .height = -@as(f32, @floatFromInt(rt.texture.height)),
    };
    rl.drawTexturePro(rt.texture, src, rect, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    rl.drawRectangleLinesEx(rect, cfg.renderer.panel_border_thickness, cfg.theme.border);
}

fn drawUnavailable(rect: rl.Rectangle) void {
    rl.drawRectangleRec(rect, cfg.renderer.scene_unavailable_fill);
    rl.drawRectangleLinesEx(rect, cfg.renderer.panel_border_thickness, cfg.renderer.scene_unavailable_border);
    drawTextFmt(
        "3D unavailable (invalid render target)",
        .{},
        @intFromFloat(rect.x + cfg.renderer.invalid_rt_text_x_offset),
        @intFromFloat(rect.y + cfg.renderer.invalid_rt_text_y_offset),
        cfg.renderer.invalid_rt_text_size,
        cfg.renderer.scene_unavailable_text,
    );
}

fn latestOrientation(history: *const History) struct { elevation: f32, bearing: f32 } {
    const sample = history.latestSample() orelse return .{ .elevation = 0, .bearing = 0 };
    return .{ .elevation = sample.elevation, .bearing = sample.bearing };
}

fn drawReferenceAxes() void {
    const s = cfg.scene3d.reference_axis_length / cfg.scene3d.axis_head_end;
    const origin = referenceOriginNearCamera();
    drawArrow(origin, .{ .x = 1, .y = 0, .z = 0 }, cfg.renderer.scene_ref_x, s);
    drawArrow(origin, .{ .x = 0, .y = 1, .z = 0 }, cfg.renderer.scene_ref_y, s);
    drawArrow(origin, .{ .x = 0, .y = 0, .z = 1 }, cfg.renderer.scene_ref_z, s);
}

fn referenceOriginNearCamera() rl.Vector3 {
    const half_extent = (@as(f32, @floatFromInt(cfg.scene3d.grid_slices)) * cfg.scene3d.grid_spacing) * 0.5;
    return .{
        .x = -half_extent + cfg.scene3d.reference_inset,
        .y = cfg.scene3d.reference_height,
        .z = -half_extent + cfg.scene3d.reference_inset,
    };
}

fn drawImuDirectionArrow(elevation_deg: f32, bearing_deg: f32) void {
    const dir = normalizeSafe(rotateAxis(.{ .x = 1, .y = 0, .z = 0 }, elevation_deg, bearing_deg), .{ .x = 1, .y = 0, .z = 0 });
    drawArrow(cfg.scene3d.origin, dir, cfg.renderer.scene_imu_arrow, 1.0);
}

fn drawArrow(origin: rl.Vector3, dir: rl.Vector3, color: rl.Color, scale: f32) void {
    const shaft_start = origin.add(dir.scale(cfg.scene3d.axis_shaft_start * scale));
    const shaft_end = origin.add(dir.scale(cfg.scene3d.axis_shaft_end * scale));
    rl.drawCylinderEx(
        shaft_start,
        shaft_end,
        cfg.scene3d.axis_shaft_radius * scale,
        cfg.scene3d.axis_shaft_radius * scale,
        cfg.scene3d.axis_sides,
        color,
    );

    const head_start = origin.add(dir.scale(cfg.scene3d.axis_head_start * scale));
    const head_end = origin.add(dir.scale(cfg.scene3d.axis_head_end * scale));
    rl.drawCylinderEx(head_start, head_end, cfg.scene3d.axis_head_radius * scale, 0.0, cfg.scene3d.axis_sides, color);
}

fn rotateAxis(axis: rl.Vector3, elevation_deg: f32, bearing_deg: f32) rl.Vector3 {
    const deg_to_rad = std.math.pi / 180.0;
    const elev = elevation_deg * deg_to_rad;
    const bear = bearing_deg * deg_to_rad;

    var v = rl.Vector3{ .x = -axis.x, .y = axis.y, .z = -axis.z };

    const cos_b = @cos(bear);
    const sin_b = @sin(bear);
    v = .{
        .x = cos_b * v.x - sin_b * v.y,
        .y = sin_b * v.x + cos_b * v.y,
        .z = v.z,
    };

    const cos_e = @cos(elev);
    const sin_e = @sin(elev);
    v = .{
        .x = cos_e * v.x + sin_e * v.z,
        .y = v.y,
        .z = -sin_e * v.x + cos_e * v.z,
    };

    return v;
}

fn vecDot(a: rl.Vector3, b: rl.Vector3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn normalizeSafe(v: rl.Vector3, fallback: rl.Vector3) rl.Vector3 {
    const len_sq = vecDot(v, v);
    if (len_sq <= 1e-8) return fallback;
    const inv_len = 1.0 / @sqrt(len_sq);
    return .{ .x = v.x * inv_len, .y = v.y * inv_len, .z = v.z * inv_len };
}

fn isDrawableRect(rect: rl.Rectangle) bool {
    return rect.width >= 1.0 and rect.height >= 1.0;
}
