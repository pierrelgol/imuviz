const std = @import("std");
const rl = @import("raylib");
const cfg = @import("config.zig");
const History = @import("history.zig").History;

pub const Estimate = struct {
    available: bool = false,
    lag_seconds: f64 = 0.0,
    correlation: f64 = 0.0,
};

pub const Estimator = struct {
    last_update_sec: f64 = -1e9,
    last: Estimate = .{},

    pub fn update(self: *Estimator, histories: []const *const History, connected: []const bool) void {
        if (!cfg.alignment.enabled) {
            self.last = .{};
            return;
        }
        if (histories.len < 2 or connected.len < 2) {
            self.last = .{};
            return;
        }
        const now = rl.getTime();
        if ((now - self.last_update_sec) < cfg.alignment.update_interval_seconds) return;
        self.last_update_sec = now;

        if (!connected[0] or !connected[1]) {
            self.last = .{};
            return;
        }
        self.last = estimateLagSeconds(histories[0], histories[1], .gyro_norm);
    }
};

fn estimateLagSeconds(a: *const History, b: *const History, kind: History.TraceKind) Estimate {
    const n_max = @min(@min(a.len, b.len), cfg.alignment.max_samples);
    if (n_max < cfg.alignment.min_points) return .{};

    const start_a = a.len - n_max;
    const start_b = b.len - n_max;
    const sample_period = estimateSamplePeriodSeconds(a, b, start_a, start_b, n_max);
    if (!(sample_period > 0.0 and std.math.isFinite(sample_period))) return .{};

    const max_lag_samples_f = cfg.alignment.max_lag_seconds / sample_period;
    const max_lag_samples: usize = @min(@as(usize, @intFromFloat(@max(1.0, max_lag_samples_f))), n_max / 3);
    if (max_lag_samples == 0) return .{};

    var best_corr: f64 = -2.0;
    var best_lag_samples: i64 = 0;
    var lag_i: i64 = -@as(i64, @intCast(max_lag_samples));
    while (lag_i <= @as(i64, @intCast(max_lag_samples))) : (lag_i += 1) {
        const corr = pearsonAtLag(a, b, kind, start_a, start_b, n_max, lag_i) orelse continue;
        if (corr > best_corr) {
            best_corr = corr;
            best_lag_samples = lag_i;
        }
    }

    if (!std.math.isFinite(best_corr) or best_corr < -1.0) return .{};
    return .{
        .available = true,
        .lag_seconds = @as(f64, @floatFromInt(best_lag_samples)) * sample_period,
        .correlation = best_corr,
    };
}

fn pearsonAtLag(
    a: *const History,
    b: *const History,
    kind: History.TraceKind,
    start_a: usize,
    start_b: usize,
    n: usize,
    lag_samples: i64,
) ?f64 {
    var ia0: usize = start_a;
    var ib0: usize = start_b;
    var count: usize = n;

    if (lag_samples > 0) {
        const lag_u: usize = @intCast(lag_samples);
        if (lag_u >= n) return null;
        ib0 += lag_u;
        count -= lag_u;
    } else if (lag_samples < 0) {
        const lag_u: usize = @intCast(-lag_samples);
        if (lag_u >= n) return null;
        ia0 += lag_u;
        count -= lag_u;
    }
    if (count < cfg.alignment.min_points / 2) return null;

    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    var sxy: f64 = 0;

    for (0..count) |i| {
        const x: f64 = a.value(ia0 + i, kind);
        const y: f64 = b.value(ib0 + i, kind);
        sx += x;
        sy += y;
        sxx += x * x;
        syy += y * y;
        sxy += x * y;
    }

    const n_f = @as(f64, @floatFromInt(count));
    const num = n_f * sxy - sx * sy;
    const den_l = n_f * sxx - sx * sx;
    const den_r = n_f * syy - sy * sy;
    const den = @sqrt(@max(0.0, den_l * den_r));
    if (den <= 1e-12) return null;
    return num / den;
}

fn estimateSamplePeriodSeconds(a: *const History, b: *const History, start_a: usize, start_b: usize, n: usize) f64 {
    if (n < 2) return 0.0;
    const dt_a = a.sample(start_a + n - 1).timestamp - a.sample(start_a).timestamp;
    const dt_b = b.sample(start_b + n - 1).timestamp - b.sample(start_b).timestamp;
    const denom = @as(f64, @floatFromInt(n - 1));
    return ((dt_a / denom) + (dt_b / denom)) * 0.5;
}
