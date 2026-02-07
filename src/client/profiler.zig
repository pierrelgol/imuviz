const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const cfg = @import("config.zig");

pub const Metrics = struct {
    frame_ms: f32 = 0.0,
    input_ms: f32 = 0.0,
    drain_ms: f32 = 0.0,
    snapshot_ms: f32 = 0.0,
    settings_ms: f32 = 0.0,
    renderer_total_ms: f32 = 0.0,
    renderer_prepare_ms: f32 = 0.0,
    renderer_title_ms: f32 = 0.0,
    renderer_scenes_ms: f32 = 0.0,
    renderer_plots_ms: f32 = 0.0,
    menu_draw_ms: f32 = 0.0,
};

pub const NetworkEndpointSample = struct {
    rx_bytes_total: u64,
    ping_rtt_ms: f32,
};

pub const Overlay = struct {
    key_prev_down: bool = false,
    has_smoothed: bool = false,
    smoothed: Metrics = .{},
    memory_samples: [cfg.profiler.memory_samples]u64 = [_]u64{0} ** cfg.profiler.memory_samples,
    memory_len: usize = 0,
    memory_head: usize = 0,
    memory_max_seen: u64 = 0,
    last_memory_sample_ms: f64 = -1e12,
    timing_samples: [timing_series_count][cfg.profiler.memory_samples]f32 = [_][cfg.profiler.memory_samples]f32{[_]f32{0.0} ** cfg.profiler.memory_samples} ** timing_series_count,
    timing_len: usize = 0,
    timing_head: usize = 0,
    net_device_count: usize = 0,
    net_last_sample_ms: f64 = -1e12,
    net_last_rx_bytes: [cfg.max_hosts]u64 = [_]u64{0} ** cfg.max_hosts,
    net_throughput_kbps: [cfg.max_hosts][cfg.profiler.memory_samples]f32 = [_][cfg.profiler.memory_samples]f32{[_]f32{0.0} ** cfg.profiler.memory_samples} ** cfg.max_hosts,
    net_latency_ms: [cfg.max_hosts][cfg.profiler.memory_samples]f32 = [_][cfg.profiler.memory_samples]f32{[_]f32{0.0} ** cfg.profiler.memory_samples} ** cfg.max_hosts,
    net_len: usize = 0,
    net_head: usize = 0,

    pub fn updateToggle(self: *Overlay, visible: *bool) void {
        const key_down = rl.isKeyDown(cfg.profiler.toggle_key);
        const key_toggled = key_down and !self.key_prev_down;
        self.key_prev_down = key_down;
        if (key_toggled) visible.* = !visible.*;
    }

    pub fn push(self: *Overlay, sample: Metrics) void {
        if (!self.has_smoothed) {
            self.smoothed = sample;
            self.has_smoothed = true;
            return;
        }
        const a = @max(0.0, @min(1.0, cfg.profiler.smoothing_alpha));
        self.smoothed = blend(self.smoothed, sample, a);
        pushTimingSample(self, sample);
    }

    pub fn sampleMemory(self: *Overlay, io: std.Io) void {
        const now_ms = rl.getTime() * 1000.0;
        if ((now_ms - self.last_memory_sample_ms) < cfg.profiler.memory_poll_interval_ms) return;
        self.last_memory_sample_ms = now_ms;

        const bytes = currentMemoryBytes(io) orelse return;
        self.memory_samples[self.memory_head] = bytes;
        self.memory_head = (self.memory_head + 1) % self.memory_samples.len;
        if (self.memory_len < self.memory_samples.len) self.memory_len += 1;
        if (bytes > self.memory_max_seen) self.memory_max_seen = bytes;
    }

    pub fn pushNetwork(self: *Overlay, samples: []const NetworkEndpointSample) void {
        const count = @min(samples.len, cfg.max_hosts);
        self.net_device_count = count;
        const now_ms = rl.getTime() * 1000.0;
        const dt_ms = if (self.net_last_sample_ms > 0.0) @max(1.0, @as(f32, @floatCast(now_ms - self.net_last_sample_ms))) else 0.0;
        self.net_last_sample_ms = now_ms;

        for (0..count) |i| {
            const total = samples[i].rx_bytes_total;
            const delta = total -| self.net_last_rx_bytes[i];
            const kbps: f32 = if (dt_ms > 0.0) (@as(f32, @floatFromInt(delta)) * 1000.0 / dt_ms) / 1024.0 else 0.0;
            self.net_throughput_kbps[i][self.net_head] = kbps;
            self.net_latency_ms[i][self.net_head] = @max(0.0, samples[i].ping_rtt_ms);
            self.net_last_rx_bytes[i] = total;
        }
        for (count..cfg.max_hosts) |i| {
            self.net_throughput_kbps[i][self.net_head] = 0.0;
            self.net_latency_ms[i][self.net_head] = 0.0;
            self.net_last_rx_bytes[i] = 0;
        }
        self.net_head = (self.net_head + 1) % cfg.profiler.memory_samples;
        if (self.net_len < cfg.profiler.memory_samples) self.net_len += 1;
    }

    pub fn draw(self: *const Overlay, visible: bool, target_fps: i32) void {
        if (!visible or !self.has_smoothed) return;
        const panel = panelRect();
        rl.drawRectangleRec(panel, cfg.profiler.panel_fill);
        rl.drawRectangleLinesEx(panel, 1.0, cfg.profiler.panel_border);

        const budget_ms = if (target_fps > 0) 1000.0 / @as(f32, @floatFromInt(target_fps)) else 0.0;
        var y = panel.y + cfg.profiler.panel_padding;

        drawLine(panel.x + cfg.profiler.panel_padding, y, "Perf Overlay [d]", self.smoothed.frame_ms, budget_ms, true);
        y += cfg.profiler.panel_line_gap;
        drawTimingGraph(self, panel, y, budget_ms);
        y += cfg.profiler.timing_graph_height;
        y += cfg.profiler.panel_line_gap + cfg.profiler.graph_top_gap;

        drawMemoryGraph(self, panel, y);
        y += cfg.profiler.graph_height + cfg.profiler.network_graph_gap;
        drawNetworkThroughputGraph(self, panel, y);
        y += cfg.profiler.network_graph_height + cfg.profiler.network_graph_split_gap;
        drawNetworkLatencyGraph(self, panel, y);
    }
};

