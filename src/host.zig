const std = @import("std");
const common = @import("common");
const Io = std.Io;

pub const Args = struct {
    port: u16 = 42069,
    module_id: [4]u8 = [_]u8{'X'} ** 4,

    pub const init: Args = .{};

    pub fn fromArgIter(it: *std.process.Args.Iterator) error{ InvalidArgument, InvalidValue }!Args {
        var self: Args = .init;

        if (it.skip() == false) {
            return self;
        }

        while (it.next()) |arg| {
            const trimmed = std.mem.trim(u8, arg, " \t\r\n");

            if (std.mem.startsWith(u8, trimmed, "--port")) {
                const port_string = it.next() orelse return error.InvalidValue;
                self.port = std.fmt.parseInt(u16, port_string, 10) catch return error.InvalidValue;
            }

            if (std.mem.startsWith(u8, trimmed, "--module_id")) {
                const module_id = it.next() orelse return error.InvalidValue;
                if (module_id.len != 4) return error.InvalidArgument;
                @memcpy(self.module_id[0..4], module_id[0..4]);
            }
        }

        return self;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    var args = init.minimal.args.iterateAllocator(arena) catch |err| {
        std.log.err("{}", .{err});
        return;
    };
    defer args.deinit();

    const parsed = Args.fromArgIter(&args) catch |err| {
        std.log.err("{}", .{err});
        return;
    };

    _ = parsed;
}
