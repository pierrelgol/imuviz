const std = @import("std");
const cfg = @import("config.zig");
const options_mod = @import("options.zig");

pub const Store = struct {
    io: std.Io,
    op_arena: std.heap.ArenaAllocator,
    executable_dir_path: []u8,
    executable_dir: std.Io.Dir,

    pub fn init(io: std.Io, _: std.mem.Allocator) !Store {
        const executable_dir_path = try std.process.executableDirPathAlloc(io, std.heap.page_allocator);
        const executable_dir = try std.Io.Dir.openDirAbsolute(io, executable_dir_path, .{});
        return .{
            .io = io,
            .op_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .executable_dir_path = executable_dir_path,
            .executable_dir = executable_dir,
        };
    }

    pub fn deinit(self: *Store) void {
        self.executable_dir.close(self.io);
        self.op_arena.deinit();
        std.heap.page_allocator.free(self.executable_dir_path);
    }

    pub fn load(self: *Store, options: *options_mod.RuntimeOptions) !bool {
        _ = self.op_arena.reset(.retain_capacity);
        const allocator = self.op_arena.allocator();
        const bytes = self.executable_dir.readFileAlloc(
            self.io,
            cfg.settings.file_name,
            allocator,
            .limited(cfg.settings.max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };

        const parsed = std.json.parseFromSliceLeaky(
            options_mod.RuntimeOptions,
            allocator,
            bytes,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.warn("settings: failed to parse {s}: {}", .{ cfg.settings.file_name, err });
            return false;
        };
        options.* = normalize(parsed);
        return true;
    }

    pub fn save(self: *Store, options: options_mod.RuntimeOptions) !void {
        _ = self.op_arena.reset(.retain_capacity);
        const allocator = self.op_arena.allocator();
        const normalized = normalize(options);
        const json = try std.json.Stringify.valueAlloc(allocator, normalized, .{ .whitespace = .indent_2 });

        const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{json});

        try self.executable_dir.writeFile(self.io, .{
            .sub_path = cfg.settings.file_name,
            .data = with_newline,
        });
    }
};

pub fn normalize(options: options_mod.RuntimeOptions) options_mod.RuntimeOptions {
    var out = options;
    out.show_menu = false;
    normalizeTolerancePair(&out.tolerance_accel_warn_abs, &out.tolerance_accel_fail_abs);
    normalizeTolerancePair(&out.tolerance_gyro_warn_abs, &out.tolerance_gyro_fail_abs);
    normalizeTolerancePair(&out.tolerance_elevation_warn_abs, &out.tolerance_elevation_fail_abs);
    normalizeTolerancePair(&out.tolerance_bearing_warn_abs, &out.tolerance_bearing_fail_abs);
    return out;
}

fn normalizeTolerancePair(warn_abs: *f32, fail_abs: *f32) void {
    warn_abs.* = @max(0.0, warn_abs.*);
    fail_abs.* = @max(0.0, fail_abs.*);
    if (fail_abs.* < warn_abs.*) {
        const tmp = warn_abs.*;
        warn_abs.* = fail_abs.*;
        fail_abs.* = tmp;
    }
}
