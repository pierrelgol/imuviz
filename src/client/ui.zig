const rl = @import("raylib");
const cfg = @import("config.zig");
const std = @import("std");

pub const UiScale = struct {
    margin: f32,
    gap: f32,
    title_height: f32,
    panel_header_height: f32,
    panel_padding: f32,

    pub fn fromScreen(screen_w: i32, screen_h: i32, policy: ScalePolicy) UiScale {
        const w = @as(f32, @floatFromInt(screen_w));
        const h = @as(f32, @floatFromInt(screen_h));
        const base = @max(policy.base_min, @min(w, h));

        return .{
            .margin = scaled(base, policy.margin_ratio, policy.margin_min),
            .gap = scaled(base, policy.gap_ratio, policy.gap_min),
            .title_height = scaled(base, policy.title_height_ratio, policy.title_height_min),
            .panel_header_height = scaled(base, policy.panel_header_height_ratio, policy.panel_header_height_min),
            .panel_padding = scaled(base, policy.panel_padding_ratio, policy.panel_padding_min),
        };
    }
};

pub const ScalePolicy = struct {
    base_min: f32 = cfg.ui.screen_ref_min,
    margin_ratio: f32 = cfg.ui.margin_ratio,
    margin_min: f32 = cfg.ui.margin_min,
    gap_ratio: f32 = cfg.ui.gap_ratio,
    gap_min: f32 = cfg.ui.gap_min,
    title_height_ratio: f32 = cfg.ui.title_height_ratio,
    title_height_min: f32 = cfg.ui.title_height_min,
    panel_header_height_ratio: f32 = cfg.ui.panel_header_height_ratio,
    panel_header_height_min: f32 = cfg.ui.panel_header_height_min,
    panel_padding_ratio: f32 = cfg.ui.panel_padding_ratio,
    panel_padding_min: f32 = cfg.ui.panel_padding_min,
};

pub const RootLayout = struct {
    title: rl.Rectangle,
    body: rl.Rectangle,
    scale: UiScale,
};

pub const RootLayoutOptions = struct {
    scale_policy: ScalePolicy = .{},
};

pub fn computeRootLayout(screen_w: i32, screen_h: i32, options: RootLayoutOptions) RootLayout {
    const scale = UiScale.fromScreen(screen_w, screen_h, options.scale_policy);
    const margin = scale.margin;

    const screen_rect = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(@max(screen_w, 1))),
        .height = @as(f32, @floatFromInt(@max(screen_h, 1))),
    };

    const title = rl.Rectangle{
        .x = margin,
        .y = margin,
        .width = @max(1.0, screen_rect.width - margin * 2.0),
        .height = @max(1.0, scale.title_height),
    };

    const body_top = title.y + title.height + scale.gap;
    const body = rl.Rectangle{
        .x = margin,
        .y = body_top,
        .width = @max(1.0, screen_rect.width - margin * 2.0),
        .height = @max(1.0, screen_rect.height - body_top - margin),
    };

    return .{ .title = title, .body = body, .scale = scale };
}

pub fn panelRect(body: rl.Rectangle, endpoint_count: usize, index: usize, gap: f32) rl.Rectangle {
    std.debug.assert(gap >= 0.0);
    if (endpoint_count <= 1) return body;
    if (index >= endpoint_count) return .{ .x = body.x, .y = body.y, .width = 0, .height = 0 };

    const count_f = @as(f32, @floatFromInt(endpoint_count));
    const total_gaps = gap * @as(f32, @floatFromInt(endpoint_count - 1));
    const panel_h = @max(1.0, (body.height - total_gaps) / count_f);

    return .{
        .x = body.x,
        .y = body.y + (@as(f32, @floatFromInt(index)) * (panel_h + gap)),
        .width = body.width,
        .height = panel_h,
    };
}

pub const PanelContentLayout = struct {
    scene: rl.Rectangle,
    charts: [cfg.ui.chart_count]rl.Rectangle,
    chart_count: usize,
};

pub const PanelLayoutOptions = struct {
    scene_ratio_wide: f32 = cfg.ui.scene_ratio_wide,
    scene_ratio_narrow: f32 = cfg.ui.scene_ratio_narrow,
    scene_ratio_breakpoint_px: f32 = cfg.ui.scene_ratio_breakpoint_px,
    scene_width_padding_scale: f32 = cfg.ui.scene_width_padding_scale,
    charts_gap_scale: f32 = cfg.ui.charts_gap_scale,
    chart_grid: ChartGridOptions = .{},
};

