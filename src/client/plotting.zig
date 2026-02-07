const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const History = @import("history.zig").History;

pub const SeriesDef = struct {
    history: *const History,
    rhs_history: ?*const History = null,
    kind: History.TraceKind,
    label: []const u8,
    color: rl.Color,
    render_enabled: bool = true,
    available: bool = true,
};

pub const LabelFormat = enum {
    fixed0,
    fixed1,
    fixed2,
};

pub const AxisOptions = struct {
    label: []const u8,
    graduation_count: usize = 5,
    label_format: LabelFormat = .fixed1,
};

pub const PlotOptions = struct {
    title: []const u8,
    series: []const SeriesDef,
    x_window_seconds: f64,
    x_axis: AxisOptions,
    y_axis: AxisOptions,
    x_labels_relative_to_latest: bool = true,
    show_x_axis_label: bool = false,
    show_y_axis_label: bool = false,
    show_legend: bool = true,
    empty_message: []const u8 = "Waiting for data...",
    min_samples: usize = cfg.plot.min_samples,
    y_domain: YDomain = .dynamic,
    cursor_x_norm: ?f32 = null,
    show_stats_panel: bool = cfg.plot.show_stats_panel,
    show_tolerance: bool = cfg.plot.show_tolerance_overlay,
    stats_key: ?usize = null,
    tolerance: ?ToleranceOptions = null,
};

pub const YDomain = union(enum) {
    dynamic,
    fixed: AxisDomain,
};

pub const ToleranceMode = enum {
    delta_only,
    all_series,
};

pub const ToleranceBasis = enum {
    peak_abs,
    stddev,
};

pub const ToleranceOptions = struct {
    warn_abs: f32,
    fail_abs: f32,
    mode: ToleranceMode = .delta_only,
    basis: ToleranceBasis = .peak_abs,
};

pub const PlotStyle = struct {
    palette: Palette = .{},
    layout: Layout = .{},
    typography: Typography = .{},
    stroke: Stroke = .{},

    pub const Palette = struct {
        background: rl.Color = rgba(14, 16, 21, 255),
        border: rl.Color = rgba(58, 63, 76, 255),
        grid: rl.Color = rgba(46, 50, 60, 255),
        axis: rl.Color = rgba(88, 95, 112, 255),
        title: rl.Color = rgba(208, 214, 226, 255),
        label: rl.Color = rgba(198, 204, 216, 255),
        tick: rl.Color = rl.Color.light_gray,
        empty_text: rl.Color = rl.Color.gray,
        legend_text: rl.Color = rl.Color.light_gray,
        cursor_line: rl.Color = rgba(238, 242, 252, 176),
        cursor_panel_fill: rl.Color = cfg.plot.cursor_column_fill,
        tolerance_warn: rl.Color = rgba(247, 196, 80, 190),
        tolerance_fail: rl.Color = rgba(235, 94, 94, 210),
        tolerance_warn_fill: rl.Color = rgba(247, 196, 80, 36),
        tolerance_fail_fill: rl.Color = rgba(235, 94, 94, 44),
        tolerance_pass: rl.Color = cfg.renderer.status_connected,
    };

    pub const Layout = struct {
        left_padding_ratio: f32 = cfg.plot.left_padding_ratio,
        right_padding_ratio: f32 = cfg.plot.right_padding_ratio,
        top_padding_ratio: f32 = cfg.plot.top_padding_ratio,
        bottom_padding_ratio: f32 = cfg.plot.bottom_padding_ratio,
        tick_length_ratio: f32 = cfg.plot.tick_length_ratio,
        axis_label_offset_ratio: f32 = cfg.plot.axis_label_offset_ratio,
        title_offset_ratio: f32 = cfg.plot.title_offset_ratio,
        legend_offset_ratio: f32 = cfg.plot.legend_offset_ratio,
        legend_item_gap_ratio: f32 = cfg.plot.legend_item_gap_ratio,
        cursor_readout_offset_ratio: f32 = cfg.plot.cursor_readout_offset_ratio,
        cursor_readout_line_gap_ratio: f32 = cfg.plot.cursor_readout_line_gap_ratio,
        cursor_column_width_ratio: f32 = cfg.plot.cursor_column_width_ratio,
        cursor_column_gap_ratio: f32 = cfg.plot.cursor_column_gap_ratio,
        cursor_column_inner_padding_px: f32 = cfg.plot.cursor_column_inner_padding_px,
        y_tick_lane_width_ratio: f32 = cfg.plot.y_tick_lane_width_ratio,
    };

    pub const Typography = struct {
        title_size_ratio: f32 = cfg.plot.title_size_ratio,
        axis_label_size_ratio: f32 = cfg.plot.axis_label_size_ratio,
        tick_label_size_ratio: f32 = cfg.plot.tick_label_size_ratio,
        legend_size_ratio: f32 = cfg.plot.legend_size_ratio,
        empty_size_ratio: f32 = cfg.plot.empty_size_ratio,
        cursor_readout_size_ratio: f32 = cfg.plot.cursor_readout_size_ratio,
        stats_size_ratio: f32 = cfg.plot.stats_size_ratio,
        min_font_px: i32 = cfg.plot.min_font_px,
    };

    pub const Stroke = struct {
        border_ratio: f32 = cfg.plot.border_ratio,
        grid_ratio: f32 = cfg.plot.grid_ratio,
        trace_ratio: f32 = cfg.plot.trace_ratio,
        cursor_line_ratio: f32 = cfg.plot.cursor_line_ratio,
    };
};