fn panelRect() rl.Rectangle {
    return .{
        .x = cfg.profiler.panel_x,
        .y = cfg.profiler.panel_y,
        .width = cfg.profiler.panel_width,
        .height = cfg.profiler.panel_padding * 2.0 +
            cfg.profiler.panel_line_gap * 3.0 +
            cfg.profiler.timing_graph_height +
            cfg.profiler.graph_top_gap +
            cfg.profiler.graph_height +
            cfg.profiler.network_graph_gap +
            cfg.profiler.network_graph_height +
            cfg.profiler.network_graph_split_gap +
            cfg.profiler.network_graph_height,
    };
}

fn drawLine(x: f32, y: f32, label: []const u8, ms: f32, budget_ms: f32, title: bool) void {
    const color = if (title) cfg.theme.text_primary else timeColor(ms, budget_ms);
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{s:<16} {d:>6.2} ms", .{ label, ms }) catch return;
    rl.drawText(
        text,
        @intFromFloat(x),
        @intFromFloat(y),
        if (title) cfg.profiler.panel_title_size else cfg.profiler.panel_text_size,
        color,
    );
}

fn timeColor(ms: f32, budget_ms: f32) rl.Color {
    if (budget_ms <= 0.0) return cfg.profiler.text_muted;
    if (ms <= budget_ms * cfg.profiler.good_ratio) return cfg.profiler.text_good;
    if (ms <= budget_ms * cfg.profiler.warn_ratio) return cfg.profiler.text_warn;
    return cfg.profiler.text_bad;
}

fn blend(a: Metrics, b: Metrics, alpha: f32) Metrics {
    return .{
        .frame_ms = lerp(a.frame_ms, b.frame_ms, alpha),
        .input_ms = lerp(a.input_ms, b.input_ms, alpha),
        .drain_ms = lerp(a.drain_ms, b.drain_ms, alpha),
        .snapshot_ms = lerp(a.snapshot_ms, b.snapshot_ms, alpha),
        .settings_ms = lerp(a.settings_ms, b.settings_ms, alpha),
        .renderer_total_ms = lerp(a.renderer_total_ms, b.renderer_total_ms, alpha),
        .renderer_prepare_ms = lerp(a.renderer_prepare_ms, b.renderer_prepare_ms, alpha),
        .renderer_title_ms = lerp(a.renderer_title_ms, b.renderer_title_ms, alpha),
        .renderer_scenes_ms = lerp(a.renderer_scenes_ms, b.renderer_scenes_ms, alpha),
        .renderer_plots_ms = lerp(a.renderer_plots_ms, b.renderer_plots_ms, alpha),
        .menu_draw_ms = lerp(a.menu_draw_ms, b.menu_draw_ms, alpha),
    };
}

