const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");

pub const RuntimeOptions = struct {
    show_menu: bool = false,
    show_fps: bool = true,
    show_scene: bool = true,
    show_status_line: bool = true,
    show_current_values: bool = true,
    show_legend: bool = true,
    show_cursor: bool = true,
    show_plot_grid: bool = true,
    show_plot_axes: bool = true,
    show_plot_traces: bool = true,
    show_stats_panel: bool = cfg.plot.show_stats_panel,
    show_tolerance: bool = cfg.plot.show_tolerance_overlay,
    show_delta_series: bool = cfg.plot.show_delta_series,
    tolerance_use_stddev: bool = cfg.plot.tolerance_use_stddev,
    show_accel_x_plot: bool = true,
    show_accel_y_plot: bool = true,
    show_accel_z_plot: bool = true,
    show_gyro_norm_plot: bool = true,
    show_elevation_plot: bool = true,
    show_bearing_plot: bool = true,

    tolerance_accel_warn_abs: f32 = cfg.plot.tolerance_accel_warn_abs,
    tolerance_accel_fail_abs: f32 = cfg.plot.tolerance_accel_fail_abs,
    tolerance_gyro_warn_abs: f32 = cfg.plot.tolerance_gyro_warn_abs,
    tolerance_gyro_fail_abs: f32 = cfg.plot.tolerance_gyro_fail_abs,
    tolerance_elevation_warn_abs: f32 = cfg.plot.tolerance_elevation_warn_abs,
    tolerance_elevation_fail_abs: f32 = cfg.plot.tolerance_elevation_fail_abs,
    tolerance_bearing_warn_abs: f32 = cfg.plot.tolerance_bearing_warn_abs,
    tolerance_bearing_fail_abs: f32 = cfg.plot.tolerance_bearing_fail_abs,
};

pub const Menu = struct {
    selected: usize = 0,
    mode: Mode = .normal,

    const Mode = enum {
        normal,
        insert,
    };

    pub fn update(self: *Menu, options: *RuntimeOptions) void {
        if (rl.isKeyPressed(.semicolon)) {
            options.show_menu = !options.show_menu;
            if (options.show_menu) self.mode = .normal;
        }
        if (!options.show_menu) return;

        if (rl.isKeyPressed(.escape)) self.mode = .normal;
        if (rl.isKeyPressed(.i)) self.mode = .insert;

        self.handleMouse(options);

        const item_count = items.len;
        if (self.mode == .normal) {
            if (rl.isKeyPressed(.k)) {
                self.selected = if (self.selected == 0) item_count - 1 else self.selected - 1;
            }
            if (rl.isKeyPressed(.j)) {
                self.selected = (self.selected + 1) % item_count;
            }
        }
        if (rl.isKeyPressed(.h)) {
            items[self.selected].apply(options, -1);
        }
        if (rl.isKeyPressed(.l)) {
            items[self.selected].apply(options, 1);
        }
    }

    pub fn draw(self: *const Menu, options: RuntimeOptions) void {
        if (!options.show_menu) return;

        const sw = @as(f32, @floatFromInt(rl.getScreenWidth()));
        const sh = @as(f32, @floatFromInt(rl.getScreenHeight()));
        const rect = panelRect(sw, sh);

        rl.drawRectangleRec(rect, cfg.theme.title_panel);
        rl.drawRectangleLinesEx(rect, 1.0, cfg.theme.border);
        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "Options [:] mode={s}", .{modeText(self.mode)}) catch return;
        rl.drawText(title, @intFromFloat(rect.x + cfg.options_menu.panel_padding), @intFromFloat(rect.y + cfg.options_menu.panel_padding), cfg.options_menu.title_size, cfg.theme.text_primary);

        var y = rect.y + cfg.options_menu.panel_padding + @as(f32, @floatFromInt(cfg.options_menu.title_size)) + 6.0;
        for (items, 0..) |item, i| {
            var line_buf: [160]u8 = undefined;
            const value = item.value(options, &line_buf) catch continue;
            const color = if (i == self.selected) cfg.renderer.status_connected else cfg.theme.text_secondary;
            var text_buf: [224]u8 = undefined;
            const text = std.fmt.bufPrintZ(&text_buf, "{s}: {s}", .{ item.name, value }) catch continue;
            rl.drawText(text, @intFromFloat(rect.x + cfg.options_menu.panel_padding), @intFromFloat(y), cfg.options_menu.item_size, color);
            y += cfg.options_menu.panel_line_gap;
        }
    }

    fn handleMouse(self: *Menu, options: *RuntimeOptions) void {
        const sw = @as(f32, @floatFromInt(rl.getScreenWidth()));
        const sh = @as(f32, @floatFromInt(rl.getScreenHeight()));
        const rect = panelRect(sw, sh);
        const mouse = rl.getMousePosition();
        if (!pointInRect(mouse, rect)) return;

        if (!rl.isMouseButtonPressed(.left)) return;
        const idx = itemIndexAtMouse(rect, mouse) orelse return;
        self.selected = idx;

        const item = items[idx];
        if (item.kind == .toggle) {
            item.apply(options, 1);
            return;
        }
        const split_x = rect.x + rect.width * 0.60;
        item.apply(options, if (mouse.x < split_x) -1 else 1);
    }
};

