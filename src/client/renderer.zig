const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const ui = @import("ui.zig");
const net = @import("network.zig");
const plotting = @import("plotting.zig");
const scene3d = @import("scene3d.zig");
const cursor = @import("cursor.zig");
const options_mod = @import("options.zig");
const History = @import("history.zig").History;
const drawTextFmt = @import("utils.zig").drawTextFmt;

pub const DeviceFrame = struct {
    title: []const u8,
    history: *const History,
    snapshot: net.EndpointSnapshot,
};

pub const Renderer = struct {
    scenes: [cfg.max_hosts]scene3d.SceneTarget = [_]scene3d.SceneTarget{.{}} ** cfg.max_hosts,
    shared_cursor: cursor.SharedCursor = .{},
    root_layout_options: ui.RootLayoutOptions = .{},
    comparison_layout_options: ui.ComparisonLayoutOptions = .{},

    pub fn deinit(self: *Renderer) void {
        for (&self.scenes) |*scene| scene.deinit();
    }

    pub fn draw(self: *Renderer, devices: []const DeviceFrame, options: options_mod.RuntimeOptions) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();
        const draw_count = @min(devices.len, self.scenes.len);

        const root = ui.computeRootLayout(screen_w, screen_h, self.root_layout_options);
        const cmp = ui.splitComparison(root.body, root.scale, draw_count, self.comparison_layout_options);

        rl.clearBackground(cfg.theme.background);
        drawTitleBar(root.title, draw_count);

        for (devices[0..draw_count], 0..) |device, i| {
            drawSceneCard(&self.scenes[i], cmp.scenes[i], root.scale, device);
        }

        self.shared_cursor.update(cmp.plots);
        drawSharedPlots(cmp.plots, devices[0..draw_count], self.shared_cursor, options);
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
    drawFpsTopRight(title_rect);
}

fn drawFpsTopRight(title_rect: rl.Rectangle) void {
    var fps_buf: [32]u8 = undefined;
    const fps_text = std.fmt.bufPrintZ(&fps_buf, "FPS: {d}", .{rl.getFPS()}) catch return;
    const font_size = cfg.renderer.status_text_size;
    const text_w = rl.measureText(fps_text, font_size);
    const x: i32 = @intFromFloat(title_rect.x + title_rect.width - @as(f32, @floatFromInt(text_w)) - cfg.renderer.fps_right_padding);
    const y: i32 = @intFromFloat(title_rect.y + cfg.renderer.fps_top_padding);
    rl.drawText(fps_text, x, y, font_size, cfg.theme.text_secondary);
}

fn drawSceneCard(target: *scene3d.SceneTarget, rect: rl.Rectangle, scale: ui.UiScale, device: DeviceFrame) void {
    if (!isDrawableRect(rect)) return;

    rl.drawRectangleRec(rect, cfg.theme.frame_panel);
    rl.drawRectangleLinesEx(rect, cfg.renderer.panel_border_thickness, cfg.renderer.panel_border);

    const pad = scale.panel_padding;
    const header_top = rect.y + pad * cfg.renderer.panel_title_padding_scale;
    drawTextFmt(
        "{s}",
        .{device.title},
        @intFromFloat(rect.x + pad),
        @intFromFloat(header_top),
        cfg.renderer.panel_title_size,
        cfg.theme.text_primary,
    );

    const status = statusMeta(device.snapshot.state);
    const status_y = header_top + @as(f32, @floatFromInt(cfg.renderer.panel_title_size)) + 2.0;
    drawTextFmt(
        "{s} | Parse:{} ConnFail:{} Disc:{} Reconn:{}",
        .{ status.text, device.snapshot.parse_errors, device.snapshot.connect_failures, device.snapshot.disconnects, device.snapshot.reconnects },
        @intFromFloat(rect.x + pad),
        @intFromFloat(status_y),
        cfg.renderer.status_text_size,
        status.color,
    );

    const scene_y = status_y + @as(f32, @floatFromInt(cfg.renderer.status_text_size)) + pad;
    const values_h = @as(f32, @floatFromInt(cfg.renderer.current_values_size)) + pad;
    const scene_rect = rl.Rectangle{
        .x = rect.x + pad,
        .y = scene_y,
        .width = @max(1.0, rect.width - pad * 2.0),
        .height = @max(1.0, rect.height - (scene_y - rect.y) - values_h),
    };
    scene3d.draw(target, scene_rect, device.history);

    drawCurrentValues(rect, device.history);
}

fn drawCurrentValues(card_rect: rl.Rectangle, history: *const History) void {
    const sample = history.latestSample() orelse return;
    const y = card_rect.y + card_rect.height - cfg.renderer.current_values_bottom_offset;
    drawTextFmt(
        "A:[{d:.0},{d:.0},{d:.0}] Gnorm:{d:.1} E:{d:.1} B:{d:.1}",
        .{ sample.accel_x, sample.accel_y, sample.accel_z, sample.gyro_norm, sample.elevation, sample.bearing },
        @intFromFloat(card_rect.x + cfg.renderer.current_values_x_offset),
        @intFromFloat(y),
        cfg.renderer.current_values_size,
        cfg.theme.text_secondary,
    );
}

