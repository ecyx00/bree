const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bree_tui = b.addModule("bree_tui", .{
        .root_source_file = b.path("../../../../zig/src/bree.zig"),
        .target = target,
        .optimize = optimize,
    });
    const adapter = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.addImport("bree_tui", bree_tui);

    const executable = b.addExecutable(.{
        .name = "bree-conformance-zig",
        .root_module = adapter,
    });
    b.installArtifact(executable);
}
