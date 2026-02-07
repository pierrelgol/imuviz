const std = @import("std");
const common = @import("common");
const cfg = @import("config.zig");

pub const History = struct {
    options: Options = .{},
    len: usize = 0,
    head: usize = 0,
    timestamp: [cfg.max_history]f64 = undefined,
    accel_x: [cfg.max_history]f32 = undefined,
    accel_y: [cfg.max_history]f32 = undefined,
    accel_z: [cfg.max_history]f32 = undefined,
    gyro_norm: [cfg.max_history]f32 = undefined,
    elevation: [cfg.max_history]f32 = undefined,
    bearing: [cfg.max_history]f32 = undefined,

    pub const TraceKind = enum {
        accel_x,
        accel_y,
        accel_z,
        gyro_norm,
        elevation,
        bearing,
    };

    pub const Options = struct {
        window_seconds: f64 = cfg.history_window_seconds,
    };

    pub const Sample = struct {
        timestamp: f64,
        accel_x: f32,
        accel_y: f32,
        accel_z: f32,
        gyro_norm: f32,
        elevation: f32,
        bearing: f32,
    };

    pub const LogicalRange = struct {
        start: usize,
        end: usize,

        pub fn len(self: LogicalRange) usize {
            return self.end - self.start;
        }

        pub fn isEmpty(self: LogicalRange) bool {
            return self.start >= self.end;
        }
    };

    pub fn init(options: Options) History {
        std.debug.assert(options.window_seconds >= 0.0);
        return .{ .options = options };
    }

    pub fn isEmpty(self: *const History) bool {
        return self.len == 0;
    }

    pub fn appendReport(self: *History, report: common.Report) void {
        std.debug.assert(self.len <= cfg.max_history);
        std.debug.assert(self.head < cfg.max_history);
        const t = timestampToSeconds(report.sample.timestamp);
        const gx = @as(f32, @floatFromInt(report.sample.gyro_x));
        const gy = @as(f32, @floatFromInt(report.sample.gyro_y));
        const gz = @as(f32, @floatFromInt(report.sample.gyro_z));
        const gn = @sqrt(gx * gx + gy * gy + gz * gz);

        var insert_index: usize = undefined;
        if (self.len < cfg.max_history) {
            insert_index = (self.head + self.len) % cfg.max_history;
            self.len += 1;
        } else {
            insert_index = self.head;
            self.head = (self.head + 1) % cfg.max_history;
        }

        self.timestamp[insert_index] = t;
        self.accel_x[insert_index] = @floatFromInt(report.sample.accel_x);
        self.accel_y[insert_index] = @floatFromInt(report.sample.accel_y);
        self.accel_z[insert_index] = @floatFromInt(report.sample.accel_z);
        self.gyro_norm[insert_index] = gn;
        self.elevation[insert_index] = @floatFromInt(report.elevation);
        self.bearing[insert_index] = @floatFromInt(report.bearing);

        self.trimToWindow();
        std.debug.assert(self.len <= cfg.max_history);
        std.debug.assert(self.head < cfg.max_history);
    }

    pub fn index(self: *const History, logical_index: usize) usize {
        std.debug.assert(logical_index < self.len);
        return (self.head + logical_index) % cfg.max_history;
    }

    pub fn sample(self: *const History, logical_index: usize) Sample {
        const idx = self.index(logical_index);
        return .{
            .timestamp = self.timestamp[idx],
            .accel_x = self.accel_x[idx],
            .accel_y = self.accel_y[idx],
            .accel_z = self.accel_z[idx],
            .gyro_norm = self.gyro_norm[idx],
            .elevation = self.elevation[idx],
            .bearing = self.bearing[idx],
        };
    }

    pub fn latestSample(self: *const History) ?Sample {
        if (self.isEmpty()) return null;
        return self.sample(self.len - 1);
    }

    pub fn latestTimestamp(self: *const History) ?f64 {
        const s = self.latestSample() orelse return null;
        return s.timestamp;
    }

    pub fn value(self: *const History, logical_index: usize, kind: TraceKind) f32 {
        const s = self.sample(logical_index);
        return switch (kind) {
            .accel_x => s.accel_x,
            .accel_y => s.accel_y,
            .accel_z => s.accel_z,
            .gyro_norm => s.gyro_norm,
            .elevation => s.elevation,
            .bearing => s.bearing,
        };
    }

    pub fn rangeByTimestamp(self: *const History, start_ts: f64, end_ts: f64) LogicalRange {
        if (self.isEmpty() or start_ts > end_ts) return .{ .start = 0, .end = 0 };

        var start: usize = 0;
        while (start < self.len and self.sample(start).timestamp < start_ts) : (start += 1) {}

        var end = start;
        while (end < self.len and self.sample(end).timestamp <= end_ts) : (end += 1) {}

        return .{ .start = start, .end = end };
    }

    fn trimToWindow(self: *History) void {
        if (self.isEmpty()) return;

        const latest_t = self.latestTimestamp().?;
        const cutoff = latest_t - self.options.window_seconds;

        while (self.len > 0 and self.timestamp[self.head] < cutoff) {
            self.head = (self.head + 1) % cfg.max_history;
            self.len -= 1;
        }
    }
};

pub fn timestampToSeconds(ts: i64) f64 {
    const abs_ts: u64 = @intCast(@abs(ts));
    if (abs_ts >= 1_000_000_000_000_000_000) return @as(f64, @floatFromInt(ts)) / 1_000_000_000.0;
    if (abs_ts >= 1_000_000_000_000_000) return @as(f64, @floatFromInt(ts)) / 1_000_000.0;
    if (abs_ts >= 1_000_000_000_000) return @as(f64, @floatFromInt(ts)) / 1_000.0;
    return @as(f64, @floatFromInt(ts));
}
