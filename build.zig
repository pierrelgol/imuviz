const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
    });

    const h = b.createModule(.{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common },
        },
    });

    const c = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common },
        },
    });

    const client = b.addExecutable(.{
        .name = "client",
        .root_module = c,
    });
    b.installArtifact(client);

    const host = b.addExecutable(.{
        .name = "host",
        .root_module = h,
    });
    b.installArtifact(host);

    const run_host_step = b.step("run_host", "Run the app");

    const run_host_cmd = b.addRunArtifact(host);
    run_host_step.dependOn(&run_host_cmd.step);

    run_host_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_host_cmd.addArgs(args);
    }

    const run_client_step = b.step("run_client", "Run the app");

    const run_client_cmd = b.addRunArtifact(host);
    run_client_step.dependOn(&run_client_cmd.step);

    run_client_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = common,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = host.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const host_check = b.addExecutable(.{
        .name = "host",
        .root_module = h,
    });

    const client_check = b.addExecutable(.{
        .name = "client",
        .root_module = h,
    });

    const check_step = b.step("check", "Run checks");
    check_step.dependOn(&host_check.step);
    check_step.dependOn(&client_check.step);
}