fn drawSharedPlots(plot_rects: [cfg.ui.chart_count]rl.Rectangle, devices: []const DeviceFrame, shared_cursor: cursor.SharedCursor, options: options_mod.RuntimeOptions) void {
    drawComparisonPlot(plot_rects[0], 0, devices, .accel_x, "accel_x", .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } }, .fixed0, rl.Color.red, shared_cursor, options, .{ .warn_abs = options.tolerance_accel_warn_abs, .fail_abs = options.tolerance_accel_fail_abs, .basis = toleranceBasisFromOptions(options) });
    drawComparisonPlot(plot_rects[1], 1, devices, .accel_y, "accel_y", .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } }, .fixed0, rl.Color.green, shared_cursor, options, .{ .warn_abs = options.tolerance_accel_warn_abs, .fail_abs = options.tolerance_accel_fail_abs, .basis = toleranceBasisFromOptions(options) });
    drawComparisonPlot(plot_rects[2], 2, devices, .accel_z, "accel_z", .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } }, .fixed0, rl.Color.blue, shared_cursor, options, .{ .warn_abs = options.tolerance_accel_warn_abs, .fail_abs = options.tolerance_accel_fail_abs, .basis = toleranceBasisFromOptions(options) });
    drawComparisonPlot(plot_rects[3], 3, devices, .gyro_norm, "gyro_norm", .{ .fixed = .{ .min = cfg.plot.gyro_norm_min, .max = cfg.plot.gyro_norm_max } }, .fixed0, cfg.renderer.trace_gyro_norm, shared_cursor, options, .{ .warn_abs = options.tolerance_gyro_warn_abs, .fail_abs = options.tolerance_gyro_fail_abs, .basis = toleranceBasisFromOptions(options) });
    drawComparisonPlot(plot_rects[4], 4, devices, .elevation, "elevation", .{ .fixed = .{ .min = cfg.plot.elevation_min_deg, .max = cfg.plot.elevation_max_deg } }, .fixed0, rl.Color.orange, shared_cursor, options, .{ .warn_abs = options.tolerance_elevation_warn_abs, .fail_abs = options.tolerance_elevation_fail_abs, .basis = toleranceBasisFromOptions(options) });
    drawComparisonPlot(plot_rects[5], 5, devices, .bearing, "bearing", .{ .fixed = .{ .min = cfg.plot.orientation_min_deg, .max = cfg.plot.orientation_max_deg } }, .fixed0, rl.Color.sky_blue, shared_cursor, options, .{ .warn_abs = options.tolerance_bearing_warn_abs, .fail_abs = options.tolerance_bearing_fail_abs, .basis = toleranceBasisFromOptions(options) });
}

fn drawComparisonPlot(
    rect: rl.Rectangle,
    plot_index: usize,
    devices: []const DeviceFrame,
    kind: History.TraceKind,
    title: []const u8,
    y_domain: plotting.YDomain,
    y_format: plotting.LabelFormat,
    base_color: rl.Color,
    shared_cursor: cursor.SharedCursor,
    options: options_mod.RuntimeOptions,
    tolerance: plotting.ToleranceOptions,
) void {
    if (!isDrawableRect(rect)) return;

    var series_buffer: [cfg.max_hosts + 1]plotting.SeriesDef = undefined;
    const n = @min(devices.len, cfg.max_hosts);
    var series_count: usize = 0;
    for (0..n) |i| {
        series_buffer[i] = .{
            .history = devices[i].history,
            .kind = kind,
            .label = deviceSeriesLabel(i),
            .color = shadeForDevice(base_color, i, n),
            .available = devices[i].snapshot.state == .connected,
        };
        series_count += 1;
    }
    if (cfg.plot.show_delta_series and n >= 2) {
        series_buffer[series_count] = .{
            .history = devices[0].history,
            .rhs_history = devices[1].history,
            .kind = kind,
            .label = "d",
            .color = cfg.renderer.delta_trace,
            .available = devices[0].snapshot.state == .connected and devices[1].snapshot.state == .connected,
            .render_enabled = options.show_delta_series,
        };
        series_count += 1;
    }

    plotting.drawPlot(
        rect,
        .{
            .title = title,
            .series = series_buffer[0..series_count],
            .x_window_seconds = cfg.history_window_seconds,
            .x_axis = .{ .label = "time (s)", .graduation_count = cfg.plot.raw_x_graduations, .label_format = .fixed1 },
            .y_axis = .{ .label = "", .graduation_count = cfg.plot.raw_y_graduations, .label_format = y_format },
            .x_labels_relative_to_latest = true,
            .show_x_axis_label = false,
            .show_y_axis_label = false,
            .show_legend = options.show_legend and series_count > 1,
            .y_domain = y_domain,
            .cursor_x_norm = if (options.show_cursor and shared_cursor.active) shared_cursor.x_norm else null,
            .show_stats_panel = options.show_stats_panel,
            .show_tolerance = options.show_tolerance,
            .stats_key = plot_index,
            .tolerance = tolerance,
        },
        .{},
    );
}

fn shadeForDevice(base: rl.Color, index: usize, total: usize) rl.Color {
    if (total <= 1) return base;
    if (index == 0) return blend(base, rl.Color.white, 0.35);
    return blend(base, rl.Color.black, 0.35);
}

fn blend(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        .r = lerpU8(a.r, b.r, clamped),
        .g = lerpU8(a.g, b.g, clamped),
        .b = lerpU8(a.b, b.b, clamped),
        .a = a.a,
    };
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af = @as(f32, @floatFromInt(a));
    const bf = @as(f32, @floatFromInt(b));
    return @intFromFloat(af + (bf - af) * t);
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

fn deviceSeriesLabel(index: usize) []const u8 {
    return switch (index) {
        0 => "1",
        1 => "2",
        2 => "3",
        3 => "4",
        4 => "5",
        5 => "6",
        else => "?",
    };
}

fn toleranceBasisFromOptions(options: options_mod.RuntimeOptions) plotting.ToleranceBasis {
    return if (options.tolerance_use_stddev) .stddev else .peak_abs;
}