pub fn drawPlot(rect: rl.Rectangle, options: PlotOptions, style: PlotStyle) void {
    drawFrame(rect, style);

    const chart_rect = computeChartRect(rect, style.layout);
    const min_dim = @min(rect.width, rect.height);

    drawPlotTitle(rect, options.title, style, min_dim);

    if (chart_rect.width <= 1 or chart_rect.height <= 1 or options.x_window_seconds <= 0 or options.series.len == 0) {
        drawEmptyState(chart_rect, options.empty_message, style, min_dim);
        return;
    }

    const x_domain: AxisDomain = if (options.x_labels_relative_to_latest)
        .{ .min = -options.x_window_seconds, .max = 0 }
    else
        .{ .min = absoluteLatest(options.series) - options.x_window_seconds, .max = absoluteLatest(options.series) };

    const tolerance_state = if (options.tolerance) |tol|
        evaluateToleranceState(options.series, x_domain, options.x_labels_relative_to_latest, tol)
    else
        null;

    drawSidePanel(
        rect,
        options.series,
        x_domain,
        options.x_labels_relative_to_latest,
        options.cursor_x_norm,
        options.show_stats_panel,
        options.stats_key,
        if (options.show_tolerance) tolerance_state else null,
        style,
        min_dim,
    );

    const y_domain = switch (options.y_domain) {
        .dynamic => computeYDomain(options.series, x_domain, options.x_labels_relative_to_latest, cfg.plot.y_padding_fraction) orelse {
            drawEmptyState(chart_rect, options.empty_message, style, min_dim);
            return;
        },
        .fixed => |domain| domain,
    };

    const points = countVisiblePoints(options.series, x_domain, options.x_labels_relative_to_latest);
    if (points < options.min_samples) {
        drawEmptyState(chart_rect, options.empty_message, style, min_dim);
        return;
    }

    drawGrid(chart_rect, options.x_axis.graduation_count, options.y_axis.graduation_count, style, min_dim);
    if (options.show_tolerance) {
        if (options.tolerance) |tol| drawToleranceOverlay(chart_rect, y_domain, tol, tolerance_state orelse .na, style, min_dim);
    }
    drawAxisGraduations(.x, chart_rect, x_domain, options.x_axis, style, min_dim);
    drawAxisGraduations(.y, chart_rect, y_domain, options.y_axis, style, min_dim);
    drawAxisLabels(rect, chart_rect, options, style, min_dim);

    drawSeries(options.series, chart_rect, x_domain, y_domain, options.x_labels_relative_to_latest, style, min_dim);
    if (options.cursor_x_norm) |cursor_x| {
        drawCursorLine(chart_rect, cursor_x, style, min_dim);
    }

    if (options.show_legend) drawLegend(rect, options.series, style, min_dim);
}

const Axis = enum { x, y };

pub const AxisDomain = struct {
    min: f64,
    max: f64,
};

fn drawFrame(rect: rl.Rectangle, style: PlotStyle) void {
    const min_dim = @min(rect.width, rect.height);
    rl.drawRectangleRec(rect, style.palette.background);
    rl.drawRectangleLinesEx(rect, lineThickness(min_dim, style.stroke.border_ratio), style.palette.border);
}

fn computeChartRect(rect: rl.Rectangle, layout: PlotStyle.Layout) rl.Rectangle {
    const cursor_column = computeCursorColumnRect(rect, layout);
    const right_pad = rect.width * layout.right_padding_ratio;
    const top_pad = rect.height * layout.top_padding_ratio;
    const bottom_pad = rect.height * layout.bottom_padding_ratio;
    const column_gap = rect.width * layout.cursor_column_gap_ratio;
    const y_tick_lane = rect.width * layout.y_tick_lane_width_ratio;
    return .{
        .x = cursor_column.x + cursor_column.width + column_gap + y_tick_lane,
        .y = rect.y + top_pad,
        .width = @max(1.0, rect.width - right_pad - cursor_column.width - column_gap - y_tick_lane),
        .height = @max(1.0, rect.height - top_pad - bottom_pad),
    };
}

fn computeCursorColumnRect(rect: rl.Rectangle, layout: PlotStyle.Layout) rl.Rectangle {
    const top_pad = rect.height * layout.top_padding_ratio;
    const bottom_pad = rect.height * layout.bottom_padding_ratio;
    const left_pad = rect.width * layout.left_padding_ratio;
    const w = @max(1.0, rect.width * layout.cursor_column_width_ratio + left_pad);
    return .{
        .x = rect.x + 1.0,
        .y = rect.y + top_pad,
        .width = w,
        .height = @max(1.0, rect.height - top_pad - bottom_pad),
    };
}