pub const ChartGridOptions = struct {
    two_column_width_height_ratio: f32 = cfg.ui.charts_two_column_width_height_ratio,
};

pub fn splitDevicePanel(panel: rl.Rectangle, scale: UiScale, options: PanelLayoutOptions) PanelContentLayout {
    const content = contentRect(panel, scale);
    const scene_ratio = chooseSceneRatio(panel.width, options);
    const scene = sceneRect(content, scale, scene_ratio, options.scene_width_padding_scale);
    const charts_area = chartsRect(content, scale, scene_ratio);

    return .{
        .scene = scene,
        .charts = chartGrid(charts_area, cfg.ui.chart_count, scale.panel_padding * options.charts_gap_scale, options.chart_grid),
        .chart_count = cfg.ui.chart_count,
    };
}

fn contentRect(panel: rl.Rectangle, scale: UiScale) rl.Rectangle {
    const y = panel.y + scale.panel_header_height + scale.gap;
    return .{
        .x = panel.x,
        .y = y,
        .width = @max(1.0, panel.width),
        .height = @max(1.0, panel.height - scale.panel_header_height - scale.gap * 2.0),
    };
}

fn chooseSceneRatio(panel_width: f32, options: PanelLayoutOptions) f32 {
    return if (panel_width >= options.scene_ratio_breakpoint_px) options.scene_ratio_wide else options.scene_ratio_narrow;
}

fn sceneRect(content: rl.Rectangle, scale: UiScale, scene_ratio: f32, width_padding_scale: f32) rl.Rectangle {
    const scene_width = content.width * scene_ratio;
    return .{
        .x = content.x + scale.panel_padding,
        .y = content.y + scale.panel_padding,
        .width = @max(1.0, scene_width - scale.panel_padding * width_padding_scale),
        .height = @max(1.0, content.height - scale.panel_padding * 2.0),
    };
}

fn chartsRect(content: rl.Rectangle, scale: UiScale, scene_ratio: f32) rl.Rectangle {
    const scene_width = content.width * scene_ratio;
    const charts_x = content.x + scene_width + scale.panel_padding;
    return .{
        .x = charts_x,
        .y = content.y + scale.panel_padding,
        .width = @max(1.0, content.width - scene_width - scale.panel_padding * 2.0),
        .height = @max(1.0, content.height - scale.panel_padding * 2.0),
    };
}

fn chartGrid(
    area: rl.Rectangle,
    count: usize,
    gap: f32,
    options: ChartGridOptions,
) [cfg.ui.chart_count]rl.Rectangle {
    std.debug.assert(gap >= 0.0);
    var out: [cfg.ui.chart_count]rl.Rectangle = [_]rl.Rectangle{.{ .x = area.x, .y = area.y, .width = 1.0, .height = 1.0 }} ** cfg.ui.chart_count;
    const capped_count = @min(count, out.len);
    if (capped_count == 0) return out;

    const cols: usize = if (area.width > area.height * options.two_column_width_height_ratio) 2 else 1;
    const rows: usize = std.math.divCeil(usize, capped_count, cols) catch unreachable;

    const cols_f = @as(f32, @floatFromInt(cols));
    const rows_f = @as(f32, @floatFromInt(rows));
    const cell_w = @max(1.0, (area.width - gap * @as(f32, @floatFromInt(cols - 1))) / cols_f);
    const cell_h = @max(1.0, (area.height - gap * @as(f32, @floatFromInt(rows - 1))) / rows_f);

    for (0..capped_count) |i| {
        const row = i / cols;
        const col = i % cols;
        out[i] = .{
            .x = area.x + @as(f32, @floatFromInt(col)) * (cell_w + gap),
            .y = area.y + @as(f32, @floatFromInt(row)) * (cell_h + gap),
            .width = cell_w,
            .height = cell_h,
        };
    }

    return out;
}

fn scaled(base: f32, ratio: f32, min_value: f32) f32 {
    return @max(min_value, base * ratio);
}

pub const ComparisonLayout = struct {
    scenes: [cfg.max_hosts]rl.Rectangle,
    scene_count: usize,
    plots: [cfg.ui.chart_count]rl.Rectangle,
    plot_count: usize,
};

