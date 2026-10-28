const std = @import("std");

/// Koi's core: the `koi` binary (the server on every machine, and the
/// command-line tool) and `libkoi`, the link client the Mac app embeds.
/// `zig build -Dtarget=x86_64-linux-musl` cross-compiles either.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    });
    const engine = ghostty.artifact("ghostty-vt-static");

    // The C headers the core uses, as one Zig module.
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/core/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c.addIncludePath(ghostty.path("include"));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/core/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const build_options = b.addOptions();
    // The build script supplies a fresh target-specific digest. Direct Zig
    // builds are unversioned because configure-time source hashes can go stale.
    const version = b.option([]const u8, "version", "The core version to stamp, from the build script") orelse "unversioned";
    build_options.addOption([]const u8, "version", version);
    mod.addOptions("build_options", build_options);
    mod.addImport("c", c.createModule());
    mod.linkLibrary(engine);

    if (optimize != .debug) mod.strip = true;
    const exe = b.addExecutable(.{ .name = "koi", .root_module = mod });
    b.installArtifact(exe);

    // libkoi: the link's client side for the app, with no engine in it.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/core/libkoi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("c", c.createModule());
    if (optimize != .debug) lib_mod.strip = true;
    const lib = b.addLibrary(.{ .name = "koi", .root_module = lib_mod, .linkage = .static });
    b.installArtifact(lib);
    b.installFile("src/core/include/koi.h", "include/koi.h");

    const filter = b.option([]const u8, "test-filter", "Run core tests whose names contain this text");
    const tests = b.addTest(.{ .root_module = mod, .filters = if (filter) |text| &.{text} else &.{} });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the core's tests").dependOn(&run_tests.step);
}