fn drawPlotTitle(rect: rl.Rectangle, title: []const u8, style: PlotStyle, min_dim: f32) void {
    const font = fontSize(min_dim, style.typography.title_size_ratio, style.typography.min_font_px);
    const y = rect.y + rect.height * style.layout.title_offset_ratio;
    const w = measureTextSlice(title, font);
    const x = rect.x + (rect.width - @as(f32, @floatFromInt(w))) * 0.5;
    drawTextSlice(title, @intFromFloat(x), @intFromFloat(y), font, style.palette.title);
}

fn drawEmptyState(chart_rect: rl.Rectangle, text: []const u8, style: PlotStyle, min_dim: f32) void {
    const font = fontSize(min_dim, style.typography.empty_size_ratio, style.typography.min_font_px);
    drawTextSlice(text, @intFromFloat(chart_rect.x + chart_rect.width * 0.03), @intFromFloat(chart_rect.y + chart_rect.height * 0.5), font, style.palette.empty_text);
}

fn absoluteLatest(series: []const SeriesDef) f64 {
    var latest: f64 = 0;
    var has_value = false;
    for (series) |s| {
        const lhs_ts = s.history.latestTimestamp() orelse continue;
        if (!has_value or lhs_ts > latest) {
            latest = lhs_ts;
            has_value = true;
        }
        if (s.rhs_history) |rhs| {
            const rhs_ts = rhs.latestTimestamp() orelse continue;
            if (rhs_ts > latest) latest = rhs_ts;
        }
    }
    return latest;
}

fn countVisiblePoints(series: []const SeriesDef, x_domain: AxisDomain, relative: bool) usize {
    var count: usize = 0;
    for (series) |s| {
        if (s.rhs_history) |_| {
            const pair_len = pairedSeriesLen(s);
            for (0..pair_len) |i| {
                const x = sampleXAtIndex(s.history, i, relative) orelse continue;
                if (x < x_domain.min or x > x_domain.max) continue;
                if (seriesValueAtIndex(s, i) != null) count += 1;
            }
            continue;
        }

        const latest_ts = s.history.latestTimestamp() orelse continue;
        for (0..s.history.len) |i| {
            const sample = s.history.sample(i);
            const x = if (relative) sample.timestamp - latest_ts else sample.timestamp;
            if (x >= x_domain.min and x <= x_domain.max) count += 1;
        }
    }
    return count;
}

fn computeYDomain(series: []const SeriesDef, x_domain: AxisDomain, relative: bool, y_padding_fraction: f32) ?AxisDomain {
    var min_v: f32 = std.math.inf(f32);
    var max_v: f32 = -std.math.inf(f32);

    for (series) |s| {
        if (s.rhs_history) |_| {
            const pair_len = pairedSeriesLen(s);
            for (0..pair_len) |i| {
                const x = sampleXAtIndex(s.history, i, relative) orelse continue;
                if (x < x_domain.min or x > x_domain.max) continue;
                const v = seriesValueAtIndex(s, i) orelse continue;
                min_v = @min(min_v, v);
                max_v = @max(max_v, v);
            }
            continue;
        }

        const latest_ts = s.history.latestTimestamp() orelse continue;
        for (0..s.history.len) |i| {
            const sample = s.history.sample(i);
            const x = if (relative) sample.timestamp - latest_ts else sample.timestamp;
            if (x < x_domain.min or x > x_domain.max) continue;
            const v = s.history.value(i, s.kind);
            min_v = @min(min_v, v);
            max_v = @max(max_v, v);
        }
    }

    if (!std.math.isFinite(min_v) or !std.math.isFinite(max_v)) return null;
    if (@abs(max_v - min_v) < 1e-6) {
        min_v -= 1;
        max_v += 1;
    }
    const span = max_v - min_v;
    const pad = span * @max(0.0, y_padding_fraction);
    return .{ .min = min_v - pad, .max = max_v + pad };
}

fn drawGrid(chart_rect: rl.Rectangle, x_graduations: usize, y_graduations: usize, style: PlotStyle, min_dim: f32) void {
    const x_count = @max(x_graduations, 1);
    const y_count = @max(y_graduations, 1);
    const thickness = lineThickness(min_dim, style.stroke.grid_ratio);

    var gx: usize = 0;
    while (gx <= x_count) : (gx += 1) {
        const t = @as(f32, @floatFromInt(gx)) / @as(f32, @floatFromInt(x_count));
        const x = chart_rect.x + chart_rect.width * t;
        rl.drawLineEx(.{ .x = x, .y = chart_rect.y }, .{ .x = x, .y = chart_rect.y + chart_rect.height }, thickness, style.palette.grid);
    }

    var gy: usize = 0;
    while (gy <= y_count) : (gy += 1) {
        const t = @as(f32, @floatFromInt(gy)) / @as(f32, @floatFromInt(y_count));
        const y = chart_rect.y + chart_rect.height * t;
        rl.drawLineEx(.{ .x = chart_rect.x, .y = y }, .{ .x = chart_rect.x + chart_rect.width, .y = y }, thickness, style.palette.grid);
    }

    rl.drawRectangleLinesEx(chart_rect, thickness, style.palette.axis);
}

