const std = @import("std");
const Io = std.Io;
const Atomic = std.atomic.Value;
const common = @import("common");
const cfg = @import("config.zig");

pub const ConnectionState = enum {
    connecting,
    connected,
    disconnected,
};

pub const EndpointSpec = struct {
    host: []const u8,
    port: u16,
};

pub const EndpointSnapshot = struct {
    state: ConnectionState,
    parse_errors: u64,
    disconnects: u64,
    reconnects: u64,
    partial_disconnects: u64,
    connect_failures: u64,
};

const EndpointShared = struct {
    mutex: Io.Mutex = .init,
    state: ConnectionState = .disconnected,
    queue: Io.Queue(common.Report) = undefined,
    queue_buffer: [cfg.queue_capacity]common.Report = undefined,
    parse_errors: u64 = 0,
    disconnects: u64 = 0,
    reconnects: u64 = 0,
    partial_disconnects: u64 = 0,
    connect_failures: u64 = 0,

    fn init(self: *EndpointShared) void {
        self.* = .{};
        self.queue = Io.Queue(common.Report).init(&self.queue_buffer);
    }
};

const WorkerContext = struct {
    io: Io,
    host: []const u8,
    port: u16,
    stop: *const Atomic(bool),
    shared: *EndpointShared,
};

const LoopExit = enum {
    disconnected,
    stopped,
};

pub const ClientNetwork = struct {
    io: Io,
    stop: Atomic(bool) = .init(false),
    endpoint_count: usize,
    endpoints: [cfg.max_hosts]EndpointShared = [_]EndpointShared{.{}} ** cfg.max_hosts,
    contexts: [cfg.max_hosts]WorkerContext = undefined,
    group: Io.Group = .init,
    threads: [cfg.max_hosts]?std.Thread = [_]?std.Thread{null} ** cfg.max_hosts,

    pub fn init(io: Io, endpoints: []const EndpointSpec) ClientNetwork {
        std.debug.assert(endpoints.len <= cfg.max_hosts);

        var self: ClientNetwork = .{
            .io = io,
            .endpoint_count = endpoints.len,
        };

        for (0..self.endpoint_count) |i| {
            self.endpoints[i].init();
            self.contexts[i] = .{
                .io = io,
                .host = endpoints[i].host,
                .port = endpoints[i].port,
                .stop = &self.stop,
                .shared = undefined,
            };
        }

        return self;
    }

    pub fn start(self: *ClientNetwork) !void {
        if (cfg.trace_network) {
            std.log.info("network: start endpoint_count={}", .{self.endpoint_count});
        }
        for (0..self.endpoint_count) |i| {
            // Bind pointers after `ClientNetwork` reaches its stable address.
            self.contexts[i].shared = &self.endpoints[i];
        }
        for (0..self.endpoint_count) |i| {
            if (cfg.trace_network) {
                std.log.info("network: spawn worker endpoint={} host={s} port={}", .{ i, self.contexts[i].host, self.contexts[i].port });
            }
            self.group.concurrent(self.io, endpointWorkerMain, .{&self.contexts[i]}) catch |err| switch (err) {
                error.ConcurrencyUnavailable => {
                    if (cfg.trace_network) {
                        std.log.warn("network: Group.concurrent unavailable endpoint={}, falling back to std.Thread", .{i});
                    }
                    self.threads[i] = try std.Thread.spawn(.{}, endpointWorkerThreadMain, .{&self.contexts[i]});
                },
            };
        }
    }

    pub fn stopAndJoin(self: *ClientNetwork) void {
        if (cfg.trace_network) {
            std.log.info("network: stop requested", .{});
        }
        self.stop.store(true, .release);

        for (0..self.endpoint_count) |i| {
            self.endpoints[i].queue.close(self.io);
        }

        self.group.cancel(self.io);
        if (cfg.trace_network) {
            std.log.info("network: group canceled, awaiting completion", .{});
        }
        self.group.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };
        if (cfg.trace_network) {
            std.log.info("network: group await finished", .{});
        }

        for (0..self.endpoint_count) |i| {
            if (self.threads[i]) |thread| {
                if (cfg.trace_network) {
                    std.log.info("network: joining fallback thread endpoint={}", .{i});
                }
                thread.join();
                self.threads[i] = null;
            }
        }
        if (cfg.trace_network) {
            std.log.info("network: fully stopped", .{});
        }
    }

    pub fn drain(self: *ClientNetwork, endpoint_index: usize, out: []common.Report) usize {
        return self.endpoints[endpoint_index].queue.getUncancelable(self.io, out, 0) catch |err| switch (err) {
            error.Closed => 0,
        };
    }

    pub fn snapshot(self: *ClientNetwork, endpoint_index: usize) EndpointSnapshot {
        var shared = &self.endpoints[endpoint_index];
        shared.mutex.lockUncancelable(self.io);
        defer shared.mutex.unlock(self.io);

        return .{
            .state = shared.state,
            .parse_errors = shared.parse_errors,
            .disconnects = shared.disconnects,
            .reconnects = shared.reconnects,
            .partial_disconnects = shared.partial_disconnects,
            .connect_failures = shared.connect_failures,
        };
    }
};

