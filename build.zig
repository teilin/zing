const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zing",
        .optimize = mode,
        .root_module = module,
    });

    exe.linkSystemLibrary("m");
    exe.linkSystemLibrary("pthread");

    b.installArtifact(exe);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const tests = b.addTest(.{
        .optimize = mode,
        .root_module = test_module,
    });
    _ = b.addRunArtifact(tests);
}
