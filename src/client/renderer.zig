const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const ui = @import("ui.zig");
const net = @import("network.zig");
const plotting = @import("plotting.zig");
const History = @import("history.zig").History;
const drawTextFmt = @import("utils.zig").drawTextFmt;

pub const DeviceFrame = struct {
    title: []const u8,
    history: *const History,
    snapshot: net.EndpointSnapshot,
};

const SceneTarget = struct {
    rt: ?rl.RenderTexture2D = null,
    width: i32 = 0,
    height: i32 = 0,
    warned_invalid_rt: bool = false,

    fn ensure(self: *SceneTarget, width: i32, height: i32) void {
        if (width <= 8 or height <= 8) return;
        if (self.rt != null and self.width == width and self.height == height) return;

        if (self.rt) |texture| {
            rl.unloadRenderTexture(texture);
            self.rt = null;
        }

        self.rt = rl.loadRenderTexture(width, height) catch null;
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

    fn deinit(self: *SceneTarget) void {
        if (self.rt) |texture| rl.unloadRenderTexture(texture);
        self.* = .{};
    }
};

pub const Renderer = struct {
    scenes: [cfg.max_hosts]SceneTarget = [_]SceneTarget{.{}} ** cfg.max_hosts,

    pub fn deinit(self: *Renderer) void {
        for (&self.scenes) |*scene| {
            scene.deinit();
        }
    }

    pub fn draw(self: *Renderer, devices: []const DeviceFrame) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();

        const layout = ui.computeRootLayout(screen_w, screen_h);
        rl.clearBackground(cfg.theme.background);

        rl.drawRectangleRec(layout.title, cfg.theme.title_panel);
        rl.drawRectangleLinesEx(layout.title, 1, rl.Color{ .r = 56, .g = 66, .b = 84, .a = 255 });
        drawTextFmt("IMU Visualizer - {d} device(s)", .{devices.len}, @intFromFloat(layout.title.x + 8), @intFromFloat(layout.title.y + 6), 18, cfg.theme.text_primary);

        for (devices, 0..) |device, idx| {
            const panel = ui.panelRect(layout.body, devices.len, idx, layout.scale.gap);
            drawDevicePanel(&self.scenes[idx], panel, layout.scale, device);
        }
    }
};

fn drawDevicePanel(scene_target: *SceneTarget, panel: rl.Rectangle, scale: ui.UiScale, device: DeviceFrame) void {
    rl.drawRectangleRec(panel, cfg.theme.frame_panel);
    rl.drawRectangleLinesEx(panel, 1, rl.Color{ .r = 52, .g = 61, .b = 78, .a = 255 });

    const header_y = panel.y + scale.panel_padding * 0.8;
    drawTextFmt("{s}", .{device.title}, @intFromFloat(panel.x + scale.panel_padding), @intFromFloat(header_y), 18, cfg.theme.text_primary);

    const status_text = switch (device.snapshot.state) {
        .connected => "Connected",
        .connecting => "Connecting",
        .disconnected => "Disconnected",
    };
    const status_color = switch (device.snapshot.state) {
        .connected => rl.Color{ .r = 80, .g = 214, .b = 124, .a = 255 },
        .connecting => rl.Color{ .r = 247, .g = 196, .b = 80, .a = 255 },
        .disconnected => rl.Color{ .r = 235, .g = 94, .b = 94, .a = 255 },
    };

    drawTextFmt(
        "Status: {s} | Parse: {} | ConnFail: {} | Disc: {} | Reconn: {}",
        .{ status_text, device.snapshot.parse_errors, device.snapshot.connect_failures, device.snapshot.disconnects, device.snapshot.reconnects },
        @intFromFloat(panel.x + 180),
        @intFromFloat(header_y + 2),
        14,
        status_color,
    );

    const content = ui.splitDevicePanel(panel, scale);
    drawScenePanel(scene_target, content.scene, device.history);

    const t_accel_x = [_]plotting.TraceDef{.{ .kind = .accel_x, .name = "accel_x", .color = rl.Color.red }};
    const t_accel_y = [_]plotting.TraceDef{.{ .kind = .accel_y, .name = "accel_y", .color = rl.Color.green }};
    const t_accel_z = [_]plotting.TraceDef{.{ .kind = .accel_z, .name = "accel_z", .color = rl.Color.blue }};
    const t_gyro_norm = [_]plotting.TraceDef{.{ .kind = .gyro_norm, .name = "gyro_norm", .color = rl.Color{ .r = 230, .g = 126, .b = 247, .a = 255 } }};
    const t_elevation = [_]plotting.TraceDef{.{ .kind = .elevation, .name = "elevation", .color = rl.Color.orange }};
    const t_bearing = [_]plotting.TraceDef{.{ .kind = .bearing, .name = "bearing", .color = rl.Color.sky_blue }};

    const accel_domain: plotting.YDomain = .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } };
    drawSignalPlot(content.charts[0], device.history, "accel_x", "accel", &t_accel_x, accel_domain);
    drawSignalPlot(content.charts[1], device.history, "accel_y", "accel", &t_accel_y, accel_domain);
    drawSignalPlot(content.charts[2], device.history, "accel_z", "accel", &t_accel_z, accel_domain);
    drawSignalPlot(content.charts[3], device.history, "gyro_norm", "gyro", &t_gyro_norm, .{ .fixed = .{
        .min = cfg.plot.gyro_norm_min,
        .max = cfg.plot.gyro_norm_max,
    } });
    drawSignalPlot(content.charts[4], device.history, "elevation", "degrees", &t_elevation, .{ .fixed = .{
        .min = cfg.plot.elevation_min_deg,
        .max = cfg.plot.elevation_max_deg,
    } });
    drawSignalPlot(content.charts[5], device.history, "bearing", "degrees", &t_bearing, .{ .fixed = .{
        .min = cfg.plot.orientation_min_deg,
        .max = cfg.plot.orientation_max_deg,
    } });

    drawCurrentValues(panel, device.history);
}

