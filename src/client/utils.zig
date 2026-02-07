const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

pub fn drawTextFmt(comptime fmt: []const u8, args: anytype, x: i32, y: i32, size: i32, color: rl.Color) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, fmt, args) catch return;
    rl.drawText(text, x, y, size, color);
}

pub fn setupSignalHandler(stop: *std.atomic.Value(bool)) void {
    if (builtin.os.tag != .linux) return;

    signal_target = stop;
    const signals: std.os.linux.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &signals, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &signals, null);
}

var signal_target: ?*std.atomic.Value(bool) = null;

fn handleSignal(_: std.os.linux.SIG) callconv(.c) void {
    if (signal_target) |target| {
        target.store(true, .release);
    }
}
