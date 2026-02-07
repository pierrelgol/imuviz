const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const generator_mod = b.createModule(.{
        .root_source_file = b.path("src/generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const generator = b.addExecutable(.{
        .name = "generator",
        .root_module = generator_mod,
    });
    b.installArtifact(generator);

    const client = b.addExecutable(.{
        .name = "client",
        .root_module = client_mod,
    });
    b.installArtifact(client);

    const host = b.addExecutable(.{
        .name = "host",
        .root_module = host_mod,
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

    const run_generator_step = b.step("run_generator", "Run the app");

    const run_generator_cmd = b.addRunArtifact(host);
    run_generator_step.dependOn(&run_generator_cmd.step);

    run_generator_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_generator_cmd.addArgs(args);
    }

    const common_mod_tests = b.addTest(.{
        .root_module = common_mod,
    });

    const generator_mod_tests = b.addTest(.{
        .root_module = generator_mod,
    });

    const host_mod_tests = b.addTest(.{
        .root_module = host_mod,
    });

    const client_mod_tests = b.addTest(.{
        .root_module = client_mod,
    });

    const run_common_mod_tests = b.addRunArtifact(common_mod_tests);
    const run_generator_mod_tests = b.addRunArtifact(generator_mod_tests);
    const run_host_mod_tests = b.addRunArtifact(host_mod_tests);
    const run_client_mod_tests = b.addRunArtifact(client_mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_common_mod_tests.step);
    test_step.dependOn(&run_host_mod_tests.step);
    test_step.dependOn(&run_client_mod_tests.step);
    test_step.dependOn(&run_generator_mod_tests.step);

    const generator_check = b.addExecutable(.{
        .name = "generator",
        .root_module = generator_mod,
    });

    const host_check = b.addExecutable(.{
        .name = "host",
        .root_module = host_mod,
    });

    const client_check = b.addExecutable(.{
        .name = "client",
        .root_module = client_mod,
    });

    const check_step = b.step("check", "Run checks");
    check_step.dependOn(&host_check.step);
    check_step.dependOn(&client_check.step);
    check_step.dependOn(&generator_check.step);
}