fn lerp(a: f32, b: f32, alpha: f32) f32 {
    return a + (b - a) * alpha;
}

const timing_series_count: usize = 5;

fn pushTimingSample(self: *Overlay, sample: Metrics) void {
    self.timing_samples[0][self.timing_head] = sample.frame_ms;
    self.timing_samples[1][self.timing_head] = sample.input_ms;
    self.timing_samples[2][self.timing_head] = sample.drain_ms;
    self.timing_samples[3][self.timing_head] = sample.renderer_total_ms;
    self.timing_samples[4][self.timing_head] = sample.menu_draw_ms;

    self.timing_head = (self.timing_head + 1) % cfg.profiler.memory_samples;
    if (self.timing_len < cfg.profiler.memory_samples) self.timing_len += 1;
}

fn drawTimingGraph(self: *const Overlay, panel: rl.Rectangle, y: f32, budget_ms: f32) void {
    const graph = rl.Rectangle{
        .x = panel.x + cfg.profiler.panel_padding,
        .y = y,
        .width = panel.width - cfg.profiler.panel_padding * 2.0,
        .height = cfg.profiler.timing_graph_height,
    };
    rl.drawRectangleRec(graph, cfg.profiler.graph_fill);
    rl.drawRectangleLinesEx(graph, 1.0, cfg.profiler.graph_border);
    const plot = graphPlotRect(graph);

    var max_ms: f32 = @max(1.0, budget_ms * 1.25);
    if (self.timing_len >= 2) {
        for (0..timing_series_count) |s| {
            for (0..self.timing_len) |i| {
                const idx = (self.timing_head + cfg.profiler.memory_samples - self.timing_len + i) % cfg.profiler.memory_samples;
                max_ms = @max(max_ms, self.timing_samples[s][idx]);
            }
        }
    }
    drawGraphGridAndAxes(graph, plot, max_ms, "ms");
    drawTimingLegend(plot);
    if (self.timing_len < 2) return;

    if (budget_ms > 0.0) {
        const by = plot.y + plot.height * (1.0 - @min(1.0, budget_ms / max_ms));
        rl.drawLineEx(.{ .x = plot.x, .y = by }, .{ .x = plot.x + plot.width, .y = by }, 1.0, cfg.profiler.budget_line);
    }

    drawTimingSeries(self, plot, max_ms, 0, cfg.profiler.frame_line);
    drawTimingSeries(self, plot, max_ms, 1, cfg.profiler.input_line);
    drawTimingSeries(self, plot, max_ms, 2, cfg.profiler.drain_line);
    drawTimingSeries(self, plot, max_ms, 3, cfg.profiler.renderer_line);
    drawTimingSeries(self, plot, max_ms, 4, cfg.profiler.menu_line);
}

fn drawTimingLegend(plot: rl.Rectangle) void {
    const y = plot.y - cfg.profiler.legend_y_offset;
    const x0 = plot.x + cfg.profiler.legend_x_start;
    drawLegendEntry(x0 + cfg.profiler.legend_item_gap * 0.0, y, "frame", cfg.profiler.frame_line);
    drawLegendEntry(x0 + cfg.profiler.legend_item_gap * 1.0, y, "input", cfg.profiler.input_line);
    drawLegendEntry(x0 + cfg.profiler.legend_item_gap * 2.0, y, "drain", cfg.profiler.drain_line);
    drawLegendEntry(x0 + cfg.profiler.legend_item_gap * 3.0, y, "render", cfg.profiler.renderer_line);
    drawLegendEntry(x0 + cfg.profiler.legend_item_gap * 4.0, y, "menu", cfg.profiler.menu_line);
}

fn drawLegendEntry(x: f32, y: f32, text: []const u8, color: rl.Color) void {
    rl.drawRectangle(@intFromFloat(x), @intFromFloat(y + 2.0), 6, 6, color);
    var buf: [48]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
    rl.drawText(z, @intFromFloat(x + 9.0), @intFromFloat(y), cfg.profiler.panel_text_size, cfg.profiler.text_muted);
}