const Item = struct {
    name: []const u8,
    kind: Kind,
    value: *const fn (RuntimeOptions, *[160]u8) anyerror![:0]const u8,
    apply: *const fn (*RuntimeOptions, i32) void,

    const Kind = enum {
        toggle,
        scalar,
    };
};

const items = [_]Item{
    .{ .name = "fps", .kind = .toggle, .value = boolValue(.show_fps), .apply = boolApply(.show_fps) },
    .{ .name = "scene_3d", .kind = .toggle, .value = boolValue(.show_scene), .apply = boolApply(.show_scene) },
    .{ .name = "status_line", .kind = .toggle, .value = boolValue(.show_status_line), .apply = boolApply(.show_status_line) },
    .{ .name = "current_values", .kind = .toggle, .value = boolValue(.show_current_values), .apply = boolApply(.show_current_values) },
    .{ .name = "legend", .kind = .toggle, .value = boolValue(.show_legend), .apply = boolApply(.show_legend) },
    .{ .name = "cursor", .kind = .toggle, .value = boolValue(.show_cursor), .apply = boolApply(.show_cursor) },
    .{ .name = "plot_grid", .kind = .toggle, .value = boolValue(.show_plot_grid), .apply = boolApply(.show_plot_grid) },
    .{ .name = "plot_axes", .kind = .toggle, .value = boolValue(.show_plot_axes), .apply = boolApply(.show_plot_axes) },
    .{ .name = "plot_traces", .kind = .toggle, .value = boolValue(.show_plot_traces), .apply = boolApply(.show_plot_traces) },
    .{ .name = "plot_accel_x", .kind = .toggle, .value = boolValue(.show_accel_x_plot), .apply = boolApply(.show_accel_x_plot) },
    .{ .name = "plot_accel_y", .kind = .toggle, .value = boolValue(.show_accel_y_plot), .apply = boolApply(.show_accel_y_plot) },
    .{ .name = "plot_accel_z", .kind = .toggle, .value = boolValue(.show_accel_z_plot), .apply = boolApply(.show_accel_z_plot) },
    .{ .name = "plot_gyro_norm", .kind = .toggle, .value = boolValue(.show_gyro_norm_plot), .apply = boolApply(.show_gyro_norm_plot) },
    .{ .name = "plot_elevation", .kind = .toggle, .value = boolValue(.show_elevation_plot), .apply = boolApply(.show_elevation_plot) },
    .{ .name = "plot_bearing", .kind = .toggle, .value = boolValue(.show_bearing_plot), .apply = boolApply(.show_bearing_plot) },
    .{ .name = "stats", .kind = .toggle, .value = boolValue(.show_stats_panel), .apply = boolApply(.show_stats_panel) },
    .{ .name = "tolerance", .kind = .toggle, .value = boolValue(.show_tolerance), .apply = boolApply(.show_tolerance) },
    .{ .name = "delta", .kind = .toggle, .value = boolValue(.show_delta_series), .apply = boolApply(.show_delta_series) },
    .{ .name = "tol_basis_stddev", .kind = .toggle, .value = boolValue(.tolerance_use_stddev), .apply = boolApply(.tolerance_use_stddev) },
    .{ .name = "accel_warn", .kind = .scalar, .value = f32Value(.tolerance_accel_warn_abs), .apply = f32Apply(.tolerance_accel_warn_abs, 10.0, 0.0, 1_000_000.0) },
    .{ .name = "accel_fail", .kind = .scalar, .value = f32Value(.tolerance_accel_fail_abs), .apply = f32Apply(.tolerance_accel_fail_abs, 25.0, 0.0, 1_000_000.0) },
    .{ .name = "gyro_warn", .kind = .scalar, .value = f32Value(.tolerance_gyro_warn_abs), .apply = f32Apply(.tolerance_gyro_warn_abs, 25.0, 0.0, 1_000_000.0) },
    .{ .name = "gyro_fail", .kind = .scalar, .value = f32Value(.tolerance_gyro_fail_abs), .apply = f32Apply(.tolerance_gyro_fail_abs, 50.0, 0.0, 1_000_000.0) },
    .{ .name = "elev_warn", .kind = .scalar, .value = f32Value(.tolerance_elevation_warn_abs), .apply = f32Apply(.tolerance_elevation_warn_abs, 1.0, 0.0, 360.0) },
    .{ .name = "elev_fail", .kind = .scalar, .value = f32Value(.tolerance_elevation_fail_abs), .apply = f32Apply(.tolerance_elevation_fail_abs, 1.0, 0.0, 360.0) },
    .{ .name = "bearing_warn", .kind = .scalar, .value = f32Value(.tolerance_bearing_warn_abs), .apply = f32Apply(.tolerance_bearing_warn_abs, 1.0, 0.0, 360.0) },
    .{ .name = "bearing_fail", .kind = .scalar, .value = f32Value(.tolerance_bearing_fail_abs), .apply = f32Apply(.tolerance_bearing_fail_abs, 1.0, 0.0, 360.0) },
};

