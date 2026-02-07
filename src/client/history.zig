const std = @import("std");
const common = @import("common");
const cfg = @import("config.zig");

pub const History = struct {
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

    pub fn appendReport(self: *History, report: common.Report) void {
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
    }

    pub fn index(self: *const History, logical_index: usize) usize {
        return (self.head + logical_index) % cfg.max_history;
    }

    pub fn latestTimestamp(self: *const History) ?f64 {
        if (self.len == 0) return null;
        return self.timestamp[self.index(self.len - 1)];
    }

    pub fn value(self: *const History, logical_index: usize, kind: TraceKind) f32 {
        const idx = self.index(logical_index);
        return switch (kind) {
            .accel_x => self.accel_x[idx],
            .accel_y => self.accel_y[idx],
            .accel_z => self.accel_z[idx],
            .gyro_norm => self.gyro_norm[idx],
            .elevation => self.elevation[idx],
            .bearing => self.bearing[idx],
        };
    }

    fn trimToWindow(self: *History) void {
        if (self.len == 0) return;

        const latest_t = self.timestamp[self.index(self.len - 1)];
        const cutoff = latest_t - cfg.history_window_seconds;

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
