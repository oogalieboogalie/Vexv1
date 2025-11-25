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

    exe.linkLibC();

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    b.step("run", "Run the Vex compiler").dependOn(&run.step);
}
