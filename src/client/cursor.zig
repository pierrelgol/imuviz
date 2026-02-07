const rl = @import("raylib");
const cfg = @import("config.zig");

pub const SharedCursor = struct {
    active: bool = false,
    x_norm: f32 = 1.0,

    pub fn update(self: *SharedCursor, plot_rects: [cfg.ui.chart_count]rl.Rectangle) void {
        const mouse = rl.getMousePosition();
        self.active = false;

        for (plot_rects) |rect| {
            if (!contains(rect, mouse)) continue;
            if (rect.width <= 1.0) continue;
            self.x_norm = clamp01((mouse.x - rect.x) / rect.width);
            self.active = true;
            return;
        }
    }
};

fn contains(rect: rl.Rectangle, p: rl.Vector2) bool {
    return p.x >= rect.x and p.x <= rect.x + rect.width and p.y >= rect.y and p.y <= rect.y + rect.height;
}

fn clamp01(v: f32) f32 {
    return @max(0.0, @min(1.0, v));
}