fn endpointWorkerMain(ctx: *WorkerContext) Io.Cancelable!void {
    const io = ctx.io;
    var seen_connected = false;
    var connect_attempt: u64 = 0;
    if (cfg.trace_network) {
        std.log.info("network: worker enter host={s} port={}", .{ ctx.host, ctx.port });
    }

    while (!ctx.stop.load(.acquire)) {
        connect_attempt += 1;
        if (cfg.trace_network) {
            std.log.info("network: attempt={} host={s} port={} -> connecting", .{ connect_attempt, ctx.host, ctx.port });
        }
        setState(ctx.shared, io, .connecting);

        var stream = connectToHost(io, ctx.host, ctx.port) catch |err| {
            incrementConnectFailure(ctx.shared, io);
            std.log.warn("client: connect failed to {s}:{}: {}", .{ ctx.host, ctx.port, err });
            setState(ctx.shared, io, .disconnected);
            try sleepReconnect(io, ctx.stop);
            continue;
        };
        defer stream.close(io);
        if (cfg.trace_network) {
            std.log.info("network: connected host={s} port={} socket_handle={}", .{ ctx.host, ctx.port, stream.socket.handle });
        }

        if (seen_connected) {
            incrementReconnect(ctx.shared, io);
            if (cfg.trace_network) {
                std.log.info("network: reconnect recorded host={s} port={}", .{ ctx.host, ctx.port });
            }
        }
        seen_connected = true;
        setState(ctx.shared, io, .connected);

        var parser: LineParser = .{};
        const loop_exit = try runReadLoop(ctx, &stream, &parser);
        if (cfg.trace_network) {
            std.log.info("network: read loop exit host={s} port={} reason={}", .{ ctx.host, ctx.port, loop_exit });
        }

        if (loop_exit == .stopped) break;

        if (parser.len > 0) {
            incrementPartialDisconnect(ctx.shared, io);
        }

        incrementDisconnect(ctx.shared, io);
        setState(ctx.shared, io, .disconnected);
        try sleepReconnect(io, ctx.stop);
    }
    if (cfg.trace_network) {
        std.log.info("network: worker exit host={s} port={}", .{ ctx.host, ctx.port });
    }
}

fn endpointWorkerThreadMain(ctx: *WorkerContext) void {
    endpointWorkerMain(ctx) catch |err| switch (err) {
        error.Canceled => {},
    };
}

fn runReadLoop(ctx: *WorkerContext, stream: *Io.net.Stream, parser: *LineParser) Io.Cancelable!LoopExit {
    var recv_buffer: [cfg.recv_buffer_bytes]u8 = undefined;
    var iter: u64 = 0;

    while (!ctx.stop.load(.acquire)) {
        iter += 1;
        const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(cfg.poll_timeout_ms), .clock = .real } };

        const message = stream.socket.receiveTimeout(ctx.io, &recv_buffer, timeout) catch |err| switch (err) {
            error.Timeout => {
                if (cfg.trace_network and cfg.trace_network_timeouts and (iter % 1000 == 0)) {
                    std.log.debug("network: timeout host={s} port={} iter={}", .{ ctx.host, ctx.port, iter });
                }
                continue;
            },
            error.Canceled => return error.Canceled,
            error.ConnectionResetByPeer,
            error.SocketUnconnected,
            error.NetworkDown,
            => return .disconnected,
            else => {
                std.log.warn("client: receive error from {s}:{}: {}", .{ ctx.host, ctx.port, err });
                return .disconnected;
            },
        };

        if (message.data.len == 0) {
            if (cfg.trace_network) {
                std.log.warn("network: zero-length read host={s} port={} -> disconnected", .{ ctx.host, ctx.port });
            }
            return .disconnected;
        }

        if (cfg.trace_network) {
            std.log.debug("network: recv host={s} port={} bytes={}", .{ ctx.host, ctx.port, message.data.len });
            if (cfg.trace_network_payloads) {
                const preview_len = @min(message.data.len, 120);
                std.log.debug("network: payload preview='{s}'", .{message.data[0..preview_len]});
            }
        }

        feedParser(parser, message.data, ctx);
    }

    return .stopped;
}

