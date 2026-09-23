pub fn build(b: *std.Build) void {
    b.release_mode = .small;

    const optimize = b.standardOptimizeOption(.{});

    const zitrus_dep = b.dependency("zitrus", .{});
    const zitrus_mod = zitrus_dep.module("zitrus");

    const exe = b.addExecutable(.{
        .name = "codec.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .arm,
                .os_tag = .@"3ds",
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zitrus", .module = zitrus_mod },
            },
            .strip = b.option(bool, "strip", "Strip the final elf"),
        }),
        .zig_lib_dir = zitrus_dep.namedLazyPath("juice/zig_lib"),
    });

    // Not needed as it doesn't need to be relocatable.
    // exe.pie = true;
    exe.setLinkerScript(zitrus_dep.namedLazyPath("horizon/ld"));
    b.installArtifact(exe);

    const cxi: zitrus.MakeCxi = .init(zitrus_dep, .{
        .exe = exe,
        .settings = b.path("codec.settings.zon"),
    });

    cxi.install(b, .default);
}

const std = @import("std");
const zitrus = @import("zitrus");
