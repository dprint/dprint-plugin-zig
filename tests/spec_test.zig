//! Formats each file in tests/specs with the plugin and with the `zig fmt` of
//! the Zig that runs the tests, and checks that they're the same, including the
//! error message when the file doesn't parse.
//!
//! The file names say what the file is for: `formatted_*` files must already be
//! formatted, `error_*` files must fail to parse, and the others must change.

const std = @import("std");
const builtin = @import("builtin");
const plugin = @import("plugin");
const options = @import("options");
const testing = std.testing;
const io = testing.io;

test "formats like zig fmt" {
    const gpa = testing.allocator;
    const zig_exe = try findZig(gpa);
    var specs_dir = try std.Io.Dir.cwd().openDir(io, options.specs_dir, .{ .iterate = true });
    defer specs_dir.close(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var count: usize = 0;
    var iterator = specs_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        checkSpec(gpa, zig_exe, specs_dir, tmp.dir, entry.name) catch |err| {
            std.debug.print("spec {s} failed\n", .{entry.name});
            return err;
        };
        count += 1;
    }
    try testing.expect(count > 0);
}

fn checkSpec(gpa: std.mem.Allocator, zig_exe: []const u8, specs_dir: std.Io.Dir, tmp_dir: std.Io.Dir, name: []const u8) !void {
    const input = try specs_dir.readFileAlloc(io, name, gpa, .unlimited);
    defer gpa.free(input);

    const result = try plugin.format_text.formatText(gpa, name, input);
    defer result.deinit(gpa);
    const expected_kind: std.meta.Tag(plugin.format_text.FormatResult) = if (std.mem.startsWith(u8, name, "error_"))
        .failed
    else if (std.mem.startsWith(u8, name, "formatted_"))
        .no_change
    else
        .changed;
    try testing.expectEqual(expected_kind, std.meta.activeTag(result));

    // zig fmt formats the file in place
    try tmp_dir.writeFile(io, .{ .sub_path = name, .data = input });
    const zig_fmt = try std.process.run(gpa, io, .{
        .argv = &.{ zig_exe, "fmt", "--color", "off", name },
        .cwd = .{ .dir = tmp_dir },
    });
    defer gpa.free(zig_fmt.stdout);
    defer gpa.free(zig_fmt.stderr);
    const zig_fmt_output = try tmp_dir.readFileAlloc(io, name, gpa, .unlimited);
    defer gpa.free(zig_fmt_output);

    switch (result) {
        .no_change => {
            try testing.expect(zig_fmt.term.success());
            try testing.expectEqualStrings(input, zig_fmt_output);
        },
        .changed => |text| {
            try testing.expect(zig_fmt.term.success());
            try testing.expectEqualStrings(zig_fmt_output, text);
        },
        .failed => |message| {
            try testing.expect(!zig_fmt.term.success());
            const expected = try withoutPathPrefixes(gpa, zig_fmt.stderr, name);
            defer gpa.free(expected);
            try testing.expectEqualStrings(expected, message);
        },
    }
}

/// Gets the Zig to compare against, which must be the same version as the Zig
/// that built the tests. That's normally the Zig running `zig build`, but the
/// build system can cache its path from an earlier run with another install of
/// the same version, so this falls back to the `zig` on the path.
fn findZig(gpa: std.mem.Allocator) ![]const u8 {
    for ([_][]const u8{ options.zig_exe, "zig" }) |zig_exe| {
        const result = std.process.run(gpa, io, .{ .argv = &.{ zig_exe, "version" } }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const version = std.mem.trim(u8, result.stdout, " \r\n");
        if (!std.mem.eql(u8, version, builtin.zig_version_string)) {
            std.debug.print("{s} is Zig {s}, but the tests were built with Zig {s}\n", .{ zig_exe, version, builtin.zig_version_string });
            return error.ZigVersionMismatch;
        }
        return zig_exe;
    }
    std.debug.print("could not find Zig {s} at {s} or on the path\n", .{ builtin.zig_version_string, options.zig_exe });
    return error.ZigNotFound;
}

/// Removes the `<path>:` that zig fmt starts each message with, and the
/// trailing newline.
fn withoutPathPrefixes(gpa: std.mem.Allocator, stderr: []const u8, name: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const text = std.mem.trimEnd(u8, stderr, "\r\n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try output.writer.writeByte('\n');
        first = false;
        const prefix_len = name.len + 1;
        if (std.mem.startsWith(u8, line, name) and line.len > name.len and line[name.len] == ':') {
            try output.writer.writeAll(line[prefix_len..]);
        } else {
            try output.writer.writeAll(line);
        }
    }
    return output.toOwnedSlice();
}