fn drawTimingSeries(self: *const Overlay, plot: rl.Rectangle, max_ms: f32, series_idx: usize, color: rl.Color) void {
    var prev: ?rl.Vector2 = null;
    const denom = @as(f32, @floatFromInt(@max(self.timing_len - 1, 1)));
    for (0..self.timing_len) |i| {
        const ring_idx = (self.timing_head + cfg.profiler.memory_samples - self.timing_len + i) % cfg.profiler.memory_samples;
        const ms = self.timing_samples[series_idx][ring_idx];
        const x_norm = @as(f32, @floatFromInt(i)) / denom;
        const y_norm = @min(1.0, @max(0.0, ms / max_ms));
        const p: rl.Vector2 = .{
            .x = plot.x + plot.width * x_norm,
            .y = plot.y + plot.height * (1.0 - y_norm),
        };
        if (prev) |q| rl.drawLineEx(q, p, 1.0, color);
        prev = p;
    }
}

fn drawMemoryGraph(self: *const Overlay, panel: rl.Rectangle, y: f32) void {
    const graph = rl.Rectangle{
        .x = panel.x + cfg.profiler.panel_padding,
        .y = y,
        .width = panel.width - cfg.profiler.panel_padding * 2.0,
        .height = cfg.profiler.graph_height,
    };
    rl.drawRectangleRec(graph, cfg.profiler.graph_fill);
    rl.drawRectangleLinesEx(graph, 1.0, cfg.profiler.graph_border);
    const plot = graphPlotRect(graph);

    const max_mb = bytesToMb(@max(self.memory_max_seen, 1));
    drawGraphGridAndAxes(graph, plot, @floatCast(max_mb), "MB");

    var label_buf: [128]u8 = undefined;
    const latest = latestMemoryBytes(self) orelse 0;
    const label = std.fmt.bufPrintZ(
        &label_buf,
        "mem rss: {d:.1} MB (max {d:.1} MB)",
        .{ bytesToMb(latest), bytesToMb(self.memory_max_seen) },
    ) catch return;
    rl.drawText(
        label,
        @intFromFloat(plot.x + 4.0),
        @intFromFloat(graph.y + 2.0),
        cfg.profiler.panel_text_size,
        cfg.profiler.text_muted,
    );

    if (self.memory_len < 2 or self.memory_max_seen == 0) return;

    const denom = @as(f32, @floatFromInt(@max(self.memory_len - 1, 1)));

    var prev: ?rl.Vector2 = null;
    for (0..self.memory_len) |i| {
        const idx = (self.memory_head + self.memory_samples.len - self.memory_len + i) % self.memory_samples.len;
        const mem = self.memory_samples[idx];
        const x_norm = @as(f32, @floatFromInt(i)) / denom;
        const y_norm = @as(f32, @floatFromInt(mem)) / @as(f32, @floatFromInt(self.memory_max_seen));
        const p: rl.Vector2 = .{
            .x = plot.x + plot.width * x_norm,
            .y = plot.y + plot.height * (1.0 - @max(0.0, @min(1.0, y_norm))),
        };
        if (prev) |q| rl.drawLineEx(q, p, 1.0, cfg.profiler.graph_line);
        prev = p;
    }
}

fn drawNetworkThroughputGraph(self: *const Overlay, panel: rl.Rectangle, y: f32) void {
    const graph = rl.Rectangle{
        .x = panel.x + cfg.profiler.panel_padding,
        .y = y,
        .width = panel.width - cfg.profiler.panel_padding * 2.0,
        .height = cfg.profiler.network_graph_height,
    };
    rl.drawRectangleRec(graph, cfg.profiler.graph_fill);
    rl.drawRectangleLinesEx(graph, 1.0, cfg.profiler.graph_border);
    const plot = graphPlotRect(graph);
    var max_kbps: f32 = 1.0;
    if (self.net_len >= 2 and self.net_device_count > 0) {
        for (0..self.net_device_count) |d| {
            for (0..self.net_len) |i| {
                const idx = (self.net_head + cfg.profiler.memory_samples - self.net_len + i) % cfg.profiler.memory_samples;
                max_kbps = @max(max_kbps, self.net_throughput_kbps[d][idx]);
            }
        }
    }
    drawGraphGridAndAxes(graph, plot, max_kbps, "KB/s");
    if (self.net_len < 2 or self.net_device_count == 0) return;

    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "net throughput", .{}) catch return;
    rl.drawText(label, @intFromFloat(plot.x + 4.0), @intFromFloat(graph.y + 2.0), cfg.profiler.panel_text_size, cfg.profiler.text_muted);

    drawNetworkThroughputSeries(self, plot, max_kbps, 0, cfg.profiler.network_line_dev1);
    if (self.net_device_count >= 2) {
        drawNetworkThroughputSeries(self, plot, max_kbps, 1, cfg.profiler.network_line_dev2);
    }
}

