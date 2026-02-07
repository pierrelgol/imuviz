var should_stop: Atomic(bool) = .init(false);

const Args = struct {
    ip: [:0]const u8 = "0.0.0.0",
    port: u16 = 9999,
    ping_port: u16 = 10000,
    module_id: [4]u8 = [_]u8{'X'} ** 4,
    shm_path: [:0]const u8 = "/tmp/mmapIMU",

    pub const init: Args = .{};

    pub fn fromArgIter(it: *std.process.Args.Iterator) error{ InvalidArgument, InvalidValue }!Args {
        var self: Args = .init;
        var ping_port_explicit = false;

        if (it.skip() == false) {
            return self;
        }

        while (it.next()) |arg| {
            const trimmed = std.mem.trim(u8, arg, " \t\r\n");

            if (std.mem.startsWith(u8, trimmed, "--port")) {
                const port_string = it.next() orelse return error.InvalidValue;
                self.port = std.fmt.parseInt(u16, port_string, 10) catch return error.InvalidValue;
                if (!ping_port_explicit) self.ping_port = self.port +| 1;
            }
            if (std.mem.startsWith(u8, trimmed, "--ping_port")) {
                const ping_string = it.next() orelse return error.InvalidValue;
                self.ping_port = std.fmt.parseInt(u16, ping_string, 10) catch return error.InvalidValue;
                ping_port_explicit = true;
            }

            if (std.mem.startsWith(u8, trimmed, "--module_id")) {
                const module_id = it.next() orelse return error.InvalidValue;
                if (module_id.len != 4) return error.InvalidArgument;
                @memcpy(self.module_id[0..4], module_id[0..4]);
            }

            if (std.mem.startsWith(u8, trimmed, "--shm_path")) {
                self.shm_path = it.next() orelse return error.InvalidValue;
            }
            if (std.mem.startsWith(u8, trimmed, "--ip")) {
                self.ip = it.next() orelse return error.InvalidValue;
            }
        }

        return self;
    }
};

