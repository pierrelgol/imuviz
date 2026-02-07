const std = @import("std");
const rl = @import("raylib");

const cfg = @import("client/config.zig");
const network = @import("client/network.zig");
const History = @import("client/history.zig").History;
const Renderer = @import("client/renderer.zig").Renderer;
const DeviceFrame = @import("client/renderer.zig").DeviceFrame;
const utils = @import("client/utils.zig");

comptime {
    std.testing.refAllDecls(cfg);
    std.testing.refAllDecls(network);
    std.testing.refAllDecls(History);
    std.testing.refAllDecls(DeviceFrame);
    std.testing.refAllDecls(utils);
}

const Atomic = std.atomic.Value;

const Hosts = struct {
    count: usize = 1,
    lens: [cfg.max_hosts]u8 = [_]u8{0} ** cfg.max_hosts,
    data: [cfg.max_hosts][cfg.max_host_len]u8 = [_][cfg.max_host_len]u8{[_]u8{0} ** cfg.max_host_len} ** cfg.max_hosts,

    pub fn get(self: *const Hosts, index: usize) []const u8 {
        return self.data[index][0..self.lens[index]];
    }

    pub fn parse(text: []const u8) error{ InvalidArgument, InvalidValue }!Hosts {
        var hosts: Hosts = .{};
        var it = std.mem.splitScalar(u8, text, ',');
        var i: usize = 0;

        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) return error.InvalidValue;
            if (i >= cfg.max_hosts) return error.InvalidArgument;
            if (trimmed.len >= cfg.max_host_len) return error.InvalidArgument;

            @memcpy(hosts.data[i][0..trimmed.len], trimmed);
            hosts.lens[i] = @intCast(trimmed.len);
            i += 1;
        }

        if (i == 0) return error.InvalidValue;
        hosts.count = i;
        return hosts;
    }
};

const Args = struct {
    hosts: Hosts = .{},
    port: u16 = 9999,

    pub fn fromArgIter(it: *std.process.Args.Iterator) error{ InvalidArgument, InvalidValue }!Args {
        var self: Args = .{
            .hosts = Hosts.parse("127.0.0.1") catch unreachable,
        };

        if (!it.skip()) return self;

        while (it.next()) |arg| {
            const trimmed = std.mem.trim(u8, arg, " \t\r\n");

            if (std.mem.eql(u8, trimmed, "--hosts") or std.mem.eql(u8, trimmed, "--host")) {
                const value = it.next() orelse return error.InvalidValue;
                self.hosts = try Hosts.parse(value);
                continue;
            }

            if (std.mem.eql(u8, trimmed, "--port")) {
                const value = it.next() orelse return error.InvalidValue;
                self.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
                continue;
            }

            return error.InvalidArgument;
        }

        return self;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var should_stop: Atomic(bool) = .init(false);
    // utils.setupSignalHandler(&should_stop);

    var args_iter = init.minimal.args.iterateAllocator(arena) catch |err| {
        std.log.err("failed to iterate args: {}", .{err});
        return err;
    };
    defer args_iter.deinit();

    const args = Args.fromArgIter(&args_iter) catch |err| {
        std.log.err("invalid args: {}", .{err});
        return err;
    };
    if (cfg.trace_client_main) {
        std.log.info("client: args parsed port={} host_count={}", .{ args.port, args.hosts.count });
        for (0..args.hosts.count) |i| {
            std.log.info("client: host[{}]={s}", .{ i, args.hosts.get(i) });
        }
    }

    var endpoint_specs: [cfg.max_hosts]network.EndpointSpec = undefined;
    for (0..args.hosts.count) |i| {
        endpoint_specs[i] = .{ .host = args.hosts.get(i), .port = args.port };
    }

    var client_network = network.ClientNetwork.init(io, endpoint_specs[0..args.hosts.count]);
    if (cfg.trace_client_main) {
        std.log.info("client: network init complete endpoint_count={}", .{args.hosts.count});
    }
    try client_network.start();
    if (cfg.trace_client_main) {
        std.log.info("client: network start complete", .{});
    }
    defer client_network.stopAndJoin();

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(cfg.window_initial_width, cfg.window_initial_height, "IMU Visualizer");
    rl.setWindowMinSize(cfg.window_min_width, cfg.window_min_height);
    defer rl.closeWindow();
    rl.setTargetFPS(cfg.target_fps);

    var histories: [cfg.max_hosts]History = [_]History{.{}} ** cfg.max_hosts;
    var renderer: Renderer = .{};
    defer renderer.deinit();

    var drain_buffer: [cfg.drain_batch_size]@import("common").Report = undefined;
    var last_render_debug_ms: i64 = 0;
    var frame_count: u64 = 0;

    while (!rl.windowShouldClose() and !should_stop.load(.acquire)) {
        frame_count += 1;
        for (0..args.hosts.count) |i| {
            const drained = client_network.drain(i, &drain_buffer);
            for (drain_buffer[0..drained]) |report| {
                histories[i].appendReport(report);
            }
            if (cfg.trace_client_main and drained > 0) {
                std.log.info("client: frame={} endpoint={} drained={} history_len={}", .{ frame_count, i, drained, histories[i].len });
            }
        }

        const now_ms: i64 = @intFromFloat(rl.getTime() * 1000.0);
        if (now_ms - last_render_debug_ms >= cfg.render_debug_interval_ms) {
            last_render_debug_ms = now_ms;
            for (0..args.hosts.count) |i| {
                const snap = client_network.snapshot(i);
                std.log.info("render: endpoint={} history_len={} state={} parse={} conn_fail={} disc={} reconn={} partial={}", .{
                    i,
                    histories[i].len,
                    snap.state,
                    snap.parse_errors,
                    snap.connect_failures,
                    snap.disconnects,
                    snap.reconnects,
                    snap.partial_disconnects,
                });
            }
        }

        var frames: [cfg.max_hosts]DeviceFrame = undefined;
        for (0..args.hosts.count) |i| {
            frames[i] = .{
                .title = if (args.hosts.count == 1) "IMU Device" else args.hosts.get(i),
                .history = &histories[i],
                .snapshot = client_network.snapshot(i),
            };
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        renderer.draw(frames[0..args.hosts.count]);
        rl.drawFPS(cfg.renderer.fps_x, cfg.renderer.fps_y);
    }
}

test "hosts parse" {
    const hosts = try Hosts.parse("127.0.0.1,192.168.1.20");
    try std.testing.expectEqual(@as(usize, 2), hosts.count);
    try std.testing.expectEqualStrings("127.0.0.1", hosts.get(0));
    try std.testing.expectEqualStrings("192.168.1.20", hosts.get(1));
}
