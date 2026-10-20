//! The plugin's configuration. `zig fmt` has no formatting options, so there's
//! nothing to resolve other than the diagnostics for unknown properties.
//!
//! The global configuration doesn't apply either. Like `zig fmt`, the plugin
//! always indents with four spaces, has no line width, and outputs LF newlines
//! (it formats a file with CRLF newlines to LF).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const ResolvedConfig = struct {
    diagnostics: []Diagnostic,

    pub const empty: ResolvedConfig = .{ .diagnostics = &.{} };

    pub fn deinit(config: ResolvedConfig, gpa: Allocator) void {
        for (config.diagnostics) |diagnostic| gpa.free(diagnostic.property_name);
        gpa.free(config.diagnostics);
    }
};

pub const Diagnostic = struct {
    property_name: []u8,
    message: []const u8,
};

/// Resolves the `{ "plugin": ..., "global": ... }` configuration that the host
/// registers, where `plugin` is the plugin's own configuration object.
pub fn resolveConfig(gpa: Allocator, raw_config: []const u8) Allocator.Error!ResolvedConfig {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw_config, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // the host always sends valid json
        else => return .empty,
    };
    defer parsed.deinit();

    const plugin_config = switch (parsed.value) {
        .object => |object| object.get("plugin") orelse return .empty,
        else => return .empty,
    };
    const properties = switch (plugin_config) {
        .object => |object| object.keys(),
        else => return .empty,
    };

    // every property is unknown, since zig fmt has no options
    var diagnostics: std.ArrayList(Diagnostic) = try .initCapacity(gpa, properties.len);
    errdefer {
        for (diagnostics.items) |diagnostic| gpa.free(diagnostic.property_name);
        diagnostics.deinit(gpa);
    }
    for (properties) |property_name| {
        diagnostics.appendAssumeCapacity(.{
            .property_name = try gpa.dupe(u8, property_name),
            .message = "Unknown property in configuration",
        });
    }
    return .{ .diagnostics = try diagnostics.toOwnedSlice(gpa) };
}

/// Writes the resolved configuration as JSON, which is an empty object.
pub fn writeResolvedConfig(w: *Writer, config: ResolvedConfig) Writer.Error!void {
    _ = config;
    try w.writeAll("{}");
}

/// Writes the diagnostics as JSON.
pub fn writeDiagnostics(w: *Writer, diagnostics: []const Diagnostic) Writer.Error!void {
    try w.writeByte('[');
    for (diagnostics, 0..) |diagnostic, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"propertyName\":");
        try std.json.Stringify.encodeJsonString(diagnostic.property_name, .{}, w);
        try w.writeAll(",\"message\":");
        try std.json.Stringify.encodeJsonString(diagnostic.message, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

const testing = std.testing;

fn expectDiagnosticsJson(raw_config: []const u8, expected: []const u8) !void {
    const config = try resolveConfig(testing.allocator, raw_config);
    defer config.deinit(testing.allocator);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeDiagnostics(&output.writer, config.diagnostics);
    try testing.expectEqualStrings(expected, output.written());
}

test "no diagnostics without plugin configuration" {
    try expectDiagnosticsJson("{\"plugin\":{},\"global\":{\"lineWidth\":80,\"newLineKind\":\"crlf\"}}", "[]");
    try expectDiagnosticsJson("{\"global\":{}}", "[]");
}

test "diagnostics for unknown properties" {
    try expectDiagnosticsJson(
        "{\"plugin\":{\"newLineKind\":\"lf\",\"some\\\"thing\":null},\"global\":{}}",
        "[{\"propertyName\":\"newLineKind\",\"message\":\"Unknown property in configuration\"}," ++
            "{\"propertyName\":\"some\\\"thing\",\"message\":\"Unknown property in configuration\"}]",
    );
}

test "resolved config is an empty object" {
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeResolvedConfig(&output.writer, .empty);
    try testing.expectEqualStrings("{}", output.written());
}