fn drawAxisGraduations(axis: Axis, chart_rect: rl.Rectangle, domain: AxisDomain, axis_options: AxisOptions, style: PlotStyle, min_dim: f32) void {
    const count = @max(axis_options.graduation_count, 1);
    const tick_len = @max(2.0, min_dim * style.layout.tick_length_ratio);
    const tick_font = fontSize(min_dim, style.typography.tick_label_size_ratio, style.typography.min_font_px);

    var i: usize = 0;
    while (i <= count) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const value = lerpF64(domain.min, domain.max, @as(f64, @floatCast(t)));

        switch (axis) {
            .x => {
                const x = chart_rect.x + chart_rect.width * t;
                rl.drawLineEx(.{ .x = x, .y = chart_rect.y + chart_rect.height }, .{ .x = x, .y = chart_rect.y + chart_rect.height + tick_len }, lineThickness(min_dim, style.stroke.grid_ratio), style.palette.axis);
                drawTickValue(value, axis_options.label_format, @intFromFloat(x - 18), @intFromFloat(chart_rect.y + chart_rect.height + tick_len + 2), tick_font, style.palette.tick);
            },
            .y => {
                const y = chart_rect.y + chart_rect.height * (1.0 - t);
                rl.drawLineEx(.{ .x = chart_rect.x - tick_len, .y = y }, .{ .x = chart_rect.x, .y = y }, lineThickness(min_dim, style.stroke.grid_ratio), style.palette.axis);
                drawTickValueRightAligned(
                    value,
                    axis_options.label_format,
                    @intFromFloat(chart_rect.x - tick_len - 4.0),
                    @intFromFloat(y - @as(f32, @floatFromInt(tick_font)) * 0.5),
                    tick_font,
                    style.palette.tick,
                );
            },
        }
    }
}

fn drawAxisLabels(rect: rl.Rectangle, chart_rect: rl.Rectangle, options: PlotOptions, style: PlotStyle, min_dim: f32) void {
    const font = fontSize(min_dim, style.typography.axis_label_size_ratio, style.typography.min_font_px);
    if (options.show_x_axis_label and options.x_axis.label.len > 0) {
        drawTextSlice(options.x_axis.label, @intFromFloat(chart_rect.x + chart_rect.width * 0.45), @intFromFloat(chart_rect.y + chart_rect.height + rect.height * style.layout.axis_label_offset_ratio), font, style.palette.label);
    }
    if (options.show_y_axis_label and options.y_axis.label.len > 0) {
        drawTextSlice(options.y_axis.label, @intFromFloat(chart_rect.x - rect.width * style.layout.axis_label_offset_ratio * 2.5), @intFromFloat(chart_rect.y - @as(f32, @floatFromInt(font))), font, style.palette.label);
    }
}

fn drawSeries(series: []const SeriesDef, chart_rect: rl.Rectangle, x_domain: AxisDomain, y_domain: AxisDomain, relative: bool, style: PlotStyle, min_dim: f32) void {
    beginChartClip(chart_rect);
    defer rl.endScissorMode();

    for (series) |s| {
        if (!s.render_enabled) continue;
        drawOneSeries(s, chart_rect, x_domain, y_domain, relative, style, min_dim);
    }
}

fn drawOneSeries(s: SeriesDef, chart_rect: rl.Rectangle, x_domain: AxisDomain, y_domain: AxisDomain, relative: bool, style: PlotStyle, min_dim: f32) void {
    var prev: ?rl.Vector2 = null;
    const thickness = lineThickness(min_dim, style.stroke.trace_ratio);
    const len = if (s.rhs_history != null) pairedSeriesLen(s) else s.history.len;
    for (0..len) |i| {
        const x_value = sampleXAtIndex(s.history, i, relative) orelse continue;
        if (x_value < x_domain.min or x_value > x_domain.max) continue;

        const x_norm = @as(f32, @floatCast((x_value - x_domain.min) / (x_domain.max - x_domain.min)));
        const value = if (s.rhs_history != null)
            (seriesValueAtIndex(s, i) orelse continue)
        else
            (s.history.value(i, s.kind));
        const y_norm = @as(f32, @floatCast((@as(f64, value) - y_domain.min) / (y_domain.max - y_domain.min)));
        const point = rl.Vector2{
            .x = chart_rect.x + chart_rect.width * clamp01(x_norm),
            .y = chart_rect.y + chart_rect.height * (1.0 - clamp01(y_norm)),
        };
        if (prev) |p| rl.drawLineEx(p, point, thickness, s.color);
        prev = point;
    }
}

fn drawCursorLine(
    chart_rect: rl.Rectangle,
    cursor_x_norm: f32,
    style: PlotStyle,
    min_dim: f32,
) void {
    const t = clamp01(cursor_x_norm);
    const x = chart_rect.x + chart_rect.width * t;
    const thickness = lineThickness(min_dim, style.stroke.cursor_line_ratio);
    rl.drawLineEx(
        .{ .x = x, .y = chart_rect.y },
        .{ .x = x, .y = chart_rect.y + chart_rect.height },
        thickness,
        style.palette.cursor_line,
    );
}