const LineParser = struct {
    buffer: [cfg.max_line_bytes]u8 = undefined,
    len: usize = 0,
    overflowed: bool = false,

    fn reset(self: *LineParser) void {
        self.len = 0;
        self.overflowed = false;
    }
};

fn feedParser(parser: *LineParser, chunk: []const u8, ctx: *WorkerContext) void {
    if (cfg.trace_network) {
        std.log.debug("network: parser feed host={s} chunk_len={} current_line_len={} overflowed={}", .{
            ctx.host,
            chunk.len,
            parser.len,
            parser.overflowed,
        });
    }
    for (chunk) |byte| {
        if (byte == '\n') {
            if (parser.overflowed) {
                if (cfg.trace_network) {
                    std.log.warn("network: parser overflow line dropped host={s}", .{ctx.host});
                }
                incrementParseError(ctx.shared, ctx.io);
                parser.reset();
                continue;
            }

            if (parser.len > 0) {
                const line = trimTrailingCarriage(parser.buffer[0..parser.len]);
                if (cfg.trace_network) {
                    std.log.debug("network: complete line host={s} len={}", .{ ctx.host, line.len });
                }
                if (line.len > 0) parseAndEnqueue(ctx.shared, ctx.io, line, ctx.host);
                parser.len = 0;
            }
            continue;
        }

        if (parser.overflowed) continue;

        if (parser.len < parser.buffer.len) {
            parser.buffer[parser.len] = byte;
            parser.len += 1;
        } else {
            if (cfg.trace_network) {
                std.log.warn("network: parser line exceeds max_line_bytes={} host={s}", .{ cfg.max_line_bytes, ctx.host });
            }
            parser.overflowed = true;
        }
    }
}

fn trimTrailingCarriage(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn parseAndEnqueue(shared: *EndpointShared, io: Io, line: []const u8, host: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const report = std.json.parseFromSliceLeaky(common.Report, arena.allocator(), line, .{}) catch |err| {
        const preview_len = @min(line.len, 160);
        std.log.warn("client: json parse failed from {s}, len={}, err={}, payload='{s}'", .{ host, line.len, err, line[0..preview_len] });
        incrementParseError(shared, io);
        return;
    };
    if (cfg.trace_network) {
        std.log.debug("network: parsed report host={s} ts={} a=[{},{},{}] g=[{},{},{}] e={} b={}", .{
            host,
            report.sample.timestamp,
            report.sample.accel_x,
            report.sample.accel_y,
            report.sample.accel_z,
            report.sample.gyro_x,
            report.sample.gyro_y,
            report.sample.gyro_z,
            report.elevation,
            report.bearing,
        });
    }

    shared.queue.putOne(io, report) catch |err| switch (err) {
        error.Canceled,
        error.Closed,
        => return,
    };
    if (cfg.trace_network) {
        std.log.debug("network: queued report host={s}", .{host});
    }
}

fn sleepReconnect(io: Io, stop: *const Atomic(bool)) Io.Cancelable!void {
    if (stop.load(.acquire)) return;
    if (cfg.trace_network) {
        std.log.info("network: sleeping reconnect_ms={}ms", .{cfg.reconnect_ms});
    }
    try Io.sleep(io, Io.Duration.fromMilliseconds(cfg.reconnect_ms), .real);
}

fn setState(shared: *EndpointShared, io: Io, state: ConnectionState) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.state = state;
}

fn incrementParseError(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.parse_errors += 1;
}

fn incrementDisconnect(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.disconnects += 1;
}

fn incrementReconnect(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.reconnects += 1;
}

fn incrementPartialDisconnect(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.partial_disconnects += 1;
}

fn incrementConnectFailure(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.connect_failures += 1;
}

fn connectToHost(io: Io, host: []const u8, port: u16) anyerror!Io.net.Stream {
    if (cfg.trace_network) {
        std.log.info("network: connectToHost begin host={s} port={}", .{ host, port });
    }
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        if (cfg.trace_network) {
            std.log.debug("network: using IpAddress.connect host={s} port={}", .{ host, port });
        }
        return Io.net.IpAddress.connect(addr, io, .{ .mode = .stream, .protocol = .tcp, .timeout = .none });
    } else |_| {
        const name = try Io.net.HostName.init(host);
        if (cfg.trace_network) {
            std.log.debug("network: using HostName.connect host={s} port={}", .{ host, port });
        }
        return Io.net.HostName.connect(name, io, port, .{ .mode = .stream, .protocol = .tcp, .timeout = .none });
    }
}
