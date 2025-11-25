// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vex",
        .root_source_file = b.path("bootstrap/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.addIncludePath(b.path("bootstrap"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    b.step("run", "Run the bootstrap compiler").dependOn(&run_cmd.step);
}
