var should_stop: Atomic(bool) = .init(false);

const Args = struct {
    shm_path: [:0]const u8 = "/tmp/mmapIMU",

    pub const init: Args = .{};

    pub fn fromArgIter(it: *std.process.Args.Iterator) error{ InvalidArgument, InvalidValue }!Args {
        var self: Args = .init;

        if (it.skip() == false) {
            return self;
        }

        while (it.next()) |arg| {
            const trimmed = std.mem.trim(u8, arg, " \t\r\n");

            if (std.mem.startsWith(u8, trimmed, "--path")) {
                self.shm_path = it.next() orelse return error.InvalidValue;
            }
        }

        return self;
    }
};

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    setupSignalHandler();

    var args = init.minimal.args.iterateAllocator(allocator) catch |err| {
        log.err("failed to iterate process arguments: {}", .{err});
        return err;
    };
    defer args.deinit();

    var parsed = Args.fromArgIter(&args) catch |err| {
        log.err("failed to parse command line arguments: {}", .{err});
        return err;
    };

    var prng: std.Random.DefaultPrng = .{ .s = undefined };
    const random = std.Random.init(&prng, std.Random.DefaultPrng.fill);

    const cwd = Io.Dir.cwd();
    var shm_file = cwd.createFile(io, parsed.shm_path, .{ .truncate = true, .read = true }) catch |err| {
        log.err("failed to create shared memory file '{s}': {}", .{ parsed.shm_path, err });
        return err;
    };
    defer shm_file.close(io);

    shm_file.setLength(io, REPORT_BYTE_SIZE) catch |err| {
        log.err("failed to set shared memory file size to {} bytes: {}", .{ REPORT_BYTE_SIZE, err });
        return err;
    };

    var shm_mmap = shm_file.createMemoryMap(io, .{ .len = REPORT_BYTE_SIZE }) catch |err| {
        log.err("failed to create memory mapping for shared memory file: {}", .{err});
        return err;
    };
    defer shm_mmap.destroy(io);

    var shm_write_buffer: [REPORT_BYTE_SIZE]u8 = undefined;
    var shm_file_writer: Io.File.Writer = .init(shm_file, io, &shm_write_buffer);
    const shm_writer: *Io.Writer = &shm_file_writer.interface;

    var shm_read_buffer: [REPORT_BYTE_SIZE]u8 = undefined;
    var shm_file_reader: Io.File.Reader = .init(shm_file, io, &shm_read_buffer);
    const shm_reader: *Io.Reader = &shm_file_reader.interface;

    while (should_stop.load(.acquire) != true) {
        var report: common.Report = .init;
        random.bytes(report.asBytes());

        io.sleep(.fromMilliseconds(33), .real) catch |err| {
            log.err("sleep failed: {}", .{err});
            return err;
        };

        report.serialize(shm_writer, builtin.cpu.arch.endian()) catch |err| {
            log.err("failed to serialize report to writer: {}", .{err});
            return err;
        };

        shm_writer.flush() catch |err| {
            log.err("failed to flush writer buffer to file: {}", .{err});
            return err;
        };

        shm_mmap.read(io) catch |err| {
            log.err("memory map sync read failed: {}", .{err});
            return err;
        };

        shm_mmap.write(io) catch |err| {
            log.err("memory map sync write failed: {}", .{err});
            return err;
        };

        if (builtin.mode == .Debug) {
            report = common.Report.deserialize(shm_reader, builtin.cpu.arch.endian()) catch |err| {
                log.err("failed to deserialize report from reader: {}", .{err});
                return err;
            };

            std.debug.print("{f}\n", .{report});
        }
    }
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const heap = std.heap;
const log = std.log;
const builtin = @import("builtin");
const Atomic = std.atomic.Value;
const common = @import("common");
const REPORT_BYTE_SIZE = @bitSizeOf(common.Report) / 8;
