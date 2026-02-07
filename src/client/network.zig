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
    rx_bytes_total: u64,
    ping_rtt_ms: f32,
    ping_sent: u64,
    ping_timeouts: u64,
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
    rx_bytes_total: u64 = 0,
    ping_rtt_ms: f32 = -1.0,
    ping_sent: u64 = 0,
    ping_timeouts: u64 = 0,

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
        std.debug.assert(endpoint_index < self.endpoint_count);
        return self.endpoints[endpoint_index].queue.getUncancelable(self.io, out, 0) catch |err| switch (err) {
            error.Closed => 0,
        };
    }

    pub fn snapshot(self: *ClientNetwork, endpoint_index: usize) EndpointSnapshot {
        std.debug.assert(endpoint_index < self.endpoint_count);
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
            .rx_bytes_total = shared.rx_bytes_total,
            .ping_rtt_ms = shared.ping_rtt_ms,
            .ping_sent = shared.ping_sent,
            .ping_timeouts = shared.ping_timeouts,
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
    var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer parse_arena.deinit();

    while (!ctx.stop.load(.acquire)) {
        connect_attempt += 1;
        if (cfg.trace_network) {
            std.log.info("network: attempt={} host={s} port={} -> connecting", .{ connect_attempt, ctx.host, ctx.port });
        }
        setState(ctx.shared, io, .connecting);

        const connected = connectToHost(io, ctx.host, ctx.port) catch |err| {
            incrementConnectFailure(ctx.shared, io);
            std.log.warn("client: connect failed to {s}:{}: {}", .{ ctx.host, ctx.port, err });
            setState(ctx.shared, io, .disconnected);
            try sleepReconnect(io, ctx.stop);
            continue;
        };
        var stream = connected.stream;
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
        var ping_ctx = PingContext.init(io, connected.address, ctx.port + cfg.ping.port_offset) catch |err| blk: {
            if (cfg.trace_network) std.log.warn("network: ping init failed host={s} err={}", .{ ctx.host, err });
            break :blk PingContext.disabled();
        };
        defer ping_ctx.deinit(io);

        const loop_exit = try runReadLoop(ctx, &stream, &parser, &parse_arena, &ping_ctx);
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

fn runReadLoop(
    ctx: *WorkerContext,
    stream: *Io.net.Stream,
    parser: *LineParser,
    parse_arena: *std.heap.ArenaAllocator,
    ping_ctx: *PingContext,
) Io.Cancelable!LoopExit {
    var recv_buffer: [cfg.recv_buffer_bytes]u8 = undefined;
    var iter: u64 = 0;

    while (!ctx.stop.load(.acquire)) {
        iter += 1;
        pingTick(ping_ctx, ctx);
        const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(cfg.poll_timeout_ms), .clock = .real } };

        const message = stream.socket.receiveTimeout(ctx.io, &recv_buffer, timeout) catch |err| switch (err) {
            error.Timeout => {
                pingTick(ping_ctx, ctx);
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

        incrementRxBytes(ctx.shared, ctx.io, message.data.len);
        feedParser(parser, message.data, ctx, parse_arena);
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

fn feedParser(parser: *LineParser, chunk: []const u8, ctx: *WorkerContext, parse_arena: *std.heap.ArenaAllocator) void {
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
                if (line.len > 0) parseAndEnqueue(ctx.shared, ctx.io, line, ctx.host, parse_arena);
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

fn parseAndEnqueue(shared: *EndpointShared, io: Io, line: []const u8, host: []const u8, parse_arena: *std.heap.ArenaAllocator) void {
    _ = parse_arena.reset(.retain_capacity);
    const report = std.json.parseFromSliceLeaky(common.Report, parse_arena.allocator(), line, .{}) catch |err| {
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

fn incrementRxBytes(shared: *EndpointShared, io: Io, n: usize) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.rx_bytes_total += n;
}

fn setPingRtt(shared: *EndpointShared, io: Io, rtt_ms: f32) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.ping_rtt_ms = rtt_ms;
}

fn incrementPingSent(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.ping_sent += 1;
}

fn incrementPingTimeout(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.ping_timeouts += 1;
}

const PingContext = struct {
    enabled: bool = false,
    socket: ?Io.net.Socket = null,
    dest: Io.net.IpAddress = undefined,
    seq: u32 = 1,
    pending_seq: u32 = 0,
    pending_send_ts: Io.Timestamp = .zero,
    last_sent_ts: Io.Timestamp = .zero,
    pending: bool = false,

    fn disabled() PingContext {
        return .{};
    }

    fn init(io: Io, base_addr: Io.net.IpAddress, ping_port: u16) !PingContext {
        if (!cfg.ping.enabled) return .{};
        var dest = base_addr;
        switch (dest) {
            .ip4 => |*a| a.port = ping_port,
            .ip6 => |*a| a.port = ping_port,
        }

        const bind_addr: Io.net.IpAddress = switch (dest) {
            .ip4 => .{ .ip4 = Io.net.Ip4Address.unspecified(0) },
            .ip6 => .{ .ip6 = Io.net.Ip6Address.unspecified(0) },
        };
        const socket = try Io.net.IpAddress.bind(&bind_addr, io, .{ .mode = .dgram, .protocol = .udp });
        return .{
            .enabled = true,
            .socket = socket,
            .dest = dest,
            .last_sent_ts = Io.Timestamp.now(io, .boot),
        };
    }

    fn deinit(self: *PingContext, io: Io) void {
        if (self.socket) |*s| s.close(io);
        self.socket = null;
        self.pending = false;
    }
};

fn pingTick(ping: *PingContext, ctx: *WorkerContext) void {
    if (!ping.enabled or ping.socket == null) return;
    const io = ctx.io;
    const now = Io.Timestamp.now(io, .boot);

    if (ping.pending) {
        const elapsed_ms = ping.pending_send_ts.durationTo(now).toMilliseconds();
        if (elapsed_ms >= cfg.ping.timeout_ms) {
            ping.pending = false;
            incrementPingTimeout(ctx.shared, io);
        }
    }

    if (!ping.pending) {
        const since_last_ms = ping.last_sent_ts.durationTo(now).toMilliseconds();
        if (since_last_ms >= cfg.ping.interval_ms) {
            sendPing(ping, ctx);
        }
    }

    recvPingPong(ping, ctx, now);
}

fn sendPing(ping: *PingContext, ctx: *WorkerContext) void {
    const socket = &(ping.socket.?);
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], cfg.ping.magic, .little);
    std.mem.writeInt(u32, payload[4..8], ping.seq, .little);
    socket.send(ctx.io, &ping.dest, &payload) catch return;
    ping.pending = true;
    ping.pending_seq = ping.seq;
    ping.pending_send_ts = Io.Timestamp.now(ctx.io, .boot);
    ping.last_sent_ts = ping.pending_send_ts;
    ping.seq +%= 1;
    incrementPingSent(ctx.shared, ctx.io);
}

fn recvPingPong(ping: *PingContext, ctx: *WorkerContext, now: Io.Timestamp) void {
    const socket = &(ping.socket.?);
    var recv_buf: [64]u8 = undefined;
    const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(0), .clock = .real } };
    const msg = socket.receiveTimeout(ctx.io, &recv_buf, timeout) catch |err| switch (err) {
        error.Timeout => return,
        else => return,
    };
    if (msg.data.len < 8) return;
    const magic = std.mem.readInt(u32, msg.data[0..4], .little);
    const seq = std.mem.readInt(u32, msg.data[4..8], .little);
    if (magic != cfg.ping.magic) return;
    if (!ping.pending or seq != ping.pending_seq) return;
    ping.pending = false;
    const rtt_ms: f32 = @floatFromInt(ping.pending_send_ts.durationTo(now).toMilliseconds());
    setPingRtt(ctx.shared, ctx.io, rtt_ms);
}

const ConnectResult = struct {
    stream: Io.net.Stream,
    address: Io.net.IpAddress,
};

fn connectToHost(io: Io, host: []const u8, port: u16) anyerror!ConnectResult {
    if (cfg.trace_network) {
        std.log.info("network: connectToHost begin host={s} port={}", .{ host, port });
    }
    const addr = Io.net.IpAddress.parse(host, port) catch try Io.net.IpAddress.resolve(io, host, port);
    const stream = try Io.net.IpAddress.connect(addr, io, .{ .mode = .stream, .protocol = .tcp, .timeout = .none });
    return .{ .stream = stream, .address = addr };
}