fn drawSidePanel(
    rect: rl.Rectangle,
    series: []const SeriesDef,
    x_domain: AxisDomain,
    relative: bool,
    cursor_x_norm: ?f32,
    show_stats_panel: bool,
    stats_key: ?usize,
    tolerance_state: ?ToleranceState,
    style: PlotStyle,
    min_dim: f32,
) void {
    const panel = computeCursorColumnRect(rect, style.layout);
    rl.drawRectangleRec(panel, style.palette.cursor_panel_fill);

    const cursor_font = fontSize(min_dim, style.typography.cursor_readout_size_ratio, style.typography.min_font_px);
    const stats_font = fontSize(min_dim, style.typography.stats_size_ratio, style.typography.min_font_px);
    const origin_x: i32 = @intFromFloat(panel.x + style.layout.cursor_column_inner_padding_px);
    const origin_y: i32 = @intFromFloat(panel.y + panel.height * style.layout.cursor_readout_offset_ratio);
    const line_gap: i32 = @max(1, @as(i32, @intFromFloat(panel.height * style.layout.cursor_readout_line_gap_ratio)));
    const section_gap: i32 = @max(1, @as(i32, @intFromFloat(panel.height * cfg.plot.stats_section_gap_ratio)));

    var y = origin_y;
    if (tolerance_state) |state| {
        var tol_buf: [64]u8 = undefined;
        const tol_text = std.fmt.bufPrintZ(&tol_buf, "Tolerance: {s}", .{toleranceStateText(state)}) catch return;
        rl.drawText(tol_text, origin_x, y, cursor_font, toleranceStateColor(state, style));
        y += section_gap;
    }

    if (cursor_x_norm) |cursor_x| {
        const x_value = lerpF64(x_domain.min, x_domain.max, @as(f64, @floatCast(clamp01(cursor_x))));
        var time_buf: [64]u8 = undefined;
        const time_text = std.fmt.bufPrintZ(&time_buf, "t={d:.2}s", .{x_value}) catch return;
        rl.drawText(time_text, origin_x, y, cursor_font, style.palette.tick);
        y += line_gap;

        for (series) |s| {
            if (!s.render_enabled) continue;
            var line_buf: [128]u8 = undefined;
            const clear_name = clearSeriesName(s.label);
            if (!s.available) {
                const line = std.fmt.bufPrintZ(&line_buf, "{s}: n/a", .{clear_name}) catch continue;
                rl.drawText(line, origin_x, y, cursor_font, style.palette.empty_text);
                y += line_gap;
                continue;
            }

            const value = sampleAtCursor(s, x_value, x_domain, relative) orelse {
                const line = std.fmt.bufPrintZ(&line_buf, "{s}: n/a", .{clear_name}) catch continue;
                rl.drawText(line, origin_x, y, cursor_font, style.palette.empty_text);
                y += line_gap;
                continue;
            };
            const line = std.fmt.bufPrintZ(&line_buf, "{s}: {d:.2}", .{ clear_name, value }) catch continue;
            rl.drawText(line, origin_x, y, cursor_font, s.color);
            y += line_gap;
        }
        y += section_gap;
    }

    if (!show_stats_panel) return;
    drawStatsPanel(series, origin_x, y, line_gap, x_domain, relative, stats_key, stats_font, style);
}

const SeriesStats = struct {
    min: f32,
    max: f32,
    mean: f64,
    stddev: f64,
    rms: f64,
    count: usize,
};

const ToleranceState = enum {
    na,
    pass,
    warn,
    fail,
};

const max_series_per_plot = cfg.max_hosts + 1;

const StatsCacheEntry = struct {
    valid: bool = false,
    last_update_sec: f64 = -1e9,
    series_count: usize = 0,
    available: [max_series_per_plot]bool = [_]bool{false} ** max_series_per_plot,
    stats: [max_series_per_plot]?SeriesStats = [_]?SeriesStats{null} ** max_series_per_plot,
};

var stats_cache: [cfg.ui.chart_count]StatsCacheEntry = [_]StatsCacheEntry{.{}} ** cfg.ui.chart_count;

fn drawStatsPanel(
    series: []const SeriesDef,
    x: i32,
    start_y: i32,
    line_gap: i32,
    x_domain: AxisDomain,
    relative: bool,
    stats_key: ?usize,
    font: i32,
    style: PlotStyle,
) void {
    const snapshot = getStatsSnapshot(series, x_domain, relative, stats_key);
    var y = start_y;
    for (series, 0..) |s, i| {
        if (!s.render_enabled) continue;
        var line1_buf: [160]u8 = undefined;
        var line2_buf: [160]u8 = undefined;
        const clear_name = clearSeriesName(s.label);
        if (!snapshot.available[i]) {
            const line = std.fmt.bufPrintZ(&line1_buf, "{s}: unavailable", .{clear_name}) catch continue;
            rl.drawText(line, x, y, font, style.palette.empty_text);
            y += line_gap;
            continue;
        }

        const stats = snapshot.stats[i] orelse {
            const line = std.fmt.bufPrintZ(&line1_buf, "{s}: n/a", .{clear_name}) catch continue;
            rl.drawText(line, x, y, font, style.palette.empty_text);
            y += line_gap;
            continue;
        };

        if (s.rhs_history != null) {
            const line = std.fmt.bufPrintZ(&line1_buf, "{s} RMS: {d:.1}", .{ clear_name, stats.rms }) catch continue;
            rl.drawText(line, x, y, font, s.color);
            y += line_gap;
        } else {
            const line1 = std.fmt.bufPrintZ(&line1_buf, "{s} min/max: {d:.0}/{d:.0}", .{ clear_name, stats.min, stats.max }) catch continue;
            rl.drawText(line1, x, y, font, s.color);
            y += line_gap;

            const line2 = std.fmt.bufPrintZ(&line2_buf, "{s} mean/std: {d:.1}/{d:.1}", .{ clear_name, stats.mean, stats.stddev }) catch continue;
            rl.drawText(line2, x, y, font, s.color);
            y += line_gap;
        }
    }
}

