const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Sample = packed struct(u160) {
    timestamp: i64 = 0,
    accel_x: i16 = 0,
    accel_y: i16 = 0,
    accel_z: i16 = 0,
    gyro_x: i16 = 0,
    gyro_y: i16 = 0,
    gyro_z: i16 = 0,

    pub const init: Sample = .{};

    pub fn fromBytes(bytes: [@sizeOf(Sample)]u8) Sample {
        return std.mem.bytesToValue(Sample, bytes[0..]);
    }

    pub fn asBytes(self: *Sample) []u8 {
        return std.mem.asBytes(self);
    }

    pub fn deserialize(reader: *Io.Reader, endian: std.builtin.Endian) error{ ReadFailed, EndOfStream }!Sample {
        return reader.takeStruct(@This(), endian);
    }

    pub fn serialize(self: *const Sample, writer: *Io.Writer, endian: std.builtin.Endian) error{WriteFailed}!void {
        return writer.writeStruct(self.*, endian);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const formatter: std.json.Formatter(Sample) = .{
            .value = self,
            .options = .{},
        };
        try formatter.format(writer);
    }

    comptime {
        if (@bitSizeOf(Sample) != 160) @compileError("Invalid size");
    }
};

pub const Report = packed struct(u192) {
    sample: Sample = .init,
    elevation: i16 = 0,
    bearing: i16 = 0,

    pub const init: Report = .{};

    pub fn fromBytes(bytes: [@sizeOf(Report)]u8) Report {
        return std.mem.bytesToValue(Report, bytes[0..]);
    }

    pub fn asBytes(self: *Report) []u8 {
        return std.mem.asBytes(self);
    }

    pub fn deserialize(reader: *Io.Reader, endian: std.builtin.Endian) error{ ReadFailed, EndOfStream }!Report {
        return reader.takeStruct(@This(), endian);
    }

    pub fn serialize(self: *const Report, writer: *Io.Writer, endian: std.builtin.Endian) error{WriteFailed}!void {
        return writer.writeStruct(self.*, endian);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const formatter: std.json.Formatter(Report) = .{
            .value = self,
            .options = .{},
        };
        try formatter.format(writer);
    }

    comptime {
        if (@bitSizeOf(Report) != 192) @compileError("Invalid size");
    }
};

const testing = std.testing;

test "Sample - fromBytes" {
    const bytes: [@sizeOf(Sample)]u8 = @splat(0);
    const expected: Sample = .init;
    const actual = Sample.fromBytes(bytes);
    try testing.expectEqual(expected, actual);
}

test "Sample - asBytes" {
    var self: Sample = .init;
    const expected: [@sizeOf(Sample)]u8 = @splat(0);
    const actual = Sample.asBytes(&self);
    try testing.expectEqualSlices(u8, &expected, actual);
}

test "Sample - deserialize" {
    var expected: Sample = .init;
    var fixed_reader: Io.Reader = .fixed(expected.asBytes());
    const reader: *Io.Reader = &fixed_reader;
    const actual = Sample.deserialize(reader, builtin.cpu.arch.endian()) catch unreachable;
    try testing.expectEqual(expected, actual);
}

test "Sample - serialize" {
    var self: Sample = .init;
    var expected: [@sizeOf(Sample)]u8 = @splat(0);
    var fixed_writer: Io.Writer = .fixed(&expected);
    const writer: *Io.Writer = &fixed_writer;
    self.serialize(writer, builtin.cpu.arch.endian()) catch unreachable;
    try testing.expectEqualSlices(u8, self.asBytes(), writer.buffer);
}

test "Sample - format" {
    var actual: [256]u8 = @splat(0);
    var fixed_writer: Io.Writer = .fixed(&actual);
    const writer: *Io.Writer = &fixed_writer;
    const self: Sample = .init;
    try writer.print("{f}", .{self});
    const expected = "{\"timestamp\":0,\"accel_x\":0,\"accel_y\":0,\"accel_z\":0,\"gyro_x\":0,\"gyro_y\":0,\"gyro_z\":0}";
    try testing.expectEqualSlices(u8, expected, actual[0..expected.len]);
}

test "Report - fromBytes" {
    const bytes: [@sizeOf(Report)]u8 = @splat(0);
    const expected: Report = .init;
    const actual = Report.fromBytes(bytes);
    try testing.expectEqual(expected, actual);
}

test "Report - asBytes" {
    var self: Report = .init;
    const expected: [@sizeOf(Report)]u8 = @splat(0);
    const actual = Report.asBytes(&self);
    try testing.expectEqualSlices(u8, &expected, actual);
}

test "Report - deserialize" {
    var expected: Report = .init;
    var fixed_reader: Io.Reader = .fixed(expected.asBytes());
    const reader: *Io.Reader = &fixed_reader;
    const actual = Report.deserialize(reader, builtin.cpu.arch.endian()) catch unreachable;
    try testing.expectEqual(expected, actual);
}

test "Report - serialize" {
    var self: Report = .init;
    var expected: [@sizeOf(Report)]u8 = @splat(0);
    var fixed_writer: Io.Writer = .fixed(&expected);
    const writer: *Io.Writer = &fixed_writer;
    self.serialize(writer, builtin.cpu.arch.endian()) catch unreachable;
    try testing.expectEqualSlices(u8, self.asBytes(), writer.buffer);
}

test "Report - format" {
    var actual: [256]u8 = @splat(0);
    var fixed_writer: Io.Writer = .fixed(&actual);
    const writer: *Io.Writer = &fixed_writer;
    const self: Report = .init;
    try writer.print("{f}", .{self});
    const expected = "{\"sample\":{\"timestamp\":0,\"accel_x\":0,\"accel_y\":0,\"accel_z\":0,\"gyro_x\":0,\"gyro_y\":0,\"gyro_z\":0},\"elevation\":0,\"bearing\":0}";
    try testing.expectEqualSlices(u8, expected, actual[0..expected.len]);
}
