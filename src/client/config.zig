const rl = @import("raylib");

pub const max_hosts: usize = 2;
pub const max_host_len: usize = 64;
pub const queue_capacity: usize = 4096;
pub const drain_batch_size: usize = 1024;
pub const max_history: usize = 8192;
pub const history_window_seconds: f64 = 30.0;

pub const reconnect_ms: i64 = 2000;
pub const poll_timeout_ms: i32 = 4;
pub const max_line_bytes: usize = 8192;
pub const recv_buffer_bytes: usize = 2048;

pub const render_debug_interval_ms: i64 = 1000;
pub const trace_client_main: bool = true;
pub const trace_network: bool = true;
pub const trace_network_timeouts: bool = false;
pub const trace_network_payloads: bool = false;

pub const plot = struct {
    pub const raw_x_graduations: usize = 6;
    pub const raw_y_graduations: usize = 6;
    pub const orientation_x_graduations: usize = 6;
    pub const orientation_y_graduations: usize = 6;

    pub const orientation_min_deg: f64 = 0.0;
    pub const orientation_max_deg: f64 = 360.0;
    pub const elevation_min_deg: f64 = -90.0;
    pub const elevation_max_deg: f64 = 90.0;
    pub const accel_min: f64 = -32768.0;
    pub const accel_max: f64 = 32767.0;
    pub const gyro_norm_min: f64 = 0.0;
    pub const gyro_norm_max: f64 = 60000.0;

    pub const y_padding_fraction: f32 = 0.10;
    pub const min_samples: usize = 2;

    pub const left_padding_ratio: f32 = 0.10;
    pub const right_padding_ratio: f32 = 0.02;
    pub const top_padding_ratio: f32 = 0.11;
    pub const bottom_padding_ratio: f32 = 0.16;
    pub const tick_length_ratio: f32 = 0.015;
    pub const axis_label_offset_ratio: f32 = 0.05;
    pub const title_offset_ratio: f32 = 0.04;
    pub const legend_offset_ratio: f32 = 0.04;
    pub const legend_item_gap_ratio: f32 = 0.015;

    pub const title_size_ratio: f32 = 0.075;
    pub const axis_label_size_ratio: f32 = 0.058;
    pub const tick_label_size_ratio: f32 = 0.050;
    pub const legend_size_ratio: f32 = 0.050;
    pub const empty_size_ratio: f32 = 0.055;
    pub const min_font_px: i32 = 8;

    pub const border_ratio: f32 = 0.006;
    pub const grid_ratio: f32 = 0.004;
    pub const trace_ratio: f32 = 0.007;
};

pub const window_initial_width: i32 = 1600;
pub const window_initial_height: i32 = 1000;
pub const window_min_width: i32 = 1100;
pub const window_min_height: i32 = 700;
pub const target_fps: i32 = 240;

pub const theme = struct {
    pub const background = color(8, 10, 14, 255);
    pub const frame_panel = color(11, 14, 20, 255);
    pub const title_panel = color(15, 18, 24, 255);
    pub const border = color(58, 63, 76, 255);
    pub const text_primary = color(236, 241, 249, 255);
    pub const text_secondary = color(205, 210, 220, 255);
};

pub fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
