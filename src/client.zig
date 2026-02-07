var should_stop: Atomic(bool) = .init(false);

const std = @import("std");
const Io = std.Io;
const log = std.log;
const Atomic = std.atomic.Value;
const builtin = @import("builtin");
const rl = @import("raylib");
const common = @import("common");
const linux = std.os.linux;

const MaxHosts = 2;
const MaxHostLen = 64;
const QueueCapacity = 4096;
const MaxHistory = 8192;
const ReconnectMs = 2000;
const ReadPollMs = 1;
const WindowSeconds = 30.0;
const RenderDebugIntervalMs: i64 = 1000;

const ConnectionState = enum {
    connecting,
    connected,
    disconnected,
};

const WireSample = struct {
    t: i64,
    a: [3]i16,
    g: [3]i16,
    e: i16,
    b: i16,
};

const Hosts = struct {
    count: u8 = 1,
    lens: [MaxHosts]u8 = [_]u8{0} ** MaxHosts,
    data: [MaxHosts][MaxHostLen]u8 = [_][MaxHostLen]u8{[_]u8{0} ** MaxHostLen} ** MaxHosts,

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
            if (i >= MaxHosts) return error.InvalidArgument;
            if (trimmed.len >= MaxHostLen) return error.InvalidArgument;

            @memcpy(hosts.data[i][0..trimmed.len], trimmed);
            hosts.lens[i] = @intCast(trimmed.len);
            i += 1;
        }
        if (i == 0) return error.InvalidValue;
        hosts.count = @intCast(i);
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
            } else if (std.mem.eql(u8, trimmed, "--port")) {
                const value = it.next() orelse return error.InvalidValue;
                self.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            } else {
                return error.InvalidArgument;
            }
        }

        return self;
    }
};

const EndpointShared = struct {
    mutex: Io.Mutex = .init,
    state: ConnectionState = .disconnected,
    queue: Io.Queue(WireSample) = undefined,
    queue_buffer: [QueueCapacity]WireSample = undefined,
    parse_errors: u64 = 0,
    disconnects: u64 = 0,

    fn init(self: *EndpointShared) void {
        self.* = .{};
        self.queue = Io.Queue(WireSample).init(&self.queue_buffer);
    }
};

const EndpointWorkerContext = struct {
    io: Io,
    host: []const u8,
    port: u16,
    stop: *const Atomic(bool),
    shared: *EndpointShared = undefined,
};

const Poller = struct {
    io: Io,
    stop: Atomic(bool) = .init(false),
    endpoint_count: usize,
    endpoints: [MaxHosts]EndpointShared = [_]EndpointShared{.{}} ** MaxHosts,
    threads: [MaxHosts]?std.Thread = [_]?std.Thread{null} ** MaxHosts,
    contexts: [MaxHosts]EndpointWorkerContext,

    pub fn init(io: Io, args: *const Args) Poller {
        var poller = Poller{
            .io = io,
            .endpoint_count = args.hosts.count,
            .contexts = undefined,
        };
        for (0..poller.endpoint_count) |i| poller.endpoints[i].init();
        for (0..poller.endpoint_count) |i| {
            poller.contexts[i] = .{
                .io = io,
                .host = args.hosts.get(i),
                .port = args.port,
                .stop = &poller.stop,
            };
        }
        return poller;
    }

    pub fn bindContextShared(self: *Poller) void {
        for (0..self.endpoint_count) |i| {
            self.contexts[i].shared = &self.endpoints[i];
        }
    }

    pub fn start(self: *Poller) !void {
        for (0..self.endpoint_count) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, endpointWorkerMain, .{&self.contexts[i]});
        }
    }

    pub fn stopAndJoin(self: *Poller) void {
        self.stop.store(true, .release);
        for (0..self.endpoint_count) |i| {
            self.endpoints[i].queue.close(self.io);
        }
        for (0..self.endpoint_count) |i| {
            if (self.threads[i]) |thread| {
                thread.join();
                self.threads[i] = null;
            }
        }
    }
};

