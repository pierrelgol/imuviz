const std = @import("std");
const cfg = @import("config.zig");
const options_mod = @import("options.zig");

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    executable_dir_path: []u8,
    executable_dir: std.Io.Dir,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Store {
        const executable_dir_path = try std.process.executableDirPathAlloc(io, allocator);
        const executable_dir = try std.Io.Dir.openDirAbsolute(io, executable_dir_path, .{});
        return .{
            .io = io,
            .allocator = allocator,
            .executable_dir_path = executable_dir_path,
            .executable_dir = executable_dir,
        };
    }

    pub fn deinit(self: *Store) void {
        self.executable_dir.close(self.io);
        self.allocator.free(self.executable_dir_path);
    }

    pub fn load(self: *Store, options: *options_mod.RuntimeOptions) !bool {
        const bytes = self.executable_dir.readFileAlloc(
            self.io,
            cfg.settings.file_name,
            self.allocator,
            .limited(cfg.settings.max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const parsed = std.json.parseFromSliceLeaky(
            options_mod.RuntimeOptions,
            self.allocator,
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
        const normalized = normalize(options);
        const json = try std.json.Stringify.valueAlloc(self.allocator, normalized, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);

        const with_newline = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json});
        defer self.allocator.free(with_newline);

        try self.executable_dir.writeFile(self.io, .{
            .sub_path = cfg.settings.file_name,
            .data = with_newline,
        });
    }
};

pub fn normalize(options: options_mod.RuntimeOptions) options_mod.RuntimeOptions {
    var out = options;
    out.show_menu = false;
    return out;
}
