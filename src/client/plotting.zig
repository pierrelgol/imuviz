const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const History = @import("history.zig").History;

pub const TraceDef = struct {
    kind: History.TraceKind,
    name: []const u8,
    color: rl.Color,
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
    traces: []const TraceDef,
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
    };

    pub const Typography = struct {
        title_size_ratio: f32 = cfg.plot.title_size_ratio,
        axis_label_size_ratio: f32 = cfg.plot.axis_label_size_ratio,
        tick_label_size_ratio: f32 = cfg.plot.tick_label_size_ratio,
        legend_size_ratio: f32 = cfg.plot.legend_size_ratio,
        empty_size_ratio: f32 = cfg.plot.empty_size_ratio,
        min_font_px: i32 = cfg.plot.min_font_px,
    };

    pub const Stroke = struct {
        border_ratio: f32 = cfg.plot.border_ratio,
        grid_ratio: f32 = cfg.plot.grid_ratio,
        trace_ratio: f32 = cfg.plot.trace_ratio,
    };
};

pub fn drawPlot(rect: rl.Rectangle, history: *const History, options: PlotOptions, style: PlotStyle) void {
    drawFrame(rect, style);

    const chart_rect = computeChartRect(rect, style.layout);
    const min_dim = @min(rect.width, rect.height);

    drawPlotTitle(rect, options.title, style, min_dim);

    if (chart_rect.width <= 1 or chart_rect.height <= 1 or history.len < options.min_samples or options.x_window_seconds <= 0 or options.traces.len == 0) {
        drawEmptyState(chart_rect, options.empty_message, style, min_dim);
        return;
    }

    const latest_t = history.latestTimestamp() orelse {
        drawEmptyState(chart_rect, options.empty_message, style, min_dim);
        return;
    };

    const x_domain: AxisDomain = .{ .min = latest_t - options.x_window_seconds, .max = latest_t };
    const range = history.rangeByTimestamp(x_domain.min, x_domain.max);
    if (range.isEmpty()) {
        drawEmptyState(chart_rect, options.empty_message, style, min_dim);
        return;
    }

    const y_domain = switch (options.y_domain) {
        .dynamic => computeYDomain(history, range, options.traces, cfg.plot.y_padding_fraction) orelse {
            drawEmptyState(chart_rect, options.empty_message, style, min_dim);
            return;
        },
        .fixed => |domain| domain,
    };

    drawGrid(chart_rect, options.x_axis.graduation_count, options.y_axis.graduation_count, style, min_dim);
    drawAxisGraduations(.x, chart_rect, x_domain, options.x_axis, style, min_dim, if (options.x_labels_relative_to_latest) x_domain.max else null);
    drawAxisGraduations(.y, chart_rect, y_domain, options.y_axis, style, min_dim, null);
    drawAxisLabels(rect, chart_rect, options, style, min_dim);

    drawTraces(history, range, options.traces, chart_rect, x_domain, y_domain, style, min_dim);

    if (options.show_legend) {
        drawLegend(rect, options.traces, style, min_dim);
    }
}

pub fn drawAxisGraduations(axis: Axis, chart_rect: rl.Rectangle, domain: AxisDomain, axis_options: AxisOptions, style: PlotStyle, min_dim: f32, x_relative_origin: ?f64) void {
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
                const display = if (x_relative_origin) |origin| value - origin else value;
                drawTickValue(display, axis_options.label_format, @intFromFloat(x - 18), @intFromFloat(chart_rect.y + chart_rect.height + tick_len + 2), tick_font, style.palette.tick);
            },
            .y => {
                const y = chart_rect.y + chart_rect.height * (1.0 - t);
                rl.drawLineEx(.{ .x = chart_rect.x - tick_len, .y = y }, .{ .x = chart_rect.x, .y = y }, lineThickness(min_dim, style.stroke.grid_ratio), style.palette.axis);
                drawTickValue(value, axis_options.label_format, @intFromFloat(chart_rect.x - tick_len - 44), @intFromFloat(y - @as(f32, @floatFromInt(tick_font)) * 0.5), tick_font, style.palette.tick);
            },
        }
    }
}

const Axis = enum {
    x,
    y,
};

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
    const left_pad = rect.width * layout.left_padding_ratio;
    const right_pad = rect.width * layout.right_padding_ratio;
    const top_pad = rect.height * layout.top_padding_ratio;
    const bottom_pad = rect.height * layout.bottom_padding_ratio;

    return .{
        .x = rect.x + left_pad,
        .y = rect.y + top_pad,
        .width = @max(1.0, rect.width - left_pad - right_pad),
        .height = @max(1.0, rect.height - top_pad - bottom_pad),
    };
}

fn drawPlotTitle(rect: rl.Rectangle, title: []const u8, style: PlotStyle, min_dim: f32) void {
    const title_font = fontSize(min_dim, style.typography.title_size_ratio, style.typography.min_font_px);
    const y = rect.y + rect.height * style.layout.title_offset_ratio;
    const title_w = measureTextSlice(title, title_font);
    const centered_x = rect.x + (rect.width - @as(f32, @floatFromInt(title_w))) * 0.5;
    drawTextSlice(title, @intFromFloat(centered_x), @intFromFloat(y), title_font, style.palette.title);
}

