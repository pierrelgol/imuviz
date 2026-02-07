const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const ImuShmSchema = packed struct(u192) {
    timestamp: i64 = 0,
    accel_x: i16 = 0,
    accel_y: i16 = 0,
    accel_z: i16 = 0,
    gyro_x: i16 = 0,
    gyro_y: i16 = 0,
    gyro_z: i16 = 0,
    elevation: i16 = 0,
    bearing: i16 = 0,

    pub const init: ImuShmSchema = .{};

    pub fn fromBytes(bytes: [@sizeOf(ImuShmSchema)]u8) ImuShmSchema {
        return std.mem.bytesToValue(ImuShmSchema, bytes[0..]);
    }

    pub fn asBytes(self: *ImuShmSchema) []u8 {
        return std.mem.asBytes(self);
    }

    pub fn deserialize(reader: *Io.Reader, endian: std.builtin.Endian) error{ ReadFailed, EndOfStream }!ImuShmSchema {
        return reader.takeStruct(@This(), endian);
    }

    pub fn serialize(self: *const ImuShmSchema, writer: *Io.Writer, endian: std.builtin.Endian) error{WriteFailed}!void {
        return writer.writeStruct(self.*, endian);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const formatter: std.json.Formatter(ImuShmSchema) = .{
            .value = self,
            .options = .{},
        };
        try formatter.format(writer);
    }

    comptime {
        if (@bitSizeOf(ImuShmSchema) != 192) @compileError("Invalid size");
    }
};

const testing = std.testing;

test "ImuShmSchema - imuShmSchemafromBytes" {
    const bytes: [@sizeOf(ImuShmSchema)]u8 = @splat(0);
    const expected: ImuShmSchema = .init;
    const actual = ImuShmSchema.fromBytes(bytes);
    try testing.expectEqual(expected, actual);
}

test "ImuShmSchema - bytesFromImuShmSchema" {
    var self: ImuShmSchema = .init;
    const expected: [@sizeOf(ImuShmSchema)]u8 = @splat(0);
    const actual = ImuShmSchema.asBytes(&self);
    try testing.expectEqualSlices(u8, &expected, actual);
}

test "ImuShmSchema - fromReader" {
    var expected: ImuShmSchema = .init;
    var fixed_reader: Io.Reader = .fixed(expected.asBytes());
    const reader: *Io.Reader = &fixed_reader;
    const actual = ImuShmSchema.deserialize(reader, builtin.cpu.arch.endian()) catch unreachable;
    try testing.expectEqual(expected, actual);
}

test "ImuShmSchema - toWriter" {
    var self: ImuShmSchema = .init;
    var expected: [@sizeOf(ImuShmSchema)]u8 = @splat(0);
    var fixed_writer: Io.Writer = .fixed(&expected);
    const writer: *Io.Writer = &fixed_writer;
    self.serialize(writer, builtin.cpu.arch.endian()) catch unreachable;
    try testing.expect(writer.unusedCapacityLen() == 8);
    try testing.expectEqualSlices(u8, self.asBytes(), writer.buffer);
}

test "ImuShmSchema - format" {
    var actual: [256]u8 = @splat(0);
    var fixed_writer: Io.Writer = .fixed(&actual);
    const writer: *Io.Writer = &fixed_writer;
    const self: ImuShmSchema = .init;
    try writer.print("{f}", .{self});
    const expected = "{\"timestamp\":0,\"accel_x\":0,\"accel_y\":0,\"accel_z\":0,\"gyro_x\":0,\"gyro_y\":0,\"gyro_z\":0,\"elevation\":0,\"bearing\":0}";
    try testing.expectEqualSlices(u8, expected, actual[0..expected.len]);
}
