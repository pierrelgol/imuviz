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
    pub const cursor_line_ratio: f32 = 0.006;
    pub const cursor_readout_offset_ratio: f32 = 0.080;
    pub const cursor_readout_line_gap_ratio: f32 = 0.080;
    pub const cursor_readout_size_ratio: f32 = 0.038;
    pub const cursor_column_width_ratio: f32 = 0.090;
    pub const cursor_column_gap_ratio: f32 = 0.012;
    pub const cursor_column_inner_padding_px: f32 = 4.0;
    pub const y_tick_lane_width_ratio: f32 = 0.055;
    pub const cursor_column_fill = color(10, 13, 18, 210);
    pub const show_delta_series: bool = true;
};

pub const window_initial_width: i32 = 1600;
pub const window_initial_height: i32 = 1000;
pub const window_min_width: i32 = 1100;
pub const window_min_height: i32 = 700;
pub const target_fps: i32 = 240;

pub const renderer = struct {
    pub const panel_border_thickness: f32 = 1.0;
    pub const status_text_size: i32 = 14;
    pub const panel_title_size: i32 = 18;
    pub const current_values_size: i32 = 14;
    pub const fps_top_padding: f32 = 8.0;
    pub const fps_right_padding: f32 = 12.0;
    pub const panel_title_padding_scale: f32 = 0.8;
    pub const status_text_x_offset: f32 = 180.0;
    pub const status_text_y_offset: f32 = 2.0;
    pub const current_values_bottom_offset: f32 = 24.0;
    pub const current_values_x_offset: f32 = 12.0;
    pub const invalid_rt_text_size: i32 = 12;
    pub const invalid_rt_text_x_offset: f32 = 8.0;
    pub const invalid_rt_text_y_offset: f32 = 8.0;
    pub const min_scene_dim_px: i32 = 8;

    pub const title_border = color(56, 66, 84, 255);
    pub const panel_border = color(52, 61, 78, 255);
    pub const status_connected = color(80, 214, 124, 255);
    pub const status_connecting = color(247, 196, 80, 255);
    pub const status_disconnected = color(235, 94, 94, 255);
    pub const scene_unavailable_fill = color(24, 10, 10, 255);
    pub const scene_unavailable_border = color(170, 70, 70, 255);
    pub const scene_unavailable_text = color(230, 190, 190, 255);
    pub const scene_bg = color(18, 20, 24, 255);
    pub const scene_sphere_fill = color(165, 168, 176, 220);
    pub const scene_sphere_wire = color(88, 93, 106, 255);
    pub const scene_imu_arrow = color(247, 210, 72, 255);
    pub const scene_ref_x = color(210, 78, 78, 255);
    pub const scene_ref_y = color(80, 214, 124, 255);
    pub const scene_ref_z = color(86, 166, 245, 255);
    pub const trace_gyro_norm = color(230, 126, 247, 255);
    pub const delta_trace = color(230, 230, 230, 255);
};

pub const ui = struct {
    pub const chart_count: usize = 6;

    pub const screen_ref_min: f32 = 10.0;

    pub const margin_ratio: f32 = 0.010;
    pub const margin_min: f32 = 10.0;
    pub const gap_ratio: f32 = 0.008;
    pub const gap_min: f32 = 8.0;
    pub const title_height_ratio: f32 = 0.030;
    pub const title_height_min: f32 = 34.0;
    pub const panel_header_height_ratio: f32 = 0.028;
    pub const panel_header_height_min: f32 = 28.0;
    pub const panel_padding_ratio: f32 = 0.006;
    pub const panel_padding_min: f32 = 5.0;

    pub const scene_ratio_wide: f32 = 0.34;
    pub const scene_ratio_narrow: f32 = 0.30;
    pub const scene_ratio_breakpoint_px: f32 = 1400.0;
    pub const scene_width_padding_scale: f32 = 1.5;
    pub const charts_gap_scale: f32 = 0.7;

    pub const charts_two_column_width_height_ratio: f32 = 0.9;
    pub const comparison_scenes_height_ratio_single: f32 = 0.44;
    pub const comparison_scenes_height_ratio_multi: f32 = 0.48;
    pub const comparison_scene_gap_scale: f32 = 1.0;
    pub const comparison_plot_gap_scale: f32 = 0.7;
    pub const comparison_plot_columns: usize = 2;
};

pub const scene3d = struct {
    pub const camera_pos: rl.Vector3 = .{ .x = 2.9, .y = 2.35, .z = 2.9 };
    pub const camera_target: rl.Vector3 = .{ .x = 0.0, .y = 0.55, .z = 0.0 };
    pub const camera_up: rl.Vector3 = .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    pub const camera_fovy: f32 = 45.0;

    pub const origin: rl.Vector3 = .{ .x = 0.0, .y = 0.55, .z = 0.0 };
    pub const sphere_center: rl.Vector3 = .{ .x = 0.0, .y = 0.55, .z = 0.0 };
    pub const sphere_radius: f32 = 0.52;
    pub const grid_slices: i32 = 12;
    pub const grid_spacing: f32 = 0.5;
    pub const reference_height: f32 = 0.05;
    pub const reference_inset: f32 = 0.25;
    pub const reference_axis_length: f32 = 0.9;

    pub const axis_shaft_start: f32 = 0.0;
    pub const axis_shaft_end: f32 = 1.55;
    pub const axis_head_start: f32 = 1.55;
    pub const axis_head_end: f32 = 1.82;
    pub const axis_shaft_radius: f32 = 0.03;
    pub const axis_head_radius: f32 = 0.09;
    pub const axis_sides: i32 = 12;
};

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
