const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const ui = @import("ui.zig");
const net = @import("network.zig");
const plotting = @import("plotting.zig");
const scene3d = @import("scene3d.zig");
const History = @import("history.zig").History;
const drawTextFmt = @import("utils.zig").drawTextFmt;

pub const DeviceFrame = struct {
    title: []const u8,
    history: *const History,
    snapshot: net.EndpointSnapshot,
};

pub const Renderer = struct {
    scenes: [cfg.max_hosts]scene3d.SceneTarget = [_]scene3d.SceneTarget{.{}} ** cfg.max_hosts,
    root_layout_options: ui.RootLayoutOptions = .{},
    panel_layout_options: ui.PanelLayoutOptions = .{},

    pub fn deinit(self: *Renderer) void {
        for (&self.scenes) |*scene| scene.deinit();
    }

    pub fn draw(self: *Renderer, devices: []const DeviceFrame) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();
        const draw_count = @min(devices.len, self.scenes.len);

        const layout = ui.computeRootLayout(screen_w, screen_h, self.root_layout_options);
        rl.clearBackground(cfg.theme.background);
        drawTitleBar(layout.title, draw_count);

        for (devices[0..draw_count], 0..) |device, idx| {
            const panel = ui.panelRect(layout.body, draw_count, idx, layout.scale.gap);
            if (!isDrawableRect(panel)) continue;
            drawDevicePanel(&self.scenes[idx], panel, layout.scale, self.panel_layout_options, device);
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

fn drawDevicePanel(
    scene_target: *scene3d.SceneTarget,
    panel: rl.Rectangle,
    scale: ui.UiScale,
    panel_layout_options: ui.PanelLayoutOptions,
    device: DeviceFrame,
) void {
    rl.drawRectangleRec(panel, cfg.theme.frame_panel);
    rl.drawRectangleLinesEx(panel, cfg.renderer.panel_border_thickness, cfg.renderer.panel_border);

    drawPanelHeader(panel, scale, device);

    const content = ui.splitDevicePanel(panel, scale, panel_layout_options);
    scene3d.draw(scene_target, content.scene, device.history);
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
    const sample = history.latestSample() orelse return;
    const y = panel.y + panel.height - cfg.renderer.current_values_bottom_offset;
    drawTextFmt(
        "A:[{d:.0},{d:.0},{d:.0}] Gnorm:{d:.1} E:{d:.1} B:{d:.1}",
        .{ sample.accel_x, sample.accel_y, sample.accel_z, sample.gyro_norm, sample.elevation, sample.bearing },
        @intFromFloat(panel.x + cfg.renderer.current_values_x_offset),
        @intFromFloat(y),
        cfg.renderer.current_values_size,
        cfg.theme.text_secondary,
    );
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
