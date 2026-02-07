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

const FocusTarget = union(enum) {
    scene: usize,
    plot: usize,
};

pub const Renderer = struct {
    scenes: [cfg.max_hosts]scene3d.SceneTarget = [_]scene3d.SceneTarget{.{}} ** cfg.max_hosts,
    shared_cursor: cursor.SharedCursor = .{},
    root_layout_options: ui.RootLayoutOptions = .{},
    comparison_layout_options: ui.ComparisonLayoutOptions = .{},

    paused: bool = false,
    pause_key_prev_down: bool = false,
    pause_mouse_prev_down: bool = false,
    paused_count: usize = 0,
    paused_histories: [cfg.max_hosts]History = [_]History{.{}} ** cfg.max_hosts,
    paused_snapshots: [cfg.max_hosts]net.EndpointSnapshot = [_]net.EndpointSnapshot{.{
        .state = .disconnected,
        .parse_errors = 0,
        .disconnects = 0,
        .reconnects = 0,
        .partial_disconnects = 0,
        .connect_failures = 0,
    }} ** cfg.max_hosts,
    paused_titles: [cfg.max_hosts][]const u8 = [_][]const u8{""} ** cfg.max_hosts,

    x_window_seconds: f64 = cfg.history_window_seconds,
    maximized: ?FocusTarget = null,

    pub fn deinit(self: *Renderer) void {
        for (&self.scenes) |*scene| scene.deinit();
    }

    pub fn draw(self: *Renderer, devices: []const DeviceFrame, options: options_mod.RuntimeOptions) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();
        const live_count = @min(devices.len, self.scenes.len);

        const root = ui.computeRootLayout(screen_w, screen_h, self.root_layout_options);
        const cmp = ui.splitComparison(root.body, root.scale, live_count, self.comparison_layout_options);

        self.handlePauseInput(root.title, devices[0..live_count]);
        self.handleZoomInput(cmp, root.body);

        var render_frames_buffer: [cfg.max_hosts]DeviceFrame = undefined;
        const render_frames = self.selectRenderFrames(devices[0..live_count], &render_frames_buffer);

        rl.clearBackground(cfg.theme.background);
        drawTitleBar(root.title, render_frames.len, options.show_fps, self.paused, self.x_window_seconds);

        if (self.maximized) |focus| {
            switch (focus) {
                .scene => |idx| {
                    if (idx < render_frames.len) {
                        drawSceneCard(&self.scenes[idx], root.body, root.scale, render_frames[idx], options);
                        const button = drawWindowButton(root.body, true);
                        if (isClicked(button)) self.maximized = null;
                        return;
                    }
                },
                .plot => |idx| {
                    if (idx < cfg.ui.chart_count) {
                        self.updateCursorForRect(root.body);
                        drawOnePlot(root.body, idx, render_frames, self.shared_cursor, options, self.x_window_seconds);
                        const button = drawWindowButton(root.body, true);
                        if (isClicked(button)) self.maximized = null;
                        return;
                    }
                },
            }
            self.maximized = null;
        }

        for (render_frames, 0..) |frame, i| {
            drawSceneCard(&self.scenes[i], cmp.scenes[i], root.scale, frame, options);
            const button = drawWindowButton(cmp.scenes[i], false);
            if (isClicked(button)) self.maximized = .{ .scene = i };
        }

        self.shared_cursor.update(cmp.plots);
        drawSharedPlots(cmp.plots, render_frames, self.shared_cursor, options, self.x_window_seconds);
        for (cmp.plots, 0..) |rect, i| {
            const button = drawWindowButton(rect, false);
            if (isClicked(button)) self.maximized = .{ .plot = i };
        }
    }

    fn handlePauseInput(self: *Renderer, title_rect: rl.Rectangle, live_frames: []const DeviceFrame) void {
        const key_down = rl.isKeyDown(cfg.renderer.pause_key);
        const key_toggle = key_down and !self.pause_key_prev_down;
        self.pause_key_prev_down = key_down;

        const pause_button = pauseButtonRect(title_rect);
        const mouse_down = rl.isMouseButtonDown(.left);
        const mouse_toggle = mouse_down and !self.pause_mouse_prev_down and pointInRect(rl.getMousePosition(), pause_button);
        self.pause_mouse_prev_down = mouse_down;

        if (!(key_toggle or mouse_toggle)) return;
        self.paused = !self.paused;
        if (self.paused) self.capturePaused(live_frames);
    }

    fn capturePaused(self: *Renderer, live_frames: []const DeviceFrame) void {
        self.paused_count = @min(live_frames.len, cfg.max_hosts);
        for (0..self.paused_count) |i| {
            self.paused_histories[i] = live_frames[i].history.*;
            self.paused_snapshots[i] = live_frames[i].snapshot;
            self.paused_titles[i] = live_frames[i].title;
        }
    }

    fn selectRenderFrames(self: *Renderer, live_frames: []const DeviceFrame, out: *[cfg.max_hosts]DeviceFrame) []const DeviceFrame {
        if (!self.paused) return live_frames;

        const count = @min(self.paused_count, cfg.max_hosts);
        for (0..count) |i| {
            out[i] = .{
                .title = self.paused_titles[i],
                .history = &self.paused_histories[i],
                .snapshot = self.paused_snapshots[i],
            };
        }
        return out[0..count];
    }

    fn handleZoomInput(self: *Renderer, cmp: ui.ComparisonLayout, maximized_rect: rl.Rectangle) void {
        const wheel = rl.getMouseWheelMove();
        if (wheel == 0.0) return;

        if (self.maximized) |focus| {
            if (focus == .plot and pointInRect(rl.getMousePosition(), maximized_rect)) {
                self.applyZoom(wheel);
            }
            return;
        }

        const mouse = rl.getMousePosition();
        for (cmp.plots) |rect| {
            if (pointInRect(mouse, rect)) {
                self.applyZoom(wheel);
                return;
            }
        }
    }

    fn applyZoom(self: *Renderer, wheel: f32) void {
        const factor = std.math.exp(-cfg.renderer.zoom_step * @as(f64, wheel));
        self.x_window_seconds = @max(cfg.renderer.zoom_min_window_seconds, @min(cfg.renderer.zoom_max_window_seconds, self.x_window_seconds * factor));
    }

    fn updateCursorForRect(self: *Renderer, rect: rl.Rectangle) void {
        const mouse = rl.getMousePosition();
        if (pointInRect(mouse, rect) and rect.width > 1.0) {
            self.shared_cursor.active = true;
            self.shared_cursor.x_norm = @max(0.0, @min(1.0, (mouse.x - rect.x) / rect.width));
        } else {
            self.shared_cursor.active = false;
        }
    }
};