const Server = struct {
    sock: Io.net.Socket = undefined,
    client: ?Io.net.Socket = null,

    pub const init: Server = .{};

    pub fn socket(self: *Server) !void {
        const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreationFailed;
        self.sock = .{ .handle = @intCast(fd), .address = undefined };
    }

    pub fn bind(self: *Server, ip: [:0]const u8, port: u16) !void {
        const addr = try std.Io.net.Ip4Address.parse(ip, port);
        self.sock.address = .{ .ip4 = addr };

        var sock_addr: linux.sockaddr.in = .{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.bytesToValue(u32, &addr.bytes),
            .zero = .{0} ** 8,
        };

        const result = linux.bind(
            self.sock.handle,
            @ptrCast(&sock_addr),
            @sizeOf(linux.sockaddr.in),
        );
        if (result < 0) return error.BindFailed;
    }

    pub fn listen(self: *Server, backlog: u31) !void {
        const result = linux.listen(self.sock.handle, backlog);
        if (result < 0) return error.ListenFailed;
    }

    pub fn acceptClient(self: *Server) anyerror!Io.net.Socket {
        if (self.client != null) return error.ClientAlreadyConnected;

        var addr: linux.sockaddr.in = undefined;
        var addr_len: u32 = @sizeOf(linux.sockaddr.in);

        const client_fd = linux.accept4(
            self.sock.handle,
            @ptrCast(&addr),
            &addr_len,
            linux.SOCK.CLOEXEC,
        );

        if (client_fd > @as(usize, @bitCast(@as(isize, -4096)))) {
            const errno = @as(usize, @bitCast(-@as(isize, @bitCast(client_fd))));
            return switch (@as(linux.E, @enumFromInt(errno))) {
                .AGAIN => error.WouldBlock,
                .INTR => error.Interrupted,
                .CONNABORTED => error.ConnectionAborted,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                else => error.AcceptFailed,
            };
        }

        const client_socket = Io.net.Socket{
            .handle = @intCast(client_fd),
            .address = .{ .ip4 = .{
                .bytes = std.mem.toBytes(@as(u32, @bitCast(addr.addr))),
                .port = std.mem.bigToNative(u16, addr.port),
            } },
        };

        self.client = client_socket;
        return client_socket;
    }

    pub fn configureClientSocket(self: *Server) !void {
        const client = self.client orelse return error.NoClientConnected;

        const val: i32 = 1;
        const result = linux.setsockopt(
            client.handle,
            linux.IPPROTO.TCP,
            linux.TCP.NODELAY,
            @ptrCast(&val),
            @sizeOf(i32),
        );
        if (result < 0) return error.SetSockOptFailed;
    }

    pub fn disconnectClient(self: *Server, io: Io) void {
        if (self.client) |*client| {
            client.close(io);
            self.client = null;
        }
    }

    pub fn deinit(self: *Server, io: Io) void {
        self.disconnectClient(io);
        self.sock.close(io);
    }

    pub fn setNonBlocking(self: *Server) !void {
        const flags = linux.fcntl(self.sock.handle, linux.F.GETFL, 0);
        if (flags < 0) return error.FcntlFailed;
        const new_flags = @as(u32, @intCast(flags)) | linux.SOCK.NONBLOCK;
        const result = linux.fcntl(self.sock.handle, linux.F.SETFL, new_flags);
        if (result < 0) return error.FcntlFailed;
    }

    pub fn setLowLatency(self: *Server) !void {
        const val: i32 = 1;
        const result = linux.setsockopt(
            self.sock.handle,
            linux.IPPROTO.TCP,
            linux.TCP.NODELAY,
            @ptrCast(&val),
            @sizeOf(i32),
        );
        if (result < 0) return error.SetSockOptFailed;
    }

    pub fn setReusePort(self: *Server) !void {
        const val: i32 = 1;
        const result = linux.setsockopt(
            self.sock.handle,
            linux.SOL.SOCKET,
            linux.SO.REUSEPORT,
            @ptrCast(&val),
            @sizeOf(i32),
        );
        if (result < 0) return error.SetSockOptFailed;
    }

    pub fn setReuseAddress(self: *Server) !void {
        const val: i32 = 1;
        const result = linux.setsockopt(
            self.sock.handle,
            linux.SOL.SOCKET,
            linux.SO.REUSEADDR,
            @ptrCast(&val),
            @sizeOf(i32),
        );
        if (result < 0) return error.SetSockOptFailed;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    setupSignalHandler();

    var args = init.minimal.args.iterateAllocator(arena) catch |err| {
        log.err("{}", .{err});
        return err;
    };
    defer args.deinit();

    const parsed = Args.fromArgIter(&args) catch |err| {
        log.err("{}", .{err});
        return err;
    };

    const cwd = Io.Dir.cwd();
    var shm_file = cwd.createFile(io, parsed.shm_path, .{ .truncate = false, .read = true }) catch |err| {
        log.err("failed to create shared memory file '{s}': {}", .{ parsed.shm_path, err });
        return err;
    };
    defer shm_file.close(io);

    var shm_mmap = shm_file.createMemoryMap(io, .{ .len = REPORT_BYTE_SIZE }) catch |err| {
        log.err("failed to create memory mapping for shared memory file: {}", .{err});
        return err;
    };
    defer shm_mmap.destroy(io);

    var server: Server = .init;
    defer server.deinit(io);

    server.socket() catch |err| {
        log.err("{}", .{err});
        return err;
    };

    server.setNonBlocking() catch |err| {
        log.err("{}", .{err});
        return err;
    };

    server.setReuseAddress() catch |err| {
        log.err("{}", .{err});
        return err;
    };

    server.setReusePort() catch |err| {
        log.err("{}", .{err});
        return err;
    };

    server.setLowLatency() catch |err| {
        log.err("{}", .{err});
        return err;
    };

    server.bind(parsed.ip, parsed.port) catch |err| {
        log.err("{}", .{err});
        return err;
    };

    server.listen(128) catch |err| {
        log.err("{}", .{err});
        return err;
    };

    log.info("Server listening on {s}:{}", .{ parsed.ip, parsed.port });
    log.info("Ping UDP listening on {s}:{}", .{ parsed.ip, parsed.ping_port });
    log.info("Waiting for client connection...", .{});

    var ping_addr = Io.net.IpAddress.parse(parsed.ip, parsed.ping_port) catch |err| {
        log.err("failed to parse ping address: {}", .{err});
        return err;
    };
    var ping_socket = Io.net.IpAddress.bind(&ping_addr, io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        log.err("failed to bind ping socket: {}", .{err});
        return err;
    };
    defer ping_socket.close(io);
    var ping_buffer: [64]u8 = undefined;

    const State = enum { no_client, client_accepted, client_configured, client_disconnected, new_data, client_written, wait, wait_long };
    const state: State = .no_client;

    var client_write_buffer: [4096]u8 = undefined;
    var client_writer: ?Io.net.Stream.Writer = null;
    var client_out: ?*Io.Writer = null;

    state: switch (state) {
        .no_client => {
            servicePing(io, &ping_socket, &ping_buffer);
            log.debug("State: no_client - waiting for connection", .{});
            if (should_stop.load(.acquire)) return;
            _ = server.acceptClient() catch |err| switch (err) {
                error.WouldBlock => continue :state .wait_long,
                error.Interrupted, error.ConnectionAborted => continue :state .no_client,
                error.ClientAlreadyConnected => continue :state .client_disconnected,
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => continue :state .wait_long,
                else => continue :state .wait_long,
            };
            log.info("Client connected", .{});
            continue :state .client_accepted;
        },
        .client_accepted => {
            log.debug("State: client_accepted - configuring socket", .{});
            server.configureClientSocket() catch |err| {
                log.err("Failed to configure client socket: {}", .{err});
                server.disconnectClient(io);
                continue :state .wait_long;
            };
            log.debug("Client socket configured (TCP_NODELAY)", .{});

            const client = server.client.?;
            client_writer = Io.net.Stream.Writer.init(.{ .socket = client }, io, &client_write_buffer);
            client_out = &client_writer.?.interface;
            log.debug("Client writer initialized", .{});
            continue :state .client_configured;
        },
        .client_configured => {
            servicePing(io, &ping_socket, &ping_buffer);
            log.debug("State: client_configured - reading shared memory", .{});
            shm_mmap.read(io) catch |err| {
                log.err("Failed to read shared memory: {}", .{err});
                server.disconnectClient(io);
                continue :state .wait_long;
            };
            log.debug("Shared memory read complete", .{});
            continue :state .new_data;
        },
        .new_data => {
            servicePing(io, &ping_socket, &ping_buffer);
            log.debug("State: new_data - deserializing report", .{});
            var shm_fixed_reader: Io.Reader = .fixed(shm_mmap.memory[0..REPORT_BYTE_SIZE]);
            const report = common.Report.deserialize(&shm_fixed_reader, builtin.cpu.arch.endian()) catch |err| {
                log.err("Failed to deserialize report: {}", .{err});
                continue :state .wait;
            };
            log.debug("Report deserialized: timestamp={}, elevation={}, bearing={}", .{ report.sample.timestamp, report.elevation, report.bearing });

            const writer = client_out orelse {
                log.err("Client writer not available", .{});
                continue :state .client_disconnected;
            };

            writer.print("{f}", .{report}) catch |err| {
                log.err("Failed to serialize report to JSON: {}", .{err});
                continue :state .client_disconnected;
            };

            writer.writeByte('\n') catch |err| {
                log.err("Failed to write to client: {}", .{err});
                continue :state .client_disconnected;
            };
            log.debug("Newline written", .{});

            continue :state .client_written;
        },
        .client_written => {
            log.debug("State: client_written - flushing buffer", .{});
            const writer = client_out orelse {
                log.err("Client writer not available", .{});
                continue :state .client_disconnected;
            };

            writer.flush() catch |err| {
                log.err("Failed to flush to client: {}", .{err});
                continue :state .client_disconnected;
            };
            log.debug("Buffer flushed to client", .{});

            continue :state .wait;
        },
        .wait => {
            servicePing(io, &ping_socket, &ping_buffer);
            log.debug("State: wait - sleeping 1ms (client connected)", .{});
            if (should_stop.load(.acquire)) return;

            Io.sleep(io, Io.Duration.fromMilliseconds(4), .real) catch |err| {
                if (err == error.Canceled) return;
                return err;
            };
            continue :state .client_configured;
        },
        .wait_long => {
            servicePing(io, &ping_socket, &ping_buffer);
            log.debug("State: wait_long - sleeping 33ms (no client)", .{});
            if (should_stop.load(.acquire)) return;

            Io.sleep(io, Io.Duration.fromMilliseconds(33), .real) catch |err| {
                if (err == error.Canceled) return;
                return err;
            };
            continue :state .no_client;
        },
        .client_disconnected => {
            log.info("State: client_disconnected - cleaning up", .{});
            server.disconnectClient(io);
            log.info("Client disconnected, waiting for new connection", .{});
            if (should_stop.load(.acquire)) return;
            continue :state .wait_long;
        },
    }
}

fn servicePing(io: Io, ping_socket: *Io.net.Socket, ping_buffer: *[64]u8) void {
    const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(0), .clock = .real } };
    while (true) {
        const msg = ping_socket.receiveTimeout(io, ping_buffer, timeout) catch |err| switch (err) {
            error.Timeout => return,
            else => return,
        };
        if (msg.data.len < 8) continue;
        ping_socket.send(io, &msg.from, msg.data) catch {};
    }
}

fn handleSignal(_: std.os.linux.SIG) callconv(.c) void {
    should_stop.store(true, .release);
}

fn setupSignalHandler() void {
    const signals: std.os.linux.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &signals, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &signals, null);
}

const REPORT_BYTE_SIZE = @bitSizeOf(common.Report) / 8;

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const heap = std.heap;
const log = std.log;
const Atomic = std.atomic.Value;
const builtin = @import("builtin");
const common = @import("common");
const linux = std.os.linux;
