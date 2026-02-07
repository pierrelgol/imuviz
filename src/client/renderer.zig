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

    fn deinit(self: *SceneTarget) void {
        if (self.rt) |texture| rl.unloadRenderTexture(texture);
        self.* = .{};
    }
};

pub const Renderer = struct {
    scenes: [cfg.max_hosts]SceneTarget = [_]SceneTarget{.{}} ** cfg.max_hosts,

    pub fn deinit(self: *Renderer) void {
        for (&self.scenes) |*scene| scene.deinit();
    }

    pub fn draw(self: *Renderer, devices: []const DeviceFrame) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();
        const draw_count = @min(devices.len, self.scenes.len);

        const layout = ui.computeRootLayout(screen_w, screen_h);
        rl.clearBackground(cfg.theme.background);
        drawTitleBar(layout.title, draw_count);

        for (devices[0..draw_count], 0..) |device, idx| {
            const panel = ui.panelRect(layout.body, draw_count, idx, layout.scale.gap);
            if (!isDrawableRect(panel)) continue;
            drawDevicePanel(&self.scenes[idx], panel, layout.scale, device);
        }
    }
};

fn drawTitleBar(title_rect: rl.Rectangle, device_count: usize) void {
    rl.drawRectangleRec(title_rect, cfg.theme.title_panel);
    rl.drawRectangleLinesEx(title_rect, cfg.renderer.panel_border_thickness, cfg.renderer.title_border);
    drawTextFmt(
        "IMU Visualizer - {d} device(s)",
        .{device_count},
        @intFromFloat(title_rect.x + 8.0),
        @intFromFloat(title_rect.y + 6.0),
        cfg.renderer.panel_title_size,
        cfg.theme.text_primary,
    );
}

fn drawDevicePanel(scene_target: *SceneTarget, panel: rl.Rectangle, scale: ui.UiScale, device: DeviceFrame) void {
    rl.drawRectangleRec(panel, cfg.theme.frame_panel);
    rl.drawRectangleLinesEx(panel, cfg.renderer.panel_border_thickness, cfg.renderer.panel_border);

    drawPanelHeader(panel, scale, device);

    const content = ui.splitDevicePanel(panel, scale);
    drawScenePanel(scene_target, content.scene, device.history);
    drawSignalPlots(content, device.history);
    drawCurrentValues(panel, device.history);
}

fn drawPanelHeader(panel: rl.Rectangle, scale: ui.UiScale, device: DeviceFrame) void {
    const header_y = panel.y + scale.panel_padding * cfg.renderer.panel_title_padding_scale;
    drawTextFmt(
        "{s}",
        .{device.title},
        @intFromFloat(panel.x + scale.panel_padding),
        @intFromFloat(header_y),
        cfg.renderer.panel_title_size,
        cfg.theme.text_primary,
    );

    const status = statusMeta(device.snapshot.state);
    drawTextFmt(
        "Status: {s} | Parse: {} | ConnFail: {} | Disc: {} | Reconn: {}",
        .{ status.text, device.snapshot.parse_errors, device.snapshot.connect_failures, device.snapshot.disconnects, device.snapshot.reconnects },
        @intFromFloat(panel.x + cfg.renderer.status_text_x_offset),
        @intFromFloat(header_y + cfg.renderer.status_text_y_offset),
        cfg.renderer.status_text_size,
        status.color,
    );
}

fn drawSignalPlots(content: ui.PanelContentLayout, history: *const History) void {
    if (content.chart_count < 6) return;

    const t_accel_x = [_]plotting.TraceDef{.{ .kind = .accel_x, .name = "accel_x", .color = rl.Color.red }};
    const t_accel_y = [_]plotting.TraceDef{.{ .kind = .accel_y, .name = "accel_y", .color = rl.Color.green }};
    const t_accel_z = [_]plotting.TraceDef{.{ .kind = .accel_z, .name = "accel_z", .color = rl.Color.blue }};
    const t_gyro_norm = [_]plotting.TraceDef{.{ .kind = .gyro_norm, .name = "gyro_norm", .color = cfg.renderer.trace_gyro_norm }};
    const t_elevation = [_]plotting.TraceDef{.{ .kind = .elevation, .name = "elevation", .color = rl.Color.orange }};
    const t_bearing = [_]plotting.TraceDef{.{ .kind = .bearing, .name = "bearing", .color = rl.Color.sky_blue }};

    const accel_domain: plotting.YDomain = .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } };

    drawSignalPlot(content.charts[0], history, "accel_x", "", &t_accel_x, accel_domain, .fixed0);
    drawSignalPlot(content.charts[1], history, "accel_y", "", &t_accel_y, accel_domain, .fixed0);
    drawSignalPlot(content.charts[2], history, "accel_z", "", &t_accel_z, accel_domain, .fixed0);
    drawSignalPlot(content.charts[3], history, "gyro_norm", "", &t_gyro_norm, .{ .fixed = .{ .min = cfg.plot.gyro_norm_min, .max = cfg.plot.gyro_norm_max } }, .fixed0);
    drawSignalPlot(content.charts[4], history, "elevation", "", &t_elevation, .{ .fixed = .{ .min = cfg.plot.elevation_min_deg, .max = cfg.plot.elevation_max_deg } }, .fixed0);
    drawSignalPlot(content.charts[5], history, "bearing", "", &t_bearing, .{ .fixed = .{ .min = cfg.plot.orientation_min_deg, .max = cfg.plot.orientation_max_deg } }, .fixed0);
}