fn panelRect(sw: f32, sh: f32) rl.Rectangle {
    const w = @min(cfg.options_menu.panel_width, sw - cfg.options_menu.panel_margin * 2.0);
    const h = @min(sh * cfg.options_menu.panel_max_height_ratio, cfg.options_menu.panel_padding * 2.0 + cfg.options_menu.panel_line_gap * @as(f32, @floatFromInt(items.len + 2)));
    return .{
        .x = sw - w - cfg.options_menu.panel_margin,
        .y = cfg.options_menu.panel_margin,
        .width = w,
        .height = h,
    };
}

fn itemIndexAtMouse(rect: rl.Rectangle, mouse: rl.Vector2) ?usize {
    const start_y = rect.y + cfg.options_menu.panel_padding + @as(f32, @floatFromInt(cfg.options_menu.title_size)) + 6.0;
    if (mouse.y < start_y) return null;
    const rel = mouse.y - start_y;
    const idx: usize = @intFromFloat(@floor(rel / cfg.options_menu.panel_line_gap));
    if (idx >= items.len) return null;
    return idx;
}

fn pointInRect(p: rl.Vector2, rect: rl.Rectangle) bool {
    return p.x >= rect.x and p.x <= rect.x + rect.width and p.y >= rect.y and p.y <= rect.y + rect.height;
}

fn modeText(mode: Menu.Mode) []const u8 {
    return switch (mode) {
        .normal => "NORMAL",
        .insert => "INSERT",
    };
}

fn boolValue(comptime field: std.meta.FieldEnum(RuntimeOptions)) *const fn (RuntimeOptions, *[160]u8) anyerror![:0]const u8 {
    return struct {
        fn f(options: RuntimeOptions, buf: *[160]u8) anyerror![:0]const u8 {
            return std.fmt.bufPrintZ(buf, "{s}", .{if (@field(options, @tagName(field))) "on" else "off"});
        }
    }.f;
}

fn boolApply(comptime field: std.meta.FieldEnum(RuntimeOptions)) *const fn (*RuntimeOptions, i32) void {
    return struct {
        fn f(options: *RuntimeOptions, _: i32) void {
            @field(options, @tagName(field)) = !@field(options, @tagName(field));
        }
    }.f;
}

fn f32Value(comptime field: std.meta.FieldEnum(RuntimeOptions)) *const fn (RuntimeOptions, *[160]u8) anyerror![:0]const u8 {
    return struct {
        fn f(options: RuntimeOptions, buf: *[160]u8) anyerror![:0]const u8 {
            return std.fmt.bufPrintZ(buf, "{d:.1}", .{@field(options, @tagName(field))});
        }
    }.f;
}

fn f32Apply(comptime field: std.meta.FieldEnum(RuntimeOptions), step: f32, min_v: f32, max_v: f32) *const fn (*RuntimeOptions, i32) void {
    return struct {
        fn f(options: *RuntimeOptions, dir: i32) void {
            const delta = step * @as(f32, @floatFromInt(dir));
            const next = @field(options, @tagName(field)) + delta;
            @field(options, @tagName(field)) = @max(min_v, @min(max_v, next));
        }
    }.f;
}
