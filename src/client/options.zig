const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");

pub const RuntimeOptions = struct {
    show_menu: bool = false,
    show_legend: bool = true,
    show_cursor: bool = true,
    show_stats_panel: bool = cfg.plot.show_stats_panel,
    show_tolerance: bool = cfg.plot.show_tolerance_overlay,
    show_delta_series: bool = cfg.plot.show_delta_series,
    tolerance_use_stddev: bool = cfg.plot.tolerance_use_stddev,

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

    pub fn update(self: *Menu, options: *RuntimeOptions) void {
        if (rl.isKeyPressed(cfg.options_menu.toggle_key)) {
            options.show_menu = !options.show_menu;
        }
        if (!options.show_menu) return;

        const item_count = items.len;
        if (rl.isKeyPressed(cfg.options_menu.up_key)) {
            self.selected = if (self.selected == 0) item_count - 1 else self.selected - 1;
        }
        if (rl.isKeyPressed(cfg.options_menu.down_key)) {
            self.selected = (self.selected + 1) % item_count;
        }
        if (rl.isKeyPressed(cfg.options_menu.left_key)) {
            items[self.selected].apply(options, -1);
        }
        if (rl.isKeyPressed(cfg.options_menu.right_key)) {
            items[self.selected].apply(options, 1);
        }
    }

    pub fn draw(self: *const Menu, options: RuntimeOptions) void {
        if (!options.show_menu) return;

        const sw = @as(f32, @floatFromInt(rl.getScreenWidth()));
        const sh = @as(f32, @floatFromInt(rl.getScreenHeight()));
        const w = @min(cfg.options_menu.panel_width, sw - cfg.options_menu.panel_margin * 2.0);
        const h = @min(sh * cfg.options_menu.panel_max_height_ratio, cfg.options_menu.panel_padding * 2.0 + cfg.options_menu.panel_line_gap * @as(f32, @floatFromInt(items.len + 2)));
        const rect = rl.Rectangle{
            .x = sw - w - cfg.options_menu.panel_margin,
            .y = cfg.options_menu.panel_margin,
            .width = w,
            .height = h,
        };

        rl.drawRectangleRec(rect, cfg.theme.title_panel);
        rl.drawRectangleLinesEx(rect, 1.0, cfg.theme.border);
        rl.drawText("Options (F1)", @intFromFloat(rect.x + cfg.options_menu.panel_padding), @intFromFloat(rect.y + cfg.options_menu.panel_padding), cfg.options_menu.title_size, cfg.theme.text_primary);

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
};

const Item = struct {
    name: []const u8,
    value: *const fn (RuntimeOptions, *[160]u8) anyerror![:0]const u8,
    apply: *const fn (*RuntimeOptions, i32) void,
};

const items = [_]Item{
    .{ .name = "legend", .value = boolValue(.show_legend), .apply = boolApply(.show_legend) },
    .{ .name = "cursor", .value = boolValue(.show_cursor), .apply = boolApply(.show_cursor) },
    .{ .name = "stats", .value = boolValue(.show_stats_panel), .apply = boolApply(.show_stats_panel) },
    .{ .name = "tolerance", .value = boolValue(.show_tolerance), .apply = boolApply(.show_tolerance) },
    .{ .name = "delta", .value = boolValue(.show_delta_series), .apply = boolApply(.show_delta_series) },
    .{ .name = "tol_basis_stddev", .value = boolValue(.tolerance_use_stddev), .apply = boolApply(.tolerance_use_stddev) },
    .{ .name = "accel_warn", .value = f32Value(.tolerance_accel_warn_abs), .apply = f32Apply(.tolerance_accel_warn_abs, 10.0, 0.0, 1_000_000.0) },
    .{ .name = "accel_fail", .value = f32Value(.tolerance_accel_fail_abs), .apply = f32Apply(.tolerance_accel_fail_abs, 25.0, 0.0, 1_000_000.0) },
    .{ .name = "gyro_warn", .value = f32Value(.tolerance_gyro_warn_abs), .apply = f32Apply(.tolerance_gyro_warn_abs, 25.0, 0.0, 1_000_000.0) },
    .{ .name = "gyro_fail", .value = f32Value(.tolerance_gyro_fail_abs), .apply = f32Apply(.tolerance_gyro_fail_abs, 50.0, 0.0, 1_000_000.0) },
    .{ .name = "elev_warn", .value = f32Value(.tolerance_elevation_warn_abs), .apply = f32Apply(.tolerance_elevation_warn_abs, 1.0, 0.0, 360.0) },
    .{ .name = "elev_fail", .value = f32Value(.tolerance_elevation_fail_abs), .apply = f32Apply(.tolerance_elevation_fail_abs, 1.0, 0.0, 360.0) },
    .{ .name = "bearing_warn", .value = f32Value(.tolerance_bearing_warn_abs), .apply = f32Apply(.tolerance_bearing_warn_abs, 1.0, 0.0, 360.0) },
    .{ .name = "bearing_fail", .value = f32Value(.tolerance_bearing_fail_abs), .apply = f32Apply(.tolerance_bearing_fail_abs, 1.0, 0.0, 360.0) },
};

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