fn computeSeriesStats(s: SeriesDef, x_domain: AxisDomain, relative: bool) ?SeriesStats {
    var min_v: f32 = std.math.inf(f32);
    var max_v: f32 = -std.math.inf(f32);
    var sum: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    var count: usize = 0;

    const len = if (s.rhs_history != null) pairedSeriesLen(s) else s.history.len;
    for (0..len) |i| {
        const x = sampleXAtIndex(s.history, i, relative) orelse continue;
        if (x < x_domain.min or x > x_domain.max) continue;
        const v = seriesValueAtIndex(s, i) orelse continue;
        min_v = @min(min_v, v);
        max_v = @max(max_v, v);
        const vf: f64 = v;
        sum += vf;
        sum_sq += vf * vf;
        count += 1;
    }

    if (count == 0) return null;
    const n = @as(f64, @floatFromInt(count));
    const mean = sum / n;
    const variance = @max(0.0, (sum_sq / n) - (mean * mean));
    return .{
        .min = min_v,
        .max = max_v,
        .mean = mean,
        .stddev = @sqrt(variance),
        .rms = @sqrt(sum_sq / n),
        .count = count,
    };
}

fn getStatsSnapshot(series: []const SeriesDef, x_domain: AxisDomain, relative: bool, stats_key: ?usize) StatsCacheEntry {
    const key = stats_key orelse return computeStatsEntry(series, x_domain, relative);
    if (key >= stats_cache.len) return computeStatsEntry(series, x_domain, relative);

    var entry = &stats_cache[key];
    const now = rl.getTime();
    if (!entry.valid or entry.series_count != series.len or (now - entry.last_update_sec) >= cfg.plot.stats_refresh_interval_seconds) {
        entry.* = computeStatsEntry(series, x_domain, relative);
        entry.valid = true;
        entry.last_update_sec = now;
    }
    return entry.*;
}

fn computeStatsEntry(series: []const SeriesDef, x_domain: AxisDomain, relative: bool) StatsCacheEntry {
    var entry: StatsCacheEntry = .{};
    entry.series_count = @min(series.len, max_series_per_plot);
    for (series[0..entry.series_count], 0..) |s, i| {
        entry.available[i] = s.available;
        if (!s.available) {
            entry.stats[i] = null;
            continue;
        }
        entry.stats[i] = computeSeriesStats(s, x_domain, relative);
    }
    return entry;
}

fn clearSeriesName(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "1")) return "IMU 1";
    if (std.mem.eql(u8, label, "2")) return "IMU 2";
    if (std.mem.eql(u8, label, "d")) return "Delta";
    return label;
}

fn evaluateToleranceState(series: []const SeriesDef, x_domain: AxisDomain, relative: bool, tol: ToleranceOptions) ToleranceState {
    if (series.len == 0) return .na;
    if (tol.basis == .stddev) return evaluateToleranceByStdDev(series, x_domain, relative, tol);

    var has_sample = false;
    var state: ToleranceState = .pass;

    for (series) |s| {
        if (!s.available) continue;
        if (tol.mode == .delta_only and s.rhs_history == null) continue;
        if (tol.mode == .all_series or s.rhs_history != null) {
            const len = if (s.rhs_history != null) pairedSeriesLen(s) else s.history.len;
            for (0..len) |i| {
                const x = sampleXAtIndex(s.history, i, relative) orelse continue;
                if (x < x_domain.min or x > x_domain.max) continue;
                const v = if (s.rhs_history != null)
                    (seriesValueAtIndex(s, i) orelse continue)
                else
                    s.history.value(i, s.kind);
                has_sample = true;
                const abs_v = @abs(v);
                if (abs_v > tol.fail_abs) return .fail;
                if (abs_v > tol.warn_abs) state = .warn;
            }
        }
    }
    return if (has_sample) state else .na;
}

fn evaluateToleranceByStdDev(series: []const SeriesDef, x_domain: AxisDomain, relative: bool, tol: ToleranceOptions) ToleranceState {
    var has_sample = false;
    var state: ToleranceState = .pass;

    for (series) |s| {
        if (!s.available) continue;
        if (tol.mode == .delta_only and s.rhs_history == null) continue;
        if (!(tol.mode == .all_series or s.rhs_history != null)) continue;

        const stats = computeSeriesStats(s, x_domain, relative) orelse continue;
        has_sample = true;
        const sigma: f32 = @floatCast(stats.stddev);
        if (sigma > tol.fail_abs) return .fail;
        if (sigma > tol.warn_abs) state = .warn;
    }

    return if (has_sample) state else .na;
}