fn drawTitleBar(title_rect: rl.Rectangle, device_count: usize, show_fps: bool, paused: bool, window_seconds: f64) void {
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

    drawTextFmt(
        "Window:{d:.1}s {s}",
        .{ window_seconds, if (paused) "PAUSED" else "LIVE" },
        @intFromFloat(title_rect.x + title_rect.width * 0.35),
        @intFromFloat(title_rect.y + 6.0),
        cfg.renderer.status_text_size,
        if (paused) cfg.renderer.status_connecting else cfg.theme.text_secondary,
    );

    drawPauseButton(title_rect, paused);
    if (show_fps) drawFpsTopRight(title_rect);
}

fn drawPauseButton(title_rect: rl.Rectangle, paused: bool) void {
    const rect = pauseButtonRect(title_rect);
    rl.drawRectangleRec(rect, cfg.renderer.control_button_fill);
    rl.drawRectangleLinesEx(rect, 1.0, cfg.renderer.control_button_border);
    rl.drawText(if (paused) "R" else "P", @intFromFloat(rect.x + 4.0), @intFromFloat(rect.y + 2.0), cfg.renderer.control_button_text_size, cfg.renderer.control_button_text);
}

fn pauseButtonRect(title_rect: rl.Rectangle) rl.Rectangle {
    const size = cfg.renderer.control_button_size;
    const pad = cfg.renderer.control_button_padding;
    return .{
        .x = title_rect.x + title_rect.width - pad - size - 70.0,
        .y = title_rect.y + pad,
        .width = size,
        .height = size,
    };
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

fn drawSceneCard(target: *scene3d.SceneTarget, rect: rl.Rectangle, scale: ui.UiScale, device: DeviceFrame, options: options_mod.RuntimeOptions) void {
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
    if (options.show_status_line) {
        drawTextFmt(
            "{s} | Parse:{} ConnFail:{} Disc:{} Reconn:{}",
            .{ status.text, device.snapshot.parse_errors, device.snapshot.connect_failures, device.snapshot.disconnects, device.snapshot.reconnects },
            @intFromFloat(rect.x + pad),
            @intFromFloat(status_y),
            cfg.renderer.status_text_size,
            status.color,
        );
    }

    const scene_y = status_y + @as(f32, @floatFromInt(cfg.renderer.status_text_size)) + pad;
    const values_h = @as(f32, @floatFromInt(cfg.renderer.current_values_size)) + pad;
    const scene_rect = rl.Rectangle{
        .x = rect.x + pad,
        .y = scene_y,
        .width = @max(1.0, rect.width - pad * 2.0),
        .height = @max(1.0, rect.height - (scene_y - rect.y) - values_h),
    };
    if (options.show_scene) {
        scene3d.draw(target, scene_rect, device.history);
    } else {
        rl.drawRectangleRec(scene_rect, cfg.theme.background);
        rl.drawRectangleLinesEx(scene_rect, cfg.renderer.panel_border_thickness, cfg.renderer.panel_border);
    }

    if (options.show_current_values) drawCurrentValues(rect, device.history);
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

fn drawSharedPlots(plot_rects: [cfg.ui.chart_count]rl.Rectangle, devices: []const DeviceFrame, shared_cursor: cursor.SharedCursor, options: options_mod.RuntimeOptions, x_window_seconds: f64) void {
    drawOnePlot(plot_rects[0], 0, devices, shared_cursor, options, x_window_seconds);
    drawOnePlot(plot_rects[1], 1, devices, shared_cursor, options, x_window_seconds);
    drawOnePlot(plot_rects[2], 2, devices, shared_cursor, options, x_window_seconds);
    drawOnePlot(plot_rects[3], 3, devices, shared_cursor, options, x_window_seconds);
    drawOnePlot(plot_rects[4], 4, devices, shared_cursor, options, x_window_seconds);
    drawOnePlot(plot_rects[5], 5, devices, shared_cursor, options, x_window_seconds);
}

fn drawOnePlot(rect: rl.Rectangle, plot_index: usize, devices: []const DeviceFrame, shared_cursor: cursor.SharedCursor, options: options_mod.RuntimeOptions, x_window_seconds: f64) void {
    switch (plot_index) {
        0 => drawComparisonPlot(rect, plot_index, devices, .accel_x, "accel_x", .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } }, .fixed0, rl.Color.red, options.show_accel_x_plot, shared_cursor, options, .{ .warn_abs = options.tolerance_accel_warn_abs, .fail_abs = options.tolerance_accel_fail_abs, .basis = toleranceBasisFromOptions(options) }, x_window_seconds),
        1 => drawComparisonPlot(rect, plot_index, devices, .accel_y, "accel_y", .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } }, .fixed0, rl.Color.green, options.show_accel_y_plot, shared_cursor, options, .{ .warn_abs = options.tolerance_accel_warn_abs, .fail_abs = options.tolerance_accel_fail_abs, .basis = toleranceBasisFromOptions(options) }, x_window_seconds),
        2 => drawComparisonPlot(rect, plot_index, devices, .accel_z, "accel_z", .{ .fixed = .{ .min = cfg.plot.accel_min, .max = cfg.plot.accel_max } }, .fixed0, rl.Color.blue, options.show_accel_z_plot, shared_cursor, options, .{ .warn_abs = options.tolerance_accel_warn_abs, .fail_abs = options.tolerance_accel_fail_abs, .basis = toleranceBasisFromOptions(options) }, x_window_seconds),
        3 => drawComparisonPlot(rect, plot_index, devices, .gyro_norm, "gyro_norm", .{ .fixed = .{ .min = cfg.plot.gyro_norm_min, .max = cfg.plot.gyro_norm_max } }, .fixed0, cfg.renderer.trace_gyro_norm, options.show_gyro_norm_plot, shared_cursor, options, .{ .warn_abs = options.tolerance_gyro_warn_abs, .fail_abs = options.tolerance_gyro_fail_abs, .basis = toleranceBasisFromOptions(options) }, x_window_seconds),
        4 => drawComparisonPlot(rect, plot_index, devices, .elevation, "elevation", .{ .fixed = .{ .min = cfg.plot.elevation_min_deg, .max = cfg.plot.elevation_max_deg } }, .fixed0, rl.Color.orange, options.show_elevation_plot, shared_cursor, options, .{ .warn_abs = options.tolerance_elevation_warn_abs, .fail_abs = options.tolerance_elevation_fail_abs, .basis = toleranceBasisFromOptions(options) }, x_window_seconds),
        5 => drawComparisonPlot(rect, plot_index, devices, .bearing, "bearing", .{ .fixed = .{ .min = cfg.plot.orientation_min_deg, .max = cfg.plot.orientation_max_deg } }, .fixed0, rl.Color.sky_blue, options.show_bearing_plot, shared_cursor, options, .{ .warn_abs = options.tolerance_bearing_warn_abs, .fail_abs = options.tolerance_bearing_fail_abs, .basis = toleranceBasisFromOptions(options) }, x_window_seconds),
        else => {},
    }
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
    plot_visible: bool,
    shared_cursor: cursor.SharedCursor,
    options: options_mod.RuntimeOptions,
    tolerance: plotting.ToleranceOptions,
    x_window_seconds: f64,
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
            .render_enabled = plot_visible,
            .available = devices[i].snapshot.state == .connected,
        };
        series_count += 1;
    }
    if (n >= 2) {
        series_buffer[series_count] = .{
            .history = devices[0].history,
            .rhs_history = devices[1].history,
            .kind = kind,
            .label = "d",
            .color = cfg.renderer.delta_trace,
            .render_enabled = plot_visible and options.show_delta_series,
            .available = devices[0].snapshot.state == .connected and devices[1].snapshot.state == .connected,
        };
        series_count += 1;
    }

    plotting.drawPlot(
        rect,
        .{
            .title = title,
            .series = series_buffer[0..series_count],
            .x_window_seconds = x_window_seconds,
            .x_axis = .{ .label = "time (s)", .graduation_count = cfg.plot.raw_x_graduations, .label_format = .fixed1 },
            .y_axis = .{ .label = "", .graduation_count = cfg.plot.raw_y_graduations, .label_format = y_format },
            .x_labels_relative_to_latest = true,
            .show_x_axis_label = false,
            .show_y_axis_label = false,
            .show_legend = options.show_legend and series_count > 1,
            .show_grid = options.show_plot_grid,
            .show_axes = options.show_plot_axes,
            .show_traces = options.show_plot_traces,
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

fn drawWindowButton(rect: rl.Rectangle, active: bool) rl.Rectangle {
    const size = cfg.renderer.control_button_size;
    const pad = cfg.renderer.control_button_padding;
    const btn = rl.Rectangle{
        .x = rect.x + rect.width - size - pad,
        .y = rect.y + pad,
        .width = size,
        .height = size,
    };
    rl.drawRectangleRec(btn, cfg.renderer.control_button_fill);
    rl.drawRectangleLinesEx(btn, 1.0, cfg.renderer.control_button_border);
    rl.drawText(if (active) "x" else "+", @intFromFloat(btn.x + 4.0), @intFromFloat(btn.y + 2.0), cfg.renderer.control_button_text_size, cfg.renderer.control_button_text);
    return btn;
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

fn isClicked(rect: rl.Rectangle) bool {
    return rl.isMouseButtonPressed(.left) and pointInRect(rl.getMousePosition(), rect);
}

fn pointInRect(p: rl.Vector2, rect: rl.Rectangle) bool {
    return p.x >= rect.x and p.x <= rect.x + rect.width and p.y >= rect.y and p.y <= rect.y + rect.height;
}