const History = struct {
    len: usize = 0,
    head: usize = 0,
    timestamp: [MaxHistory]f64 = undefined,
    accel_x: [MaxHistory]f32 = undefined,
    accel_y: [MaxHistory]f32 = undefined,
    accel_z: [MaxHistory]f32 = undefined,
    gyro_norm: [MaxHistory]f32 = undefined,
    elevation: [MaxHistory]f32 = undefined,
    bearing: [MaxHistory]f32 = undefined,

    pub fn append(self: *History, sample: WireSample) void {
        const t = sampleTimestampToSeconds(sample.t);
        const gx = @as(f32, @floatFromInt(sample.g[0]));
        const gy = @as(f32, @floatFromInt(sample.g[1]));
        const gz = @as(f32, @floatFromInt(sample.g[2]));
        const gn = @sqrt(gx * gx + gy * gy + gz * gz);

        var insert_index: usize = undefined;
        if (self.len < MaxHistory) {
            insert_index = (self.head + self.len) % MaxHistory;
            self.len += 1;
        } else {
            insert_index = self.head;
            self.head = (self.head + 1) % MaxHistory;
        }

        self.timestamp[insert_index] = t;
        self.accel_x[insert_index] = @floatFromInt(sample.a[0]);
        self.accel_y[insert_index] = @floatFromInt(sample.a[1]);
        self.accel_z[insert_index] = @floatFromInt(sample.a[2]);
        self.gyro_norm[insert_index] = gn;
        self.elevation[insert_index] = @floatFromInt(sample.e);
        self.bearing[insert_index] = @floatFromInt(sample.b);

        self.trimToWindow();
    }

    fn trimToWindow(self: *History) void {
        if (self.len == 0) return;
        const latest_t = self.timestamp[(self.head + self.len - 1) % MaxHistory];
        const cutoff = latest_t - WindowSeconds;

        while (self.len > 0 and self.timestamp[self.head] < cutoff) {
            self.head = (self.head + 1) % MaxHistory;
            self.len -= 1;
        }
    }

    fn index(self: *const History, i: usize) usize {
        return (self.head + i) % MaxHistory;
    }

    fn latestTimestamp(self: *const History) ?f64 {
        if (self.len == 0) return null;
        return self.timestamp[self.index(self.len - 1)];
    }
};

fn sampleTimestampToSeconds(ts: i64) f64 {
    const abs_ts: u64 = @intCast(@abs(ts));
    if (abs_ts >= 1_000_000_000_000_000_000) return @as(f64, @floatFromInt(ts)) / 1_000_000_000.0;
    if (abs_ts >= 1_000_000_000_000_000) return @as(f64, @floatFromInt(ts)) / 1_000_000.0;
    if (abs_ts >= 1_000_000_000_000) return @as(f64, @floatFromInt(ts)) / 1_000.0;
    return @as(f64, @floatFromInt(ts));
}

const TraceKind = enum {
    accel_x,
    accel_y,
    accel_z,
    gyro_norm,
    elevation,
    bearing,
};

const TraceDef = struct {
    kind: TraceKind,
    name: []const u8,
    color: rl.Color,
};

const DeviceView = struct {
    history: History = .{},
};