pub const ComparisonLayoutOptions = struct {
    scenes_height_ratio_single: f32 = cfg.ui.comparison_scenes_height_ratio_single,
    scenes_height_ratio_multi: f32 = cfg.ui.comparison_scenes_height_ratio_multi,
    scene_gap_scale: f32 = cfg.ui.comparison_scene_gap_scale,
    plot_gap_scale: f32 = cfg.ui.comparison_plot_gap_scale,
    plot_columns: usize = cfg.ui.comparison_plot_columns,
};

pub fn splitComparison(body: rl.Rectangle, scale: UiScale, device_count: usize, options: ComparisonLayoutOptions) ComparisonLayout {
    var result: ComparisonLayout = .{
        .scenes = [_]rl.Rectangle{.{ .x = body.x, .y = body.y, .width = 1.0, .height = 1.0 }} ** cfg.max_hosts,
        .scene_count = @min(device_count, cfg.max_hosts),
        .plots = [_]rl.Rectangle{.{ .x = body.x, .y = body.y, .width = 1.0, .height = 1.0 }} ** cfg.ui.chart_count,
        .plot_count = cfg.ui.chart_count,
    };

    const scene_ratio = if (result.scene_count <= 1) options.scenes_height_ratio_single else options.scenes_height_ratio_multi;
    const scenes_h = @max(1.0, body.height * scene_ratio);
    const scenes_area = rl.Rectangle{
        .x = body.x,
        .y = body.y,
        .width = @max(1.0, body.width),
        .height = scenes_h,
    };
    const plots_area = rl.Rectangle{
        .x = body.x,
        .y = body.y + scenes_h + scale.gap,
        .width = @max(1.0, body.width),
        .height = @max(1.0, body.height - scenes_h - scale.gap),
    };

    result.scenes = horizontalSlices(scenes_area, result.scene_count, scale.gap * options.scene_gap_scale);
    result.plots = fixedGrid(
        plots_area,
        result.plot_count,
        @max(@as(usize, 1), options.plot_columns),
        scale.panel_padding * options.plot_gap_scale,
    );
    return result;
}

fn horizontalSlices(area: rl.Rectangle, count: usize, gap: f32) [cfg.max_hosts]rl.Rectangle {
    std.debug.assert(gap >= 0.0);
    var out: [cfg.max_hosts]rl.Rectangle = [_]rl.Rectangle{.{ .x = area.x, .y = area.y, .width = area.width, .height = area.height }} ** cfg.max_hosts;
    if (count == 0) return out;

    const total_gap = if (count > 1) gap * @as(f32, @floatFromInt(count - 1)) else 0.0;
    const width = @max(1.0, (area.width - total_gap) / @as(f32, @floatFromInt(count)));
    for (0..@min(count, out.len)) |i| {
        out[i] = .{
            .x = area.x + @as(f32, @floatFromInt(i)) * (width + gap),
            .y = area.y,
            .width = width,
            .height = area.height,
        };
    }
    return out;
}

fn fixedGrid(area: rl.Rectangle, count: usize, columns: usize, gap: f32) [cfg.ui.chart_count]rl.Rectangle {
    std.debug.assert(gap >= 0.0);
    var out: [cfg.ui.chart_count]rl.Rectangle = [_]rl.Rectangle{.{ .x = area.x, .y = area.y, .width = 1.0, .height = 1.0 }} ** cfg.ui.chart_count;
    const capped_count = @min(count, out.len);
    if (capped_count == 0) return out;

    const cols = @max(@as(usize, 1), @min(columns, capped_count));
    const rows: usize = std.math.divCeil(usize, capped_count, cols) catch unreachable;
    const cols_f = @as(f32, @floatFromInt(cols));
    const rows_f = @as(f32, @floatFromInt(rows));
    const cell_w = @max(1.0, (area.width - gap * @as(f32, @floatFromInt(cols - 1))) / cols_f);
    const cell_h = @max(1.0, (area.height - gap * @as(f32, @floatFromInt(rows - 1))) / rows_f);

    for (0..capped_count) |i| {
        const row = i / cols;
        const col = i % cols;
        out[i] = .{
            .x = area.x + @as(f32, @floatFromInt(col)) * (cell_w + gap),
            .y = area.y + @as(f32, @floatFromInt(row)) * (cell_h + gap),
            .width = cell_w,
            .height = cell_h,
        };
    }
    return out;
}
