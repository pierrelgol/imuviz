const rl = @import("raylib");

pub const UiScale = struct {
    margin: f32,
    gap: f32,
    title_height: f32,
    panel_header_height: f32,
    panel_padding: f32,

    pub fn fromScreen(screen_w: i32, screen_h: i32) UiScale {
        const w = @as(f32, @floatFromInt(screen_w));
        const h = @as(f32, @floatFromInt(screen_h));
        const base = @min(w, h);

        return .{
            .margin = @max(10.0, base * 0.010),
            .gap = @max(8.0, base * 0.008),
            .title_height = @max(34.0, base * 0.030),
            .panel_header_height = @max(28.0, base * 0.028),
            .panel_padding = @max(5.0, base * 0.006),
        };
    }
};

pub const RootLayout = struct {
    title: rl.Rectangle,
    body: rl.Rectangle,
    scale: UiScale,
};

pub fn computeRootLayout(screen_w: i32, screen_h: i32) RootLayout {
    const scale = UiScale.fromScreen(screen_w, screen_h);
    const margin = scale.margin;

    const title = rl.Rectangle{
        .x = margin,
        .y = margin,
        .width = @as(f32, @floatFromInt(screen_w)) - margin * 2.0,
        .height = scale.title_height,
    };

    const body_top = title.y + title.height + scale.gap;
    const body = rl.Rectangle{
        .x = margin,
        .y = body_top,
        .width = @as(f32, @floatFromInt(screen_w)) - margin * 2.0,
        .height = @as(f32, @floatFromInt(screen_h)) - body_top - margin,
    };

    return .{ .title = title, .body = body, .scale = scale };
}

pub fn panelRect(body: rl.Rectangle, endpoint_count: usize, index: usize, gap: f32) rl.Rectangle {
    if (endpoint_count <= 1) return body;

    const count_f = @as(f32, @floatFromInt(endpoint_count));
    const total_gaps = gap * @as(f32, @floatFromInt(endpoint_count - 1));
    const panel_h = (body.height - total_gaps) / count_f;

    return .{
        .x = body.x,
        .y = body.y + (@as(f32, @floatFromInt(index)) * (panel_h + gap)),
        .width = body.width,
        .height = panel_h,
    };
}

pub const PanelContentLayout = struct {
    scene: rl.Rectangle,
    charts: [6]rl.Rectangle,
    chart_count: usize,
};

pub fn splitDevicePanel(panel: rl.Rectangle, scale: UiScale) PanelContentLayout {
    const content_y = panel.y + scale.panel_header_height + scale.gap;
    const content_h = panel.height - scale.panel_header_height - scale.gap * 2.0;

    const scene_ratio: f32 = if (panel.width >= 1400) 0.34 else 0.30;
    const scene_width = panel.width * scene_ratio;

    const scene = rl.Rectangle{
        .x = panel.x + scale.panel_padding,
        .y = content_y + scale.panel_padding,
        .width = scene_width - scale.panel_padding * 1.5,
        .height = content_h - scale.panel_padding * 2.0,
    };

    const charts_x = panel.x + scene_width + scale.panel_padding;
    const charts_w = panel.width - scene_width - scale.panel_padding * 2.0;
    const charts_area = rl.Rectangle{
        .x = charts_x,
        .y = content_y + scale.panel_padding,
        .width = charts_w,
        .height = content_h - scale.panel_padding * 2.0,
    };

    return .{
        .scene = scene,
        .charts = chartGrid(charts_area, 6, scale.panel_padding * 0.7),
        .chart_count = 6,
    };
}

fn chartGrid(area: rl.Rectangle, count: usize, gap: f32) [6]rl.Rectangle {
    var out: [6]rl.Rectangle = undefined;
    const cols: usize = if (area.width > area.height * 0.9) 2 else 1;
    const rows: usize = @divFloor(count + cols - 1, cols);

    const cols_f = @as(f32, @floatFromInt(cols));
    const rows_f = @as(f32, @floatFromInt(rows));
    const cell_w = (area.width - gap * @as(f32, @floatFromInt(cols - 1))) / cols_f;
    const cell_h = (area.height - gap * @as(f32, @floatFromInt(rows - 1))) / rows_f;

    for (0..count) |i| {
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