fn drawToleranceOverlay(
    chart_rect: rl.Rectangle,
    y_domain: AxisDomain,
    tol: ToleranceOptions,
    state: ToleranceState,
    style: PlotStyle,
    min_dim: f32,
) void {
    if (tol.fail_abs <= 0 or tol.warn_abs <= 0) return;
    const warn_abs: f64 = @as(f64, @floatCast(@min(tol.warn_abs, tol.fail_abs)));
    const fail_abs: f64 = @as(f64, @floatCast(@max(tol.warn_abs, tol.fail_abs)));
    const y_min = y_domain.min;
    const y_max = y_domain.max;
    if (y_max <= y_min) return;

    // Filled tolerance zones around 0 for quick scan.
    drawToleranceBand(chart_rect, y_min, y_max, -fail_abs, -warn_abs, style.palette.tolerance_fail_fill);
    drawToleranceBand(chart_rect, y_min, y_max, warn_abs, fail_abs, style.palette.tolerance_fail_fill);
    drawToleranceBand(chart_rect, y_min, y_max, -warn_abs, 0.0, style.palette.tolerance_warn_fill);
    drawToleranceBand(chart_rect, y_min, y_max, 0.0, warn_abs, style.palette.tolerance_warn_fill);

    const line_w = lineThickness(min_dim, style.stroke.grid_ratio);
    drawHorizontalToleranceLine(chart_rect, y_min, y_max, warn_abs, line_w, style.palette.tolerance_warn);
    drawHorizontalToleranceLine(chart_rect, y_min, y_max, -warn_abs, line_w, style.palette.tolerance_warn);
    drawHorizontalToleranceLine(chart_rect, y_min, y_max, fail_abs, line_w, style.palette.tolerance_fail);
    drawHorizontalToleranceLine(chart_rect, y_min, y_max, -fail_abs, line_w, style.palette.tolerance_fail);

    if (state != .na) {
        const border_color = toleranceStateColor(state, style);
        rl.drawRectangleLinesEx(chart_rect, @max(1.0, lineThickness(min_dim, style.stroke.border_ratio) + 0.5), border_color);
    }
}

fn drawToleranceBand(chart_rect: rl.Rectangle, y_min: f64, y_max: f64, band_min: f64, band_max: f64, color: rl.Color) void {
    const lo = @max(y_min, @min(band_min, band_max));
    const hi = @min(y_max, @max(band_min, band_max));
    if (hi <= lo) return;
    const y_top = valueToScreenY(chart_rect, y_min, y_max, hi);
    const y_bottom = valueToScreenY(chart_rect, y_min, y_max, lo);
    rl.drawRectangleRec(.{
        .x = chart_rect.x,
        .y = y_top,
        .width = chart_rect.width,
        .height = @max(1.0, y_bottom - y_top),
    }, color);
}

fn drawHorizontalToleranceLine(chart_rect: rl.Rectangle, y_min: f64, y_max: f64, value: f64, thickness: f32, color: rl.Color) void {
    if (value < y_min or value > y_max) return;
    const y = valueToScreenY(chart_rect, y_min, y_max, value);
    rl.drawLineEx(.{ .x = chart_rect.x, .y = y }, .{ .x = chart_rect.x + chart_rect.width, .y = y }, thickness, color);
}

fn valueToScreenY(chart_rect: rl.Rectangle, y_min: f64, y_max: f64, value: f64) f32 {
    const t = @as(f32, @floatCast((value - y_min) / (y_max - y_min)));
    return chart_rect.y + chart_rect.height * (1.0 - clamp01(t));
}

fn toleranceStateText(state: ToleranceState) []const u8 {
    return switch (state) {
        .na => "N/A",
        .pass => "PASS",
        .warn => "WARN",
        .fail => "FAIL",
    };
}

fn toleranceStateColor(state: ToleranceState, style: PlotStyle) rl.Color {
    return switch (state) {
        .na => style.palette.empty_text,
        .pass => style.palette.tolerance_pass,
        .warn => style.palette.tolerance_warn,
        .fail => style.palette.tolerance_fail,
    };
}

fn sampleAtCursor(s: SeriesDef, x_value: f64, x_domain: AxisDomain, relative: bool) ?f32 {
    return seriesValueAtX(s, x_value, x_domain, relative);
}

fn pairedSeriesLen(s: SeriesDef) usize {
    if (s.rhs_history) |rhs| return @min(s.history.len, rhs.len);
    return s.history.len;
}

fn seriesValueAtIndex(s: SeriesDef, index: usize) ?f32 {
    const lhs = s.history.value(index, s.kind);
    if (s.rhs_history) |rhs| {
        if (index >= rhs.len) return null;
        return lhs - rhs.value(index, s.kind);
    }
    return lhs;
}

fn sampleXAtIndex(history: *const History, logical_index: usize, relative: bool) ?f64 {
    const sample = history.sample(logical_index);
    if (!relative) return sample.timestamp;
    const latest_ts = history.latestTimestamp() orelse return null;
    return sample.timestamp - latest_ts;
}

