const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("build.zig.zon");

// the formatter is Zig's std, so the plugin only formats like the `zig fmt` of
// the Zig that builds it
comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, manifest.minimum_zig_version)) {
        @compileError("dprint-plugin-zig must be built with Zig " ++ manifest.minimum_zig_version ++
            " (the minimum_zig_version in build.zig.zon), but this is Zig " ++ builtin.zig_version_string);
    }
}

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSmall for the plugin, Debug for the tests)",
    );

    // `zig build` outputs zig-out/plugin.wasm
    const plugin = b.addExecutable(.{
        .name = "plugin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            // freestanding rather than WASI, so the module has no imports
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize orelse .ReleaseSmall,
            .strip = true,
        }),
    });
    // the plugin interface is the exports, so there's no entry point
    plugin.entry = .disabled;
    plugin.rdynamic = true;
    // the parser and renderer are recursive, and with the default stack of 1 MiB
    // they run out of it at around 380 levels of nesting (ex. parentheses). With
    // this, the limit is the host's own call stack instead, which is over a
    // thousand levels in the dprint cli.
    plugin.stack_size = 8 * 1024 * 1024;
    b.getInstallStep().dependOn(&b.addInstallArtifact(plugin, .{
        .dest_dir = .{ .override = .prefix },
    }).step);

    const plugin_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = b.graph.host,
        .optimize = optimize orelse .Debug,
    });
    const unit_tests = b.addTest(.{ .name = "unit", .root_module = plugin_module });

    // the spec tests compare the plugin's output to the output of this Zig's `zig fmt`
    const spec_options = b.addOptions();
    spec_options.addOptionPathUntracked("zig_exe", .zig_exe);
    spec_options.addOptionPathDirectory("specs_dir", b.path("tests/specs"));
    const spec_tests = b.addTest(.{
        .name = "specs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/spec_test.zig"),
            .target = b.graph.host,
            .optimize = optimize orelse .Debug,
            .imports = &.{
                .{ .name = "plugin", .module = plugin_module },
                .{ .name = "options", .module = spec_options.createModule() },
            },
        }),
    });

    const test_step = b.step("test", "Run the unit and spec tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_tests).step);
}