fn drawSignalPlot(
    rect: rl.Rectangle,
    history: *const History,
    title: []const u8,
    y_label: []const u8,
    traces: []const plotting.TraceDef,
    y_domain: plotting.YDomain,
    y_format: plotting.LabelFormat,
) void {
    if (!isDrawableRect(rect)) return;

    plotting.drawPlot(
        rect,
        history,
        .{
            .title = title,
            .traces = traces,
            .x_window_seconds = cfg.history_window_seconds,
            .x_axis = .{ .label = "time (s)", .graduation_count = cfg.plot.raw_x_graduations, .label_format = .fixed1 },
            .y_axis = .{ .label = y_label, .graduation_count = cfg.plot.raw_y_graduations, .label_format = y_format },
            .x_labels_relative_to_latest = true,
            .show_x_axis_label = false,
            .show_y_axis_label = false,
            .y_domain = y_domain,
        },
        .{},
    );
}

fn drawCurrentValues(panel: rl.Rectangle, history: *const History) void {
    if (history.len == 0) return;

    const i = history.index(history.len - 1);
    const y = panel.y + panel.height - cfg.renderer.current_values_bottom_offset;
    drawTextFmt(
        "A:[{d:.0},{d:.0},{d:.0}] Gnorm:{d:.1} E:{d:.1} B:{d:.1}",
        .{ history.accel_x[i], history.accel_y[i], history.accel_z[i], history.gyro_norm[i], history.elevation[i], history.bearing[i] },
        @intFromFloat(panel.x + cfg.renderer.current_values_x_offset),
        @intFromFloat(y),
        cfg.renderer.current_values_size,
        cfg.theme.text_secondary,
    );
}

fn drawScenePanel(target: *SceneTarget, rect: rl.Rectangle, history: *const History) void {
    if (!isDrawableRect(rect)) return;

    const width: i32 = @intFromFloat(@max(rect.width, 1));
    const height: i32 = @intFromFloat(@max(rect.height, 1));
    target.ensure(width, height);

    const rt = target.rt orelse {
        drawSceneUnavailable(rect);
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
    drawAxisArrow(orientation.elevation, orientation.bearing, .{ .x = 1, .y = 0, .z = 0 }, rl.Color.red);
    drawAxisArrow(orientation.elevation, orientation.bearing, .{ .x = 0, .y = 1, .z = 0 }, rl.Color.green);
    drawAxisArrow(orientation.elevation, orientation.bearing, .{ .x = 0, .y = 0, .z = 1 }, rl.Color.blue);
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

fn drawSceneUnavailable(rect: rl.Rectangle) void {
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
    if (history.len == 0) return .{ .elevation = 0, .bearing = 0 };
    const i = history.index(history.len - 1);
    return .{ .elevation = history.elevation[i], .bearing = history.bearing[i] };
}

fn drawAxisArrow(elevation_deg: f32, bearing_deg: f32, axis: rl.Vector3, color: rl.Color) void {
    const dir = rotateAxis(axis, elevation_deg, bearing_deg);
    const origin = cfg.scene3d.origin;

    const shaft_start = origin.add(dir.scale(cfg.scene3d.axis_shaft_start));
    const shaft_end = origin.add(dir.scale(cfg.scene3d.axis_shaft_end));
    rl.drawCylinderEx(shaft_start, shaft_end, cfg.scene3d.axis_shaft_radius, cfg.scene3d.axis_shaft_radius, cfg.scene3d.axis_sides, color);

    const head_start = origin.add(dir.scale(cfg.scene3d.axis_head_start));
    const head_end = origin.add(dir.scale(cfg.scene3d.axis_head_end));
    rl.drawCylinderEx(head_start, head_end, cfg.scene3d.axis_head_radius, 0.0, cfg.scene3d.axis_sides, color);
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

fn statusMeta(state: net.ConnectionState) struct { text: []const u8, color: rl.Color } {
    return switch (state) {
        .connected => .{ .text = "Connected", .color = cfg.renderer.status_connected },
        .connecting => .{ .text = "Connecting", .color = cfg.renderer.status_connecting },
        .disconnected => .{ .text = "Disconnected", .color = cfg.renderer.status_disconnected },
    };
}

fn isDrawableRect(rect: rl.Rectangle) bool {
    return rect.width >= 1.0 and rect.height >= 1.0;
}
