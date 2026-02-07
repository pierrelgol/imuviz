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
};

pub const YDomain = union(enum) {
    dynamic,
    fixed: AxisDomain,
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
    drawAxisGraduations(.x, chart_rect, x_domain, options.x_axis, style, min_dim);
    drawAxisGraduations(.y, chart_rect, y_domain, options.y_axis, style, min_dim);
    drawAxisLabels(rect, chart_rect, options, style, min_dim);

    drawSeries(options.series, chart_rect, x_domain, y_domain, options.x_labels_relative_to_latest, style, min_dim);
    if (options.cursor_x_norm) |cursor_x| {
        drawCursorOverlay(rect, chart_rect, options.series, x_domain, options.x_labels_relative_to_latest, cursor_x, style, min_dim);
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
    const left_pad = rect.width * layout.left_padding_ratio;
    const right_pad = rect.width * layout.right_padding_ratio;
    const top_pad = rect.height * layout.top_padding_ratio;
    const bottom_pad = rect.height * layout.bottom_padding_ratio;
    const column_gap = rect.width * layout.cursor_column_gap_ratio;
    const y_tick_lane = rect.width * layout.y_tick_lane_width_ratio;
    return .{
        .x = rect.x + left_pad + cursor_column.width + column_gap + y_tick_lane,
        .y = rect.y + top_pad,
        .width = @max(1.0, rect.width - left_pad - right_pad - cursor_column.width - column_gap - y_tick_lane),
        .height = @max(1.0, rect.height - top_pad - bottom_pad),
    };
}

fn computeCursorColumnRect(rect: rl.Rectangle, layout: PlotStyle.Layout) rl.Rectangle {
    const left_pad = rect.width * layout.left_padding_ratio;
    const top_pad = rect.height * layout.top_padding_ratio;
    const bottom_pad = rect.height * layout.bottom_padding_ratio;
    const w = @max(1.0, rect.width * layout.cursor_column_width_ratio);
    return .{
        .x = rect.x + left_pad,
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
            for (0..s.history.len) |i| {
                const x = sampleXAtIndex(s.history, i, relative) orelse continue;
                if (x < x_domain.min or x > x_domain.max) continue;
                if (seriesValueAtX(s, x, x_domain, relative) != null) count += 1;
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
            for (0..s.history.len) |i| {
                const x = sampleXAtIndex(s.history, i, relative) orelse continue;
                if (x < x_domain.min or x > x_domain.max) continue;
                const v = seriesValueAtX(s, x, x_domain, relative) orelse continue;
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

    for (series) |s| drawOneSeries(s, chart_rect, x_domain, y_domain, relative, style, min_dim);
}

fn drawOneSeries(s: SeriesDef, chart_rect: rl.Rectangle, x_domain: AxisDomain, y_domain: AxisDomain, relative: bool, style: PlotStyle, min_dim: f32) void {
    var prev: ?rl.Vector2 = null;
    const thickness = lineThickness(min_dim, style.stroke.trace_ratio);
    for (0..s.history.len) |i| {
        const x_value = sampleXAtIndex(s.history, i, relative) orelse continue;
        if (x_value < x_domain.min or x_value > x_domain.max) continue;

        const x_norm = @as(f32, @floatCast((x_value - x_domain.min) / (x_domain.max - x_domain.min)));
        const value = seriesValueAtX(s, x_value, x_domain, relative) orelse continue;
        const y_norm = @as(f32, @floatCast((@as(f64, value) - y_domain.min) / (y_domain.max - y_domain.min)));
        const point = rl.Vector2{
            .x = chart_rect.x + chart_rect.width * clamp01(x_norm),
            .y = chart_rect.y + chart_rect.height * (1.0 - clamp01(y_norm)),
        };
        if (prev) |p| rl.drawLineEx(p, point, thickness, s.color);
        prev = point;
    }
}

fn drawCursorOverlay(
    rect: rl.Rectangle,
    chart_rect: rl.Rectangle,
    series: []const SeriesDef,
    x_domain: AxisDomain,
    relative: bool,
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

    const x_value = lerpF64(x_domain.min, x_domain.max, @as(f64, @floatCast(t)));
    drawCursorReadout(rect, chart_rect, series, x_value, x_domain, relative, style, min_dim);
}

fn drawCursorReadout(
    rect: rl.Rectangle,
    chart_rect: rl.Rectangle,
    series: []const SeriesDef,
    x_value: f64,
    x_domain: AxisDomain,
    relative: bool,
    style: PlotStyle,
    min_dim: f32,
) void {
    const font = fontSize(min_dim, style.typography.cursor_readout_size_ratio, style.typography.min_font_px);
    _ = chart_rect;
    const panel = computeCursorColumnRect(rect, style.layout);
    rl.drawRectangleRec(panel, style.palette.cursor_panel_fill);

    const origin_x: i32 = @intFromFloat(panel.x + style.layout.cursor_column_inner_padding_px);
    const origin_y: i32 = @intFromFloat(panel.y + panel.height * style.layout.cursor_readout_offset_ratio);
    const line_gap: i32 = @max(1, @as(i32, @intFromFloat(panel.height * style.layout.cursor_readout_line_gap_ratio)));

    var time_buf: [64]u8 = undefined;
    const time_text = std.fmt.bufPrintZ(&time_buf, "t={d:.2}s", .{x_value}) catch return;
    rl.drawText(time_text, origin_x, origin_y, font, style.palette.tick);

    for (series, 0..) |s, i| {
        const y = origin_y + @as(i32, @intCast(i + 1)) * line_gap;
        var line_buf: [128]u8 = undefined;
        if (!s.available) {
            const line = std.fmt.bufPrintZ(&line_buf, "{s}: n/a", .{s.label}) catch continue;
            rl.drawText(line, origin_x, y, font, style.palette.empty_text);
            continue;
        }

        const value = sampleAtCursor(s, x_value, x_domain, relative) orelse {
            const line = std.fmt.bufPrintZ(&line_buf, "{s}: n/a", .{s.label}) catch continue;
            rl.drawText(line, origin_x, y, font, style.palette.empty_text);
            continue;
        };
        const line = std.fmt.bufPrintZ(&line_buf, "{s}: {d:.2}", .{ s.label, value }) catch continue;
        rl.drawText(line, origin_x, y, font, s.color);
    }
}

fn sampleAtCursor(s: SeriesDef, x_value: f64, x_domain: AxisDomain, relative: bool) ?f32 {
    return seriesValueAtX(s, x_value, x_domain, relative);
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
    if (series.len == 0) return;

    const font = fontSize(min_dim, style.typography.legend_size_ratio, style.typography.min_font_px);
    const title_font = fontSize(min_dim, style.typography.title_size_ratio, style.typography.min_font_px);
    const swatch = @max(6, @as(i32, @intFromFloat(@as(f32, @floatFromInt(font)) * 0.8)));
    const gap = rect.width * style.layout.legend_item_gap_ratio;
    const y = rect.y +
        rect.height * (style.layout.title_offset_ratio + style.layout.legend_offset_ratio) +
        @as(f32, @floatFromInt(title_font));

    var total_w: f32 = 0.0;
    for (series, 0..) |s, i| {
        total_w += @as(f32, @floatFromInt(swatch + 4 + measureTextSlice(s.label, font)));
        if (i + 1 < series.len) total_w += gap;
    }

    const right_pad = rect.width * style.layout.right_padding_ratio;
    var x = rect.x + rect.width - right_pad - total_w;
    if (x < rect.x) x = rect.x;

    for (series) |s| {
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