fn drawNetworkLatencyGraph(self: *const Overlay, panel: rl.Rectangle, y: f32) void {
    const graph = rl.Rectangle{
        .x = panel.x + cfg.profiler.panel_padding,
        .y = y,
        .width = panel.width - cfg.profiler.panel_padding * 2.0,
        .height = cfg.profiler.network_graph_height,
    };
    rl.drawRectangleRec(graph, cfg.profiler.graph_fill);
    rl.drawRectangleLinesEx(graph, 1.0, cfg.profiler.graph_border);
    const plot = graphPlotRect(graph);
    var max_lat_ms: f32 = 1.0;
    if (self.net_len >= 2 and self.net_device_count > 0) {
        for (0..self.net_device_count) |d| {
            for (0..self.net_len) |i| {
                const idx = (self.net_head + cfg.profiler.memory_samples - self.net_len + i) % cfg.profiler.memory_samples;
                max_lat_ms = @max(max_lat_ms, self.net_latency_ms[d][idx]);
            }
        }
    }
    drawGraphGridAndAxes(graph, plot, max_lat_ms, "ms");
    if (self.net_len < 2 or self.net_device_count == 0) return;

    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "net latency", .{}) catch return;
    rl.drawText(label, @intFromFloat(plot.x + 4.0), @intFromFloat(graph.y + 2.0), cfg.profiler.panel_text_size, cfg.profiler.text_muted);

    drawNetworkLatencySeries(self, plot, max_lat_ms, 0, cfg.profiler.latency_line_dev1);
    if (self.net_device_count >= 2) {
        drawNetworkLatencySeries(self, plot, max_lat_ms, 1, cfg.profiler.latency_line_dev2);
    }
}

fn drawNetworkThroughputSeries(self: *const Overlay, plot: rl.Rectangle, max_kbps: f32, device_idx: usize, color: rl.Color) void {
    const denom = @as(f32, @floatFromInt(@max(self.net_len - 1, 1)));
    var prev: ?rl.Vector2 = null;
    for (0..self.net_len) |i| {
        const idx = (self.net_head + cfg.profiler.memory_samples - self.net_len + i) % cfg.profiler.memory_samples;
        const x_norm = @as(f32, @floatFromInt(i)) / denom;
        const bw_norm = @min(1.0, self.net_throughput_kbps[device_idx][idx] / max_kbps);
        const p: rl.Vector2 = .{ .x = plot.x + plot.width * x_norm, .y = plot.y + plot.height * (1.0 - bw_norm) };
        if (prev) |q| rl.drawLineEx(q, p, 1.1, color);
        prev = p;
    }
}

fn drawNetworkLatencySeries(self: *const Overlay, plot: rl.Rectangle, max_lat_ms: f32, device_idx: usize, color: rl.Color) void {
    const denom = @as(f32, @floatFromInt(@max(self.net_len - 1, 1)));
    var prev: ?rl.Vector2 = null;
    for (0..self.net_len) |i| {
        const idx = (self.net_head + cfg.profiler.memory_samples - self.net_len + i) % cfg.profiler.memory_samples;
        const x_norm = @as(f32, @floatFromInt(i)) / denom;
        const lat_norm = @min(1.0, self.net_latency_ms[device_idx][idx] / max_lat_ms);
        const p: rl.Vector2 = .{ .x = plot.x + plot.width * x_norm, .y = plot.y + plot.height * (1.0 - lat_norm) };
        if (prev) |q| rl.drawLineEx(q, p, 1.0, color);
        prev = p;
    }
}

