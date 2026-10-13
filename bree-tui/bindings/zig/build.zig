const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bree_tui = b.addModule("bree_tui", .{
        .root_source_file = b.path("src/bree.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .name = "bree-tui-zig-tests",
        .root_module = bree_tui,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step(
        "test",
        "Run codec, transport, lifecycle, stream, and API tests",
    );
    test_step.dependOn(&run_unit_tests.step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/watch.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("bree_tui", bree_tui);
    const example = b.addExecutable(.{
        .name = "bree-tui-watch",
        .root_module = example_module,
        .version = std.SemanticVersion.parse("1.0.0") catch unreachable,
    });
    b.installArtifact(example);

    const example_tests = b.addTest(.{
        .name = "bree-tui-zig-consumer-test",
        .root_module = example_module,
    });
    const run_example_tests = b.addRunArtifact(example_tests);
    test_step.dependOn(&run_example_tests.step);
}