fn drawSignalPlot(
    rect: rl.Rectangle,
    history: *const History,
    title: []const u8,
    y_label: []const u8,
    traces: []const plotting.TraceDef,
    y_domain: plotting.YDomain,
) void {
    plotting.drawPlot(
        rect,
        history,
        .{
            .title = title,
            .traces = traces,
            .x_window_seconds = cfg.history_window_seconds,
            .x_axis = .{ .label = "time (s)", .graduation_count = cfg.plot.raw_x_graduations, .label_format = .fixed1 },
            .y_axis = .{ .label = y_label, .graduation_count = cfg.plot.raw_y_graduations, .label_format = .fixed1 },
            .x_labels_relative_to_latest = true,
            .y_domain = y_domain,
        },
        .{},
    );
}

fn drawCurrentValues(panel: rl.Rectangle, history: *const History) void {
    if (history.len == 0) return;

    const i = history.index(history.len - 1);
    const y = panel.y + panel.height - 24;
    drawTextFmt(
        "A:[{d:.0},{d:.0},{d:.0}] Gnorm:{d:.1} E:{d:.1} B:{d:.1}",
        .{ history.accel_x[i], history.accel_y[i], history.accel_z[i], history.gyro_norm[i], history.elevation[i], history.bearing[i] },
        @intFromFloat(panel.x + 12),
        @intFromFloat(y),
        14,
        cfg.theme.text_secondary,
    );
}

fn drawScenePanel(target: *SceneTarget, rect: rl.Rectangle, history: *const History) void {
    const width: i32 = @intFromFloat(@max(rect.width, 1));
    const height: i32 = @intFromFloat(@max(rect.height, 1));

    target.ensure(width, height);
    if (target.rt == null) {
        rl.drawRectangleRec(rect, rl.Color{ .r = 24, .g = 10, .b = 10, .a = 255 });
        rl.drawRectangleLinesEx(rect, 1, rl.Color{ .r = 170, .g = 70, .b = 70, .a = 255 });
        drawTextFmt("3D unavailable (invalid render target)", .{}, @intFromFloat(rect.x + 8), @intFromFloat(rect.y + 8), 12, rl.Color{ .r = 230, .g = 190, .b = 190, .a = 255 });
        return;
    }

    const rt = target.rt.?;
    rl.beginTextureMode(rt);
    rl.clearBackground(rl.Color{ .r = 18, .g = 20, .b = 24, .a = 255 });

    const camera = rl.Camera3D{
        .position = .{ .x = 2.9, .y = 2.35, .z = 2.9 },
        .target = .{ .x = 0, .y = 0.55, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 45,
        .projection = .perspective,
    };

    rl.beginMode3D(camera);
    const sphere_center = rl.Vector3{ .x = 0, .y = 0.55, .z = 0 };
    const sphere_radius: f32 = 0.52;
    rl.drawGrid(12, 0.5);
    rl.drawSphere(sphere_center, sphere_radius, rl.Color{ .r = 165, .g = 168, .b = 176, .a = 220 });
    rl.drawSphereWires(sphere_center, sphere_radius, 16, 16, rl.Color{ .r = 88, .g = 93, .b = 106, .a = 255 });

    var elevation: f32 = 0;
    var bearing: f32 = 0;
    if (history.len > 0) {
        const i = history.index(history.len - 1);
        elevation = history.elevation[i];
        bearing = history.bearing[i];
    }

    drawAxisArrow(elevation, bearing, .{ .x = 1, .y = 0, .z = 0 }, rl.Color.red);
    drawAxisArrow(elevation, bearing, .{ .x = 0, .y = 1, .z = 0 }, rl.Color.green);
    drawAxisArrow(elevation, bearing, .{ .x = 0, .y = 0, .z = 1 }, rl.Color.blue);
    rl.endMode3D();
    rl.endTextureMode();

    const src = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(rt.texture.width),
        .height = -@as(f32, @floatFromInt(rt.texture.height)),
    };
    rl.drawTexturePro(rt.texture, src, rect, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    rl.drawRectangleLinesEx(rect, 1, cfg.theme.border);
}

fn drawAxisArrow(elevation_deg: f32, bearing_deg: f32, axis: rl.Vector3, color: rl.Color) void {
    const dir = rotateAxis(axis, elevation_deg, bearing_deg);
    const origin = rl.Vector3{ .x = 0, .y = 0.55, .z = 0 };

    const shaft_start = origin.add(dir.scale(0.56));
    const shaft_end = origin.add(dir.scale(1.55));
    rl.drawCylinderEx(shaft_start, shaft_end, 0.03, 0.03, 12, color);

    const head_start = origin.add(dir.scale(1.55));
    const head_end = origin.add(dir.scale(1.82));
    rl.drawCylinderEx(head_start, head_end, 0.09, 0.0, 12, color);
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