fn drawGraphGridAndAxes(graph: rl.Rectangle, plot: rl.Rectangle, y_max: f32, y_unit: []const u8) void {
    const x0 = plot.x;
    const x1 = plot.x + plot.width;
    const y0 = plot.y + plot.height;
    const y1 = plot.y;

    const grid_x: usize = 6;
    const grid_y: usize = 3;
    for (0..grid_x + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(grid_x));
        const x = x0 + (x1 - x0) * t;
        rl.drawLineEx(.{ .x = x, .y = y1 }, .{ .x = x, .y = y0 }, 1.0, cfg.profiler.graph_grid);
    }
    for (0..grid_y + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(grid_y));
        const y = y0 - (y0 - y1) * t;
        rl.drawLineEx(.{ .x = x0, .y = y }, .{ .x = x1, .y = y }, 1.0, cfg.profiler.graph_grid);
        var tick_buf: [64]u8 = undefined;
        const value = y_max * t;
        const tick = std.fmt.bufPrintZ(&tick_buf, "{d:.1}", .{value}) catch continue;
        rl.drawText(
            tick,
            @intFromFloat(graph.x + cfg.profiler.graph_axis_text_x),
            @intFromFloat(y - cfg.profiler.graph_axis_tick_y_offset),
            cfg.profiler.panel_text_size - 1,
            cfg.profiler.graph_axis_text,
        );
    }
    var ylab_buf: [32]u8 = undefined;
    const ylab = std.fmt.bufPrintZ(&ylab_buf, "y:{s}", .{y_unit}) catch return;
    rl.drawText(
        ylab,
        @intFromFloat(graph.x + cfg.profiler.graph_axis_text_x),
        @intFromFloat(graph.y + 2.0),
        cfg.profiler.panel_text_size - 1,
        cfg.profiler.graph_axis_text,
    );
    rl.drawText(
        "x: recent -> now",
        @intFromFloat(x1 - cfg.profiler.graph_x_label_width),
        @intFromFloat(y0 - 12.0),
        cfg.profiler.panel_text_size - 1,
        cfg.profiler.graph_axis_text,
    );
}

fn graphPlotRect(graph: rl.Rectangle) rl.Rectangle {
    return .{
        .x = graph.x + cfg.profiler.graph_left_gutter,
        .y = graph.y + cfg.profiler.graph_header_height,
        .width = @max(1.0, graph.width - cfg.profiler.graph_left_gutter - cfg.profiler.graph_right_gutter),
        .height = @max(1.0, graph.height - cfg.profiler.graph_header_height - cfg.profiler.graph_bottom_padding),
    };
}

fn latestMemoryBytes(self: *const Overlay) ?u64 {
    if (self.memory_len == 0) return null;
    const idx = (self.memory_head + self.memory_samples.len - 1) % self.memory_samples.len;
    return self.memory_samples[idx];
}

fn bytesToMb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn currentMemoryBytes(io: std.Io) ?u64 {
    return switch (builtin.os.tag) {
        .windows => currentMemoryBytesWindows(),
        .linux => currentMemoryBytesLinux(io) orelse currentMemoryBytesPosix(),
        .dragonfly,
        .freebsd,
        .netbsd,
        .openbsd,
        .illumos,
        .serenity,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => currentMemoryBytesPosix(),
        else => null,
    };
}

fn currentMemoryBytesPosix() ?u64 {
    const ru = std.posix.getrusage(0);
    return switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => @as(u64, @intCast(ru.maxrss)),
        else => @as(u64, @intCast(ru.maxrss)) * 1024,
    };
}

fn currentMemoryBytesWindows() ?u64 {
    if (builtin.os.tag != .windows) return null;
    const windows = std.os.windows;
    var vmc: windows.VM_COUNTERS = undefined;
    const rc = windows.ntdll.NtQueryInformationProcess(
        windows.GetCurrentProcess(),
        windows.PROCESSINFOCLASS.VmCounters,
        &vmc,
        @sizeOf(windows.VM_COUNTERS),
        null,
    );
    if (rc != .SUCCESS) return null;
    return vmc.WorkingSetSize;
}

fn currentMemoryBytesLinux(io: std.Io) ?u64 {
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        "/proc/self/status",
        std.heap.page_allocator,
        .limited(64 * 1024),
    ) catch return null;
    defer std.heap.page_allocator.free(content);

    const needle = "VmRSS:";
    const start = std.mem.indexOf(u8, content, needle) orelse return null;
    const tail = content[start + needle.len ..];

    var i: usize = 0;
    while (i < tail.len and (tail[i] == ' ' or tail[i] == '\t')) : (i += 1) {}
    const num_start = i;
    while (i < tail.len and tail[i] >= '0' and tail[i] <= '9') : (i += 1) {}
    if (i <= num_start) return null;
    const kb = std.fmt.parseInt(u64, tail[num_start..i], 10) catch return null;
    return kb * 1024;
}