const SceneTarget = struct {
    rt: ?rl.RenderTexture2D = null,
    width: i32 = 0,
    height: i32 = 0,
    warned_invalid_rt: bool = false,

    fn ensure(self: *SceneTarget, width: i32, height: i32) void {
        if (width <= 8 or height <= 8) return;
        if (self.rt != null and self.width == width and self.height == height) return;

        if (self.rt) |texture| {
            rl.unloadRenderTexture(texture);
            self.rt = null;
        }

        self.rt = rl.loadRenderTexture(width, height) catch null;
        if (self.rt) |rt| {
            if (!rl.isRenderTextureValid(rt)) {
                if (!self.warned_invalid_rt) {
                    self.warned_invalid_rt = true;
                    log.err("client: invalid render texture {}x{} (id={})", .{ width, height, rt.id });
                }
                rl.unloadRenderTexture(rt);
                self.rt = null;
            } else if (self.warned_invalid_rt) {
                self.warned_invalid_rt = false;
                log.info("client: render texture became valid {}x{} (id={})", .{ width, height, rt.id });
            }
        }
        self.width = width;
        self.height = height;
    }

    fn deinit(self: *SceneTarget) void {
        if (self.rt) |texture| rl.unloadRenderTexture(texture);
        self.* = .{};
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args_iter = init.minimal.args.iterateAllocator(arena) catch |err| {
        log.err("failed to iterate args: {}", .{err});
        return err;
    };
    defer args_iter.deinit();

    const args = Args.fromArgIter(&args_iter) catch |err| {
        log.err("invalid args: {}", .{err});
        return err;
    };

    var poller = Poller.init(io, &args);
    poller.bindContextShared();
    try poller.start();
    defer poller.stopAndJoin();

    const width = 1600;
    const height = 1000;
    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(width, height, "IMU Visualizer");
    rl.setWindowMinSize(1100, 700);
    defer rl.closeWindow();
    rl.setTargetFPS(240);

    var views: [MaxHosts]DeviceView = [_]DeviceView{.{}} ** MaxHosts;
    var scenes: [MaxHosts]SceneTarget = [_]SceneTarget{.{}} ** MaxHosts;
    defer for (&scenes) |*scene| scene.deinit();
    var last_render_debug_ms: i64 = 0;

    while (!rl.windowShouldClose() and !should_stop.load(.acquire)) {
        drainEndpointSamples(&poller, &views);
        const now_ms: i64 = @intFromFloat(rl.getTime() * 1000.0);
        if (now_ms - last_render_debug_ms >= RenderDebugIntervalMs) {
            last_render_debug_ms = now_ms;
            for (0..poller.endpoint_count) |i| {
                log.info("render: endpoint={} history_len={} state={}", .{
                    i,
                    views[i].history.len,
                    poller.endpoints[i].state,
                });
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color{ .r = 8, .g = 10, .b = 14, .a = 255 });

        drawUi(&poller, &views, &scenes);
        rl.drawFPS(14, 10);
    }
}

fn drawUi(poller: *Poller, views: *[MaxHosts]DeviceView, scenes: *[MaxHosts]SceneTarget) void {
    const screen_w = rl.getScreenWidth();
    const screen_h = rl.getScreenHeight();
    const margin: f32 = 12;

    const title_rect = rl.Rectangle{ .x = margin, .y = margin, .width = @floatFromInt(screen_w - 24), .height = 34 };
    rl.drawRectangleRec(title_rect, rl.Color{ .r = 15, .g = 18, .b = 24, .a = 255 });
    rl.drawRectangleLinesEx(title_rect, 1, rl.Color{ .r = 56, .g = 66, .b = 84, .a = 255 });
    drawTextFmt("IMU Visualizer - {d} device(s)", .{poller.endpoint_count}, 20, 20, 18, rl.Color{ .r = 235, .g = 240, .b = 248, .a = 255 });

    const body_top = title_rect.y + title_rect.height + 8;
    const body_h = @as(f32, @floatFromInt(screen_h)) - body_top - margin;

    if (poller.endpoint_count == 1) {
        const rect = rl.Rectangle{ .x = margin, .y = body_top, .width = @floatFromInt(screen_w - 24), .height = body_h };
        drawDevicePanel(poller, views, scenes, 0, rect, "IMU Device");
    } else {
        const panel_h = (body_h - 8) / 2.0;
        const rect_top = rl.Rectangle{ .x = margin, .y = body_top, .width = @floatFromInt(screen_w - 24), .height = panel_h };
        const rect_bottom = rl.Rectangle{ .x = margin, .y = body_top + panel_h + 8, .width = @floatFromInt(screen_w - 24), .height = panel_h };
        drawDevicePanel(poller, views, scenes, 0, rect_top, "CONTROL");
        drawDevicePanel(poller, views, scenes, 1, rect_bottom, "TEST");
    }
}

fn drawDevicePanel(
    poller: *Poller,
    views: *[MaxHosts]DeviceView,
    scenes: *[MaxHosts]SceneTarget,
    index: usize,
    panel: rl.Rectangle,
    title: []const u8,
) void {
    rl.drawRectangleRec(panel, rl.Color{ .r = 11, .g = 14, .b = 20, .a = 255 });
    rl.drawRectangleLinesEx(panel, 1, rl.Color{ .r = 52, .g = 61, .b = 78, .a = 255 });

    const header_h: f32 = 28;
    const pad: f32 = 10;
    const header_y = panel.y + 8;

    drawTextFmt("{s}", .{title}, @intFromFloat(panel.x + 10), @intFromFloat(header_y), 18, rl.Color{ .r = 236, .g = 241, .b = 249, .a = 255 });

    var state: ConnectionState = .disconnected;
    var parse_errors: u64 = 0;
    {
        var shared = &poller.endpoints[index];
        shared.mutex.lockUncancelable(poller.io);
        defer shared.mutex.unlock(poller.io);
        state = shared.state;
        parse_errors = shared.parse_errors;
    }

    const status_color = switch (state) {
        .connected => rl.Color{ .r = 80, .g = 214, .b = 124, .a = 255 },
        .connecting => rl.Color{ .r = 247, .g = 196, .b = 80, .a = 255 },
        .disconnected => rl.Color{ .r = 235, .g = 94, .b = 94, .a = 255 },
    };
    const status_text = switch (state) {
        .connected => "Connected",
        .connecting => "Connecting",
        .disconnected => "Disconnected - retrying every 2s",
    };

    drawTextFmt("Status: {s} | Parse errors: {}", .{ status_text, parse_errors }, @intFromFloat(panel.x + 190), @intFromFloat(header_y + 2), 14, status_color);
    drawTextFmt("History len: {}", .{views[index].history.len}, @intFromFloat(panel.x + 560), @intFromFloat(header_y + 2), 14, rl.Color{ .r = 214, .g = 220, .b = 230, .a = 255 });

    const content_y = panel.y + header_h + 8;
    const content_h = panel.height - header_h - 16;
    const scene_ratio: f32 = if (panel.width >= 1400) 0.44 else 0.40;
    const scene_w = panel.width * scene_ratio;

    const scene_rect = rl.Rectangle{ .x = panel.x + pad, .y = content_y + pad, .width = scene_w - pad * 1.5, .height = content_h - pad * 2 };
    const charts_x = panel.x + scene_w + pad;
    const charts_w = panel.width - scene_w - pad * 2;

    const plot_h = (content_h - pad * 3) / 2.0;
    const raw_plot = rl.Rectangle{ .x = charts_x, .y = content_y + pad, .width = charts_w, .height = plot_h };
    const orient_plot = rl.Rectangle{ .x = charts_x, .y = content_y + pad * 2 + plot_h, .width = charts_w, .height = plot_h };

    drawScenePanel(&scenes[index], scene_rect, &views[index].history);

    const raw_traces = [_]TraceDef{
        .{ .kind = .accel_x, .name = "accel_x", .color = rl.Color.red },
        .{ .kind = .accel_y, .name = "accel_y", .color = rl.Color.green },
        .{ .kind = .accel_z, .name = "accel_z", .color = rl.Color.blue },
        .{ .kind = .gyro_norm, .name = "gyro_norm", .color = rl.Color{ .r = 230, .g = 126, .b = 247, .a = 255 } },
    };
    drawPlot(raw_plot, "Raw Sensors", &views[index].history, &raw_traces);

    const orient_traces = [_]TraceDef{
        .{ .kind = .elevation, .name = "elevation", .color = rl.Color.orange },
        .{ .kind = .bearing, .name = "bearing", .color = rl.Color.sky_blue },
    };
    drawPlot(orient_plot, "Orientation", &views[index].history, &orient_traces);

    drawCurrentValues(panel, &views[index].history);
}

fn drawCurrentValues(panel: rl.Rectangle, history: *const History) void {
    if (history.len == 0) return;
    const i = history.index(history.len - 1);
    const y = panel.y + panel.height - 24;
    drawTextFmt(
        "A:[{d:.0},{d:.0},{d:.0}] Gnorm:{d:.1} E:{d:.1} B:{d:.1}",
        .{ history.accel_x[i], history.accel_y[i], history.accel_z[i], history.gyro_norm[i], history.elevation[i], history.bearing[i] },
        @intFromFloat(panel.x + 12),
        @intFromFloat(y),
        14,
        rl.Color{ .r = 205, .g = 210, .b = 220, .a = 255 },
    );
}

fn drawScenePanel(target: *SceneTarget, rect: rl.Rectangle, history: *const History) void {
    const width: i32 = @intFromFloat(@max(rect.width, 1));
    const height: i32 = @intFromFloat(@max(rect.height, 1));
    target.ensure(width, height);
    if (target.rt == null) {
        rl.drawRectangleRec(rect, rl.Color{ .r = 24, .g = 10, .b = 10, .a = 255 });
        rl.drawRectangleLinesEx(rect, 1, rl.Color{ .r = 170, .g = 70, .b = 70, .a = 255 });
        drawTextFmt("3D unavailable (invalid render target)", .{}, @intFromFloat(rect.x + 8), @intFromFloat(rect.y + 8), 12, rl.Color{ .r = 230, .g = 190, .b = 190, .a = 255 });
        return;
    }

    const rt = target.rt.?;
    rl.beginTextureMode(rt);

    rl.clearBackground(rl.Color{ .r = 18, .g = 20, .b = 24, .a = 255 });

    const camera = rl.Camera3D{
        .position = .{ .x = 2.9, .y = 2.35, .z = 2.9 },
        .target = .{ .x = 0, .y = 0.55, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 45,
        .projection = .perspective,
    };

    rl.beginMode3D(camera);

    const sphere_center = rl.Vector3{ .x = 0, .y = 0.55, .z = 0 };
    const sphere_radius: f32 = 0.52;
    rl.drawGrid(12, 0.5);
    rl.drawSphere(sphere_center, sphere_radius, rl.Color{ .r = 165, .g = 168, .b = 176, .a = 220 });
    rl.drawSphereWires(sphere_center, sphere_radius, 16, 16, rl.Color{ .r = 88, .g = 93, .b = 106, .a = 255 });

    var elevation: f32 = 0;
    var bearing: f32 = 0;
    if (history.len > 0) {
        const i = history.index(history.len - 1);
        elevation = history.elevation[i];
        bearing = history.bearing[i];
    }

    drawAxisArrow(elevation, bearing, .{ .x = 1, .y = 0, .z = 0 }, rl.Color.red);
    drawAxisArrow(elevation, bearing, .{ .x = 0, .y = 1, .z = 0 }, rl.Color.green);
    drawAxisArrow(elevation, bearing, .{ .x = 0, .y = 0, .z = 1 }, rl.Color.blue);
    rl.endMode3D();
    rl.endTextureMode();

    const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(rt.texture.width), .height = -@as(f32, @floatFromInt(rt.texture.height)) };
    rl.drawTexturePro(rt.texture, src, rect, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    rl.drawRectangleLinesEx(rect, 1, rl.Color{ .r = 58, .g = 63, .b = 76, .a = 255 });
}

fn drawAxisArrow(elevation_deg: f32, bearing_deg: f32, axis: rl.Vector3, color: rl.Color) void {
    const dir = rotateAxis(axis, elevation_deg, bearing_deg);
    const origin = rl.Vector3{ .x = 0, .y = 0.55, .z = 0 };

    const shaft_start = origin.add(dir.scale(0.56));
    const shaft_end = origin.add(dir.scale(1.55));
    rl.drawCylinderEx(shaft_start, shaft_end, 0.03, 0.03, 12, color);

    const head_start = origin.add(dir.scale(1.55));
    const head_end = origin.add(dir.scale(1.82));
    rl.drawCylinderEx(head_start, head_end, 0.09, 0.0, 12, color);
}

fn rotateAxis(axis: rl.Vector3, elevation_deg: f32, bearing_deg: f32) rl.Vector3 {
    const deg_to_rad = std.math.pi / 180.0;
    const elev = elevation_deg * deg_to_rad;
    const bear = bearing_deg * deg_to_rad;

    var v = rl.Vector3{ .x = -axis.x, .y = axis.y, .z = -axis.z };

    const cos_b = @cos(bear);
    const sin_b = @sin(bear);
    v = .{
        .x = cos_b * v.x - sin_b * v.y,
        .y = sin_b * v.x + cos_b * v.y,
        .z = v.z,
    };

    const cos_e = @cos(elev);
    const sin_e = @sin(elev);
    v = .{
        .x = cos_e * v.x + sin_e * v.z,
        .y = v.y,
        .z = -sin_e * v.x + cos_e * v.z,
    };

    return v;
}

fn drawPlot(rect: rl.Rectangle, title: []const u8, history: *const History, traces: []const TraceDef) void {
    rl.drawRectangleRec(rect, rl.Color{ .r = 14, .g = 16, .b = 21, .a = 255 });
    rl.drawRectangleLinesEx(rect, 1, rl.Color{ .r = 58, .g = 63, .b = 76, .a = 255 });

    const left_pad: f32 = 52;
    const right_pad: f32 = 10;
    const top_pad: f32 = 26;
    const bottom_pad: f32 = 24;

    const graph = rl.Rectangle{
        .x = rect.x + left_pad,
        .y = rect.y + top_pad,
        .width = rect.width - left_pad - right_pad,
        .height = rect.height - top_pad - bottom_pad,
    };

    drawTextFmt("{s}", .{title}, @intFromFloat(rect.x + 8), @intFromFloat(rect.y + 4), 14, rl.Color{ .r = 208, .g = 214, .b = 226, .a = 255 });

    if (graph.width <= 4 or graph.height <= 4 or history.len < 2) {
        drawTextFmt("Waiting for data... (len={})", .{history.len}, @intFromFloat(graph.x + 10), @intFromFloat(graph.y + graph.height / 2), 12, rl.Color.gray);
        return;
    }

    var min_v: f32 = std.math.inf(f32);
    var max_v: f32 = -std.math.inf(f32);
    for (0..history.len) |idx| {
        for (traces) |trace| {
            const v = historyValue(history, idx, trace.kind);
            min_v = @min(min_v, v);
            max_v = @max(max_v, v);
        }
    }

    if (!std.math.isFinite(min_v) or !std.math.isFinite(max_v)) {
        min_v = -1;
        max_v = 1;
    }
    if (@abs(max_v - min_v) < 1e-3) {
        min_v -= 1;
        max_v += 1;
    }

    const pad = (max_v - min_v) * 0.1;
    min_v -= pad;
    max_v += pad;

    drawGridAndAxes(graph, min_v, max_v);

    const latest_t = history.latestTimestamp().?;
    for (traces) |trace| {
        drawTrace(history, latest_t, graph, min_v, max_v, trace);
    }

    drawLegend(rect, traces);
    drawTextFmt("{d:.1}", .{max_v}, @intFromFloat(rect.x + 6), @intFromFloat(graph.y - 8), 10, rl.Color.light_gray);
    drawTextFmt("{d:.1}", .{min_v}, @intFromFloat(rect.x + 6), @intFromFloat(graph.y + graph.height - 8), 10, rl.Color.light_gray);
}

fn drawGridAndAxes(graph: rl.Rectangle, min_v: f32, max_v: f32) void {
    _ = min_v;
    _ = max_v;
    const grid_color = rl.Color{ .r = 46, .g = 50, .b = 60, .a = 255 };

    var gx: usize = 0;
    while (gx <= 6) : (gx += 1) {
        const t = @as(f32, @floatFromInt(gx)) / 6.0;
        const x = graph.x + graph.width * t;
        rl.drawLineEx(.{ .x = x, .y = graph.y }, .{ .x = x, .y = graph.y + graph.height }, 1, grid_color);
    }

    var gy: usize = 0;
    while (gy <= 4) : (gy += 1) {
        const t = @as(f32, @floatFromInt(gy)) / 4.0;
        const y = graph.y + graph.height * t;
        rl.drawLineEx(.{ .x = graph.x, .y = y }, .{ .x = graph.x + graph.width, .y = y }, 1, grid_color);
    }

    rl.drawRectangleLinesEx(graph, 1, rl.Color{ .r = 88, .g = 95, .b = 112, .a = 255 });
}

fn drawTrace(history: *const History, latest_t: f64, graph: rl.Rectangle, min_v: f32, max_v: f32, trace: TraceDef) void {
    var prev: ?rl.Vector2 = null;
    for (0..history.len) |i| {
        const idx = history.index(i);
        const x_seconds = history.timestamp[idx] - latest_t;
        if (x_seconds < -WindowSeconds) continue;

        const v = historyValue(history, i, trace.kind);
        const x = graph.x + @as(f32, @floatCast((x_seconds + WindowSeconds) / WindowSeconds)) * graph.width;
        const y_norm = (v - min_v) / (max_v - min_v);
        const y = graph.y + (1.0 - y_norm) * graph.height;

        const current = rl.Vector2{ .x = x, .y = y };
        if (prev) |p| rl.drawLineEx(p, current, 2, trace.color);
        prev = current;
    }
}

fn drawLegend(rect: rl.Rectangle, traces: []const TraceDef) void {
    var x = rect.x + 8;
    const y = rect.y + rect.height - 16;
    for (traces) |trace| {
        rl.drawRectangle(@intFromFloat(x), @intFromFloat(y), 10, 10, trace.color);
        drawTextFmt("{s}", .{trace.name}, @intFromFloat(x + 14), @intFromFloat(y - 2), 10, rl.Color.light_gray);
        x += 74;
    }
}

fn historyValue(history: *const History, logical_index: usize, kind: TraceKind) f32 {
    const idx = history.index(logical_index);
    return switch (kind) {
        .accel_x => history.accel_x[idx],
        .accel_y => history.accel_y[idx],
        .accel_z => history.accel_z[idx],
        .gyro_norm => history.gyro_norm[idx],
        .elevation => history.elevation[idx],
        .bearing => history.bearing[idx],
    };
}

fn drainEndpointSamples(poller: *Poller, views: *[MaxHosts]DeviceView) void {
    for (0..poller.endpoint_count) |i| {
        var shared = &poller.endpoints[i];
        var drained: [QueueCapacity]WireSample = undefined;
        const drained_len = shared.queue.getUncancelable(poller.io, &drained, 0) catch |err| switch (err) {
            error.Closed => 0,
        };

        for (drained[0..drained_len]) |sample| {
            views[i].history.append(sample);
        }
        if (drained_len > 0) {
            log.debug("client: drained {} samples for endpoint {}", .{ drained_len, i });
        }
    }
}

fn endpointWorkerMain(ctx: *EndpointWorkerContext) void {
    const io = ctx.io;

    while (!ctx.stop.load(.acquire)) {
        setState(ctx.shared, io, .connecting);
        log.info("client: connecting to {s}:{}", .{ ctx.host, ctx.port });

        var stream = connectToHost(io, ctx.host, ctx.port) catch |err| {
            log.warn("client: connect failed to {s}:{}: {}", .{ ctx.host, ctx.port, err });
            onDisconnect(ctx.shared, io);
            sleepMs(io, ReconnectMs);
            continue;
        };
        defer stream.close(io);
        log.info("client: connected to {s}:{}", .{ ctx.host, ctx.port });
        setState(ctx.shared, io, .connected);

        var line_buffer: [8192]u8 = undefined;
        var line_len: usize = 0;
        var recv_buffer: [2048]u8 = undefined;

        while (!ctx.stop.load(.acquire)) {
            const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(ReadPollMs), .clock = .real } };
            const message = stream.socket.receiveTimeout(io, &recv_buffer, timeout) catch |err| switch (err) {
                error.Timeout => continue,
                else => {
                    log.warn("client: receive error from {s}:{}: {}", .{ ctx.host, ctx.port, err });
                    break;
                },
            };
            log.debug("client: recv {} bytes from {s}:{}", .{ message.data.len, ctx.host, ctx.port });

            for (message.data) |byte| {
                if (byte == '\n') {
                    if (line_len > 0) {
                        log.debug("client: complete line len={} from {s}:{}", .{ line_len, ctx.host, ctx.port });
                        parseAndPush(ctx.shared, io, line_buffer[0..line_len], ctx.host);
                        line_len = 0;
                    }
                    continue;
                }

                if (line_len < line_buffer.len) {
                    line_buffer[line_len] = byte;
                    line_len += 1;
                } else {
                    log.warn("client: line buffer overflow from {s}:{}, dropping line", .{ ctx.host, ctx.port });
                    line_len = 0;
                    incrementParseError(ctx.shared, io);
                }
            }
        }

        log.warn("client: disconnected from {s}:{}", .{ ctx.host, ctx.port });
        onDisconnect(ctx.shared, io);
        sleepMs(io, ReconnectMs);
    }
}

fn connectToHost(io: Io, host: []const u8, port: u16) anyerror!Io.net.Stream {
    if (builtin.os.tag == .linux) {
        if (Io.net.Ip4Address.parse(host, port)) |addr| {
            log.debug("client: using linux ipv4 connect path for {s}:{}", .{ host, port });
            const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
            if (linux.errno(fd) != .SUCCESS) return error.SocketCreationFailed;
            errdefer _ = linux.close(@intCast(fd));

            var sock_addr: linux.sockaddr.in = .{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.bytesToValue(u32, &addr.bytes),
                .zero = .{0} ** 8,
            };

            const rc = linux.connect(
                @intCast(fd),
                @ptrCast(&sock_addr),
                @sizeOf(linux.sockaddr.in),
            );
            if (linux.errno(rc) != .SUCCESS) {
                return switch (linux.errno(rc)) {
                    .CONNREFUSED => error.ConnectionRefused,
                    .HOSTUNREACH => error.HostUnreachable,
                    .NETUNREACH => error.NetworkUnreachable,
                    .TIMEDOUT => error.Timeout,
                    else => error.ConnectFailed,
                };
            }

            const socket = Io.net.Socket{
                .handle = @intCast(fd),
                .address = .{ .ip4 = addr },
            };
            return .{ .socket = socket };
        } else |_| {}
    }

    if (Io.net.IpAddress.parse(host, port)) |addr| {
        log.debug("client: using std.Io IpAddress.connect for {s}:{}", .{ host, port });
        return Io.net.IpAddress.connect(addr, io, .{ .mode = .stream, .protocol = .tcp, .timeout = .none });
    } else |_| {
        log.debug("client: using std.Io HostName.connect for {s}:{}", .{ host, port });
        const name = try Io.net.HostName.init(host);
        return Io.net.HostName.connect(name, io, port, .{ .mode = .stream, .protocol = .tcp, .timeout = .none });
    }
}

fn parseAndPush(shared: *EndpointShared, io: Io, line: []const u8, host: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const report = std.json.parseFromSliceLeaky(common.Report, arena.allocator(), line, .{}) catch |err| {
        const preview_len = @min(line.len, 160);
        log.warn("client: json parse failed from {s}, len={}, err={}, payload='{s}'", .{
            host,
            line.len,
            err,
            line[0..preview_len],
        });
        incrementParseError(shared, io);
        return;
    };
    log.debug("client: parsed report from {s} ts={} a=[{},{},{}] g=[{},{},{}] e={} b={}", .{
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

    const sample: WireSample = .{
        .t = report.sample.timestamp,
        .a = .{ report.sample.accel_x, report.sample.accel_y, report.sample.accel_z },
        .g = .{ report.sample.gyro_x, report.sample.gyro_y, report.sample.gyro_z },
        .e = report.elevation,
        .b = report.bearing,
    };

    shared.queue.putOne(io, sample) catch |err| switch (err) {
        error.Canceled => return,
        error.Closed => {
            return;
        },
    };
    log.debug("client: queued sample from {s}", .{host});
}

fn incrementParseError(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.parse_errors += 1;
}

fn onDisconnect(shared: *EndpointShared, io: Io) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.state = .disconnected;
    shared.disconnects += 1;
}

fn setState(shared: *EndpointShared, io: Io, state: ConnectionState) void {
    shared.mutex.lockUncancelable(io);
    defer shared.mutex.unlock(io);
    shared.state = state;
}

fn sleepMs(io: Io, ms: i64) void {
    Io.sleep(io, Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn drawTextFmt(comptime fmt: []const u8, args: anytype, x: i32, y: i32, size: i32, color: rl.Color) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, fmt, args) catch return;
    rl.drawText(text, x, y, size, color);
}

fn handleSignal(_: std.os.linux.SIG) callconv(.c) void {
    should_stop.store(true, .release);
}

fn setupSignalHandler() void {
    if (builtin.os.tag != .linux) return;

    const signals: std.os.linux.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &signals, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &signals, null);
}

test "hosts parse" {
    const hosts = try Hosts.parse("127.0.0.1,192.168.1.20");
    try std.testing.expectEqual(@as(u8, 2), hosts.count);
    try std.testing.expectEqualStrings("127.0.0.1", hosts.get(0));
    try std.testing.expectEqualStrings("192.168.1.20", hosts.get(1));
}