fn valueNearestX(history: *const History, kind: History.TraceKind, x_value: f64, x_domain: AxisDomain, relative: bool) ?f32 {
    var best: ?f32 = null;
    var best_dist = std.math.inf(f64);

    for (0..history.len) |i| {
        const sx = sampleXAtIndex(history, i, relative) orelse continue;
        if (sx < x_domain.min or sx > x_domain.max) continue;
        const dist = @abs(sx - x_value);
        if (dist < best_dist) {
            best_dist = dist;
            best = history.value(i, kind);
        }
    }
    return best;
}

fn seriesValueAtX(s: SeriesDef, x_value: f64, x_domain: AxisDomain, relative: bool) ?f32 {
    const lhs = valueNearestX(s.history, s.kind, x_value, x_domain, relative) orelse return null;
    if (s.rhs_history) |rhs| {
        const rhs_v = valueNearestX(rhs, s.kind, x_value, x_domain, relative) orelse return null;
        return lhs - rhs_v;
    }
    return lhs;
}

fn drawLegend(rect: rl.Rectangle, series: []const SeriesDef, style: PlotStyle, min_dim: f32) void {
    var visible_count: usize = 0;
    for (series) |s| {
        if (s.render_enabled) visible_count += 1;
    }
    if (visible_count == 0) return;

    const font = fontSize(min_dim, style.typography.legend_size_ratio, style.typography.min_font_px);
    const title_font = fontSize(min_dim, style.typography.title_size_ratio, style.typography.min_font_px);
    const swatch = @max(6, @as(i32, @intFromFloat(@as(f32, @floatFromInt(font)) * 0.8)));
    const gap = rect.width * style.layout.legend_item_gap_ratio;
    const y = rect.y +
        rect.height * (style.layout.title_offset_ratio + style.layout.legend_offset_ratio) +
        @as(f32, @floatFromInt(title_font));

    var total_w: f32 = 0.0;
    var seen: usize = 0;
    for (series) |s| {
        if (!s.render_enabled) continue;
        total_w += @as(f32, @floatFromInt(swatch + 4 + measureTextSlice(s.label, font)));
        seen += 1;
        if (seen < visible_count) total_w += gap;
    }

    const right_pad = rect.width * style.layout.right_padding_ratio;
    var x = rect.x + rect.width - right_pad - total_w;
    if (x < rect.x) x = rect.x;

    for (series) |s| {
        if (!s.render_enabled) continue;
        rl.drawRectangle(@intFromFloat(x), @intFromFloat(y - @as(f32, @floatFromInt(swatch))), swatch, swatch, s.color);
        drawTextSlice(s.label, @intFromFloat(x + @as(f32, @floatFromInt(swatch + 4))), @intFromFloat(y - @as(f32, @floatFromInt(swatch + 2))), font, style.palette.legend_text);
        x += @as(f32, @floatFromInt(swatch)) + 6 + @as(f32, @floatFromInt(measureTextSlice(s.label, font))) + gap;
    }
}

fn drawTickValue(value: f64, format: LabelFormat, x: i32, y: i32, font: i32, color: rl.Color) void {
    var buf: [64]u8 = undefined;
    const text = switch (format) {
        .fixed0 => std.fmt.bufPrintZ(&buf, "{d:.0}", .{value}) catch return,
        .fixed1 => std.fmt.bufPrintZ(&buf, "{d:.1}", .{value}) catch return,
        .fixed2 => std.fmt.bufPrintZ(&buf, "{d:.2}", .{value}) catch return,
    };
    rl.drawText(text, x, y, font, color);
}

fn drawTickValueRightAligned(value: f64, format: LabelFormat, right_x: i32, y: i32, font: i32, color: rl.Color) void {
    var buf: [64]u8 = undefined;
    const text = switch (format) {
        .fixed0 => std.fmt.bufPrintZ(&buf, "{d:.0}", .{value}) catch return,
        .fixed1 => std.fmt.bufPrintZ(&buf, "{d:.1}", .{value}) catch return,
        .fixed2 => std.fmt.bufPrintZ(&buf, "{d:.2}", .{value}) catch return,
    };
    const w = rl.measureText(text, font);
    rl.drawText(text, right_x - w, y, font, color);
}

fn beginChartClip(chart_rect: rl.Rectangle) void {
    rl.beginScissorMode(
        @as(i32, @intFromFloat(@floor(chart_rect.x))),
        @as(i32, @intFromFloat(@floor(chart_rect.y))),
        @max(1, @as(i32, @intFromFloat(@ceil(chart_rect.width)))),
        @max(1, @as(i32, @intFromFloat(@ceil(chart_rect.height)))),
    );
}

fn drawTextSlice(text: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
    rl.drawText(z, x, y, size, color);
}

fn measureTextSlice(text: []const u8, size: i32) i32 {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return 0;
    return rl.measureText(z, size);
}

fn lerpF64(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

fn lineThickness(min_dim: f32, ratio: f32) f32 {
    return @max(1.0, min_dim * ratio);
}

fn fontSize(min_dim: f32, ratio: f32, min_px: i32) i32 {
    return @max(min_px, @as(i32, @intFromFloat(min_dim * ratio)));
}

fn clamp01(v: f32) f32 {
    return @max(0.0, @min(1.0, v));
}

fn rgba(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