fn drawEmptyState(chart_rect: rl.Rectangle, text: []const u8, style: PlotStyle, min_dim: f32) void {
    const font = fontSize(min_dim, style.typography.empty_size_ratio, style.typography.min_font_px);
    drawTextSlice(text, @intFromFloat(chart_rect.x + chart_rect.width * 0.03), @intFromFloat(chart_rect.y + chart_rect.height * 0.5), font, style.palette.empty_text);
}

fn computeYDomain(history: *const History, range: History.LogicalRange, traces: []const TraceDef, y_padding_fraction: f32) ?AxisDomain {
    var min_v: f32 = std.math.inf(f32);
    var max_v: f32 = -std.math.inf(f32);

    for (range.start..range.end) |logical_index| {
        for (traces) |trace| {
            const v = history.value(logical_index, trace.kind);
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

    return .{
        .min = min_v - pad,
        .max = max_v + pad,
    };
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

fn drawAxisLabels(rect: rl.Rectangle, chart_rect: rl.Rectangle, options: PlotOptions, style: PlotStyle, min_dim: f32) void {
    const font = fontSize(min_dim, style.typography.axis_label_size_ratio, style.typography.min_font_px);
    if (options.show_x_axis_label and options.x_axis.label.len > 0) {
        const x_y = chart_rect.y + chart_rect.height + rect.height * style.layout.axis_label_offset_ratio;
        const x_x = chart_rect.x + chart_rect.width * 0.45;
        drawTextSlice(options.x_axis.label, @intFromFloat(x_x), @intFromFloat(x_y), font, style.palette.label);
    }

    if (options.show_y_axis_label and options.y_axis.label.len > 0) {
        const y_x = chart_rect.x - rect.width * style.layout.axis_label_offset_ratio * 2.5;
        const y_y = chart_rect.y - @as(f32, @floatFromInt(font));
        drawTextSlice(options.y_axis.label, @intFromFloat(y_x), @intFromFloat(y_y), font, style.palette.label);
    }
}

fn drawTraces(history: *const History, range: History.LogicalRange, traces: []const TraceDef, chart_rect: rl.Rectangle, x_domain: AxisDomain, y_domain: AxisDomain, style: PlotStyle, min_dim: f32) void {
    beginChartClip(chart_rect);
    defer rl.endScissorMode();

    for (traces) |trace| {
        drawTrace(history, range, trace, chart_rect, x_domain, y_domain, style, min_dim);
    }
}

fn drawTrace(history: *const History, range: History.LogicalRange, trace: TraceDef, chart_rect: rl.Rectangle, x_domain: AxisDomain, y_domain: AxisDomain, style: PlotStyle, min_dim: f32) void {
    var prev: ?rl.Vector2 = null;
    const thickness = lineThickness(min_dim, style.stroke.trace_ratio);

    for (range.start..range.end) |logical_index| {
        const s = history.sample(logical_index);

        const x_norm = @as(f32, @floatCast((s.timestamp - x_domain.min) / (x_domain.max - x_domain.min)));
        const value = history.value(logical_index, trace.kind);
        const y_norm = @as(f32, @floatCast((@as(f64, value) - y_domain.min) / (y_domain.max - y_domain.min)));

        const point = rl.Vector2{
            .x = chart_rect.x + chart_rect.width * clamp01(x_norm),
            .y = chart_rect.y + chart_rect.height * (1.0 - clamp01(y_norm)),
        };

        if (prev) |last| {
            rl.drawLineEx(last, point, thickness, trace.color);
        }
        prev = point;
    }
}

fn beginChartClip(chart_rect: rl.Rectangle) void {
    const x = @as(i32, @intFromFloat(@floor(chart_rect.x)));
    const y = @as(i32, @intFromFloat(@floor(chart_rect.y)));
    const w = @max(1, @as(i32, @intFromFloat(@ceil(chart_rect.width))));
    const h = @max(1, @as(i32, @intFromFloat(@ceil(chart_rect.height))));
    rl.beginScissorMode(x, y, w, h);
}

fn drawLegend(rect: rl.Rectangle, traces: []const TraceDef, style: PlotStyle, min_dim: f32) void {
    const font = fontSize(min_dim, style.typography.legend_size_ratio, style.typography.min_font_px);
    const swatch_size = @max(6, @as(i32, @intFromFloat(@as(f32, @floatFromInt(font)) * 0.8)));
    const y = rect.y + rect.height - rect.height * style.layout.legend_offset_ratio;
    var x = rect.x + rect.width * 0.02;

    const gap = rect.width * style.layout.legend_item_gap_ratio;
    for (traces) |trace| {
        rl.drawRectangle(@intFromFloat(x), @intFromFloat(y - @as(f32, @floatFromInt(swatch_size))), swatch_size, swatch_size, trace.color);
        drawTextSlice(trace.name, @intFromFloat(x + @as(f32, @floatFromInt(swatch_size + 4))), @intFromFloat(y - @as(f32, @floatFromInt(swatch_size + 2))), font, style.palette.legend_text);

        const name_px = @as(f32, @floatFromInt(measureTextSlice(trace.name, font)));
        x += @as(f32, @floatFromInt(swatch_size)) + 6 + name_px + gap;
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
