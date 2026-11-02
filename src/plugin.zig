//! The state behind the exports of dprint's Wasm plugin interface (schema
//! version 4), which main.zig exports.
//!
//! See https://github.com/dprint/dprint/blob/main/docs/wasm-plugin-development.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const config = @import("config.zig");
pub const format_text = @import("format_text.zig");

/// What `format` tells the host.
pub const FormatResult = enum(u32) {
    no_change = 0,
    changed = 1,
    failed = 2,
};

/// The plugin's state between calls from the host. Data goes back and forth
/// through the shared bytes: the host writes to the buffer that
/// `clearSharedBytes` allocates before a call, and reads the buffer of
/// `sharedBytes` after a call that returns a length.
pub const Plugin = struct {
    gpa: Allocator,
    shared_bytes: []u8 = &.{},
    configs: std.ArrayList(RegisteredConfig) = .empty,
    file_path: []u8 = &.{},
    formatted_text: []u8 = &.{},
    error_text: []u8 = &.{},

    const RegisteredConfig = struct {
        id: u32,
        resolved: config.ResolvedConfig,
    };

    pub fn init(gpa: Allocator) Plugin {
        return .{ .gpa = gpa };
    }

    pub fn deinit(plugin: *Plugin) void {
        const gpa = plugin.gpa;
        gpa.free(plugin.shared_bytes);
        for (plugin.configs.items) |registered| registered.resolved.deinit(gpa);
        plugin.configs.deinit(gpa);
        gpa.free(plugin.file_path);
        gpa.free(plugin.formatted_text);
        gpa.free(plugin.error_text);
        plugin.* = undefined;
    }

    pub fn sharedBytes(plugin: *const Plugin) []u8 {
        return plugin.shared_bytes;
    }

    /// Replaces the shared bytes with `size` zeroed bytes for the host to write to.
    pub fn clearSharedBytes(plugin: *Plugin, size: usize) Allocator.Error![]u8 {
        const bytes = try plugin.gpa.alloc(u8, size);
        @memset(bytes, 0);
        plugin.setSharedBytes(bytes);
        return bytes;
    }

    /// Stores the plugin info and returns its length.
    pub fn pluginInfo(plugin: *Plugin, version: []const u8) Allocator.Error!usize {
        return plugin.writeSharedBytes(writePluginInfo, version);
    }

    pub fn licenseText(plugin: *Plugin, text: []const u8) Allocator.Error!usize {
        plugin.setSharedBytes(try plugin.gpa.dupe(u8, text));
        return text.len;
    }

    /// Resolves the configuration in the shared bytes and stores it under the id.
    pub fn registerConfig(plugin: *Plugin, config_id: u32) Allocator.Error!void {
        const raw_config = plugin.takeSharedBytes();
        defer plugin.gpa.free(raw_config);
        const resolved = try config.resolveConfig(plugin.gpa, raw_config);
        errdefer resolved.deinit(plugin.gpa);

        plugin.releaseConfig(config_id);
        try plugin.configs.append(plugin.gpa, .{ .id = config_id, .resolved = resolved });
    }

    pub fn releaseConfig(plugin: *Plugin, config_id: u32) void {
        for (plugin.configs.items, 0..) |registered, i| {
            if (registered.id == config_id) {
                registered.resolved.deinit(plugin.gpa);
                _ = plugin.configs.swapRemove(i);
                return;
            }
        }
    }

    pub fn configDiagnostics(plugin: *Plugin, config_id: u32) Allocator.Error!usize {
        return plugin.writeSharedBytes(writeDiagnostics, plugin.resolvedConfig(config_id));
    }

    pub fn resolvedConfigJson(plugin: *Plugin, config_id: u32) Allocator.Error!usize {
        return plugin.writeSharedBytes(writeResolvedConfig, plugin.resolvedConfig(config_id));
    }

    pub fn configFileMatching(plugin: *Plugin, config_id: u32) Allocator.Error!usize {
        _ = config_id;
        return plugin.writeSharedBytes(writeFileMatching, {});
    }

    /// Reports that no configuration changes are needed after upgrading the plugin.
    pub fn checkConfigUpdates(plugin: *Plugin) Allocator.Error!usize {
        plugin.gpa.free(plugin.takeSharedBytes());
        const response = "{\"kind\":\"ok\",\"data\":[]}";
        plugin.setSharedBytes(try plugin.gpa.dupe(u8, response));
        return response.len;
    }

    /// Takes the configuration that only applies to the next format. There's
    /// nothing in it that changes the output, since zig fmt has no options.
    pub fn setOverrideConfig(plugin: *Plugin) void {
        plugin.gpa.free(plugin.takeSharedBytes());
    }

    pub fn setFilePath(plugin: *Plugin) void {
        plugin.gpa.free(plugin.file_path);
        plugin.file_path = plugin.takeSharedBytes();
        // windows paths have backslashes
        std.mem.replaceScalar(u8, plugin.file_path, '\\', '/');
    }

    /// Formats the file text in the shared bytes, for the file path set before it.
    pub fn format(plugin: *Plugin, config_id: u32) Allocator.Error!FormatResult {
        _ = config_id;
        const file_bytes = plugin.takeSharedBytes();
        defer plugin.gpa.free(file_bytes);
        const file_path = plugin.takeFilePath();
        defer plugin.gpa.free(file_path);

        switch (try format_text.formatText(plugin.gpa, file_path, file_bytes)) {
            .no_change => return .no_change,
            .changed => |text| {
                plugin.gpa.free(plugin.formatted_text);
                plugin.formatted_text = text;
                return .changed;
            },
            .failed => |text| {
                plugin.gpa.free(plugin.error_text);
                plugin.error_text = text;
                return .failed;
            },
        }
    }

    /// Formats a range of the file text, which zig fmt doesn't support, so it's
    /// left as it is.
    pub fn formatRange(plugin: *Plugin, config_id: u32, range_start: u32, range_end: u32) FormatResult {
        _ = .{ config_id, range_start, range_end };
        plugin.gpa.free(plugin.takeSharedBytes());
        plugin.gpa.free(plugin.takeFilePath());
        return .no_change;
    }

    pub fn formattedText(plugin: *Plugin) usize {
        const text = plugin.formatted_text;
        plugin.formatted_text = &.{};
        plugin.setSharedBytes(text);
        return text.len;
    }

    pub fn errorText(plugin: *Plugin) usize {
        const text = plugin.error_text;
        plugin.error_text = &.{};
        plugin.setSharedBytes(text);
        return text.len;
    }

    /// Gets the resolved config of the id, which is the default config for an id
    /// the host never registered.
    fn resolvedConfig(plugin: *const Plugin, config_id: u32) config.ResolvedConfig {
        for (plugin.configs.items) |registered| {
            if (registered.id == config_id) return registered.resolved;
        }
        return .empty;
    }

    fn writeSharedBytes(
        plugin: *Plugin,
        comptime writeFn: anytype,
        data: anytype,
    ) Allocator.Error!usize {
        var output: Writer.Allocating = .init(plugin.gpa);
        defer output.deinit();
        writeFn(&output.writer, data) catch return error.OutOfMemory;
        const bytes = try output.toOwnedSlice();
        plugin.setSharedBytes(bytes);
        return bytes.len;
    }

    fn setSharedBytes(plugin: *Plugin, bytes: []u8) void {
        plugin.gpa.free(plugin.shared_bytes);
        plugin.shared_bytes = bytes;
    }

    fn takeSharedBytes(plugin: *Plugin) []u8 {
        const bytes = plugin.shared_bytes;
        plugin.shared_bytes = &.{};
        return bytes;
    }

    fn takeFilePath(plugin: *Plugin) []u8 {
        const file_path = plugin.file_path;
        plugin.file_path = &.{};
        return file_path;
    }
};

fn writePluginInfo(w: *Writer, version: []const u8) Writer.Error!void {
    try w.writeAll("{\"name\":\"dprint-plugin-zig\",\"version\":");
    try std.json.Stringify.encodeJsonString(version, .{}, w);
    try w.writeAll(",\"configKey\":\"zig\",\"helpUrl\":\"https://dprint.dev/plugins/zig\",\"configSchemaUrl\":\"");
    try w.print("https://plugins.dprint.dev/dprint/dprint-plugin-zig/{s}/schema.json", .{version});
    try w.writeAll("\",\"updateUrl\":\"https://plugins.dprint.dev/dprint/dprint-plugin-zig/latest.json\",\"supportsRangeFormatting\":false}");
}

fn writeDiagnostics(w: *Writer, resolved: config.ResolvedConfig) Writer.Error!void {
    try config.writeDiagnostics(w, resolved.diagnostics);
}

fn writeResolvedConfig(w: *Writer, resolved: config.ResolvedConfig) Writer.Error!void {
    try config.writeResolvedConfig(w, resolved);
}

fn writeFileMatching(w: *Writer, _: void) Writer.Error!void {
    try w.writeAll("{\"fileExtensions\":[");
    for (format_text.file_extensions, 0..) |extension, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.Stringify.encodeJsonString(extension, .{}, w);
    }
    try w.writeAll("],\"fileNames\":[],\"additive\":false}");
}

test {
    _ = config;
    _ = format_text;
}

const testing = std.testing;

/// Sends the bytes the way the host does, by writing them to the buffer that
/// `clearSharedBytes` allocates.
fn sendBytes(plugin: *Plugin, bytes: []const u8) !void {
    @memcpy(try plugin.clearSharedBytes(bytes.len), bytes);
}

fn expectSharedBytes(plugin: *const Plugin, len: usize, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, plugin.sharedBytes()[0..len]);
}

test "plugin info" {
    var plugin: Plugin = .init(testing.allocator);
    defer plugin.deinit();
    const len = try plugin.pluginInfo("1.2.3");
    try expectSharedBytes(&plugin, len, "{\"name\":\"dprint-plugin-zig\",\"version\":\"1.2.3\",\"configKey\":\"zig\"," ++
        "\"helpUrl\":\"https://dprint.dev/plugins/zig\"," ++
        "\"configSchemaUrl\":\"https://plugins.dprint.dev/dprint/dprint-plugin-zig/1.2.3/schema.json\"," ++
        "\"updateUrl\":\"https://plugins.dprint.dev/dprint/dprint-plugin-zig/latest.json\",\"supportsRangeFormatting\":false}");
}

test "config" {
    var plugin: Plugin = .init(testing.allocator);
    defer plugin.deinit();
    try sendBytes(&plugin, "{\"plugin\":{\"indentWidth\":2},\"global\":{\"indentWidth\":4}}");
    try plugin.registerConfig(1);
    try sendBytes(&plugin, "{\"plugin\":{},\"global\":{}}");
    try plugin.registerConfig(2);

    try expectSharedBytes(&plugin, try plugin.configDiagnostics(1), "[{\"propertyName\":\"indentWidth\",\"message\":\"Unknown property in configuration\"}]");
    try expectSharedBytes(&plugin, try plugin.configDiagnostics(2), "[]");
    try expectSharedBytes(&plugin, try plugin.resolvedConfigJson(1), "{}");
    try expectSharedBytes(&plugin, try plugin.configFileMatching(1), "{\"fileExtensions\":[\"zig\",\"zon\"],\"fileNames\":[],\"additive\":false}");

    // registering an id again replaces its config
    try sendBytes(&plugin, "{\"plugin\":{},\"global\":{}}");
    try plugin.registerConfig(1);
    try expectSharedBytes(&plugin, try plugin.configDiagnostics(1), "[]");

    plugin.releaseConfig(2);
    try testing.expectEqual(1, plugin.configs.items.len);
    // an unknown id gets the defaults
    try expectSharedBytes(&plugin, try plugin.configDiagnostics(3), "[]");
}

test "check config updates" {
    var plugin: Plugin = .init(testing.allocator);
    defer plugin.deinit();
    try sendBytes(&plugin, "{\"oldVersion\":\"0.1.0\",\"config\":{}}");
    try expectSharedBytes(&plugin, try plugin.checkConfigUpdates(), "{\"kind\":\"ok\",\"data\":[]}");
}

test "format" {
    var plugin: Plugin = .init(testing.allocator);
    defer plugin.deinit();
    try sendBytes(&plugin, "{\"plugin\":{},\"global\":{}}");
    try plugin.registerConfig(1);

    // changed
    try sendBytes(&plugin, "C:\\dir\\file.zig");
    plugin.setFilePath();
    try sendBytes(&plugin, "const   x = 1;");
    try testing.expectEqual(.changed, try plugin.format(1));
    try expectSharedBytes(&plugin, plugin.formattedText(), "const x = 1;\n");

    // no change
    try sendBytes(&plugin, "file.zig");
    plugin.setFilePath();
    try sendBytes(&plugin, "const x = 1;\n");
    try testing.expectEqual(.no_change, try plugin.format(1));

    // an override config doesn't change anything
    try sendBytes(&plugin, "{\"indentWidth\":2}");
    plugin.setOverrideConfig();
    try sendBytes(&plugin, "file.zig");
    plugin.setFilePath();
    try sendBytes(&plugin, "fn f() void {\nreturn;\n}\n");
    try testing.expectEqual(.changed, try plugin.format(1));
    try expectSharedBytes(&plugin, plugin.formattedText(), "fn f() void {\n    return;\n}\n");

    // error
    try sendBytes(&plugin, "file.zig");
    plugin.setFilePath();
    try sendBytes(&plugin, "const x = 1");
    try testing.expectEqual(.failed, try plugin.format(1));
    try expectSharedBytes(&plugin, plugin.errorText(), "1:12: error: expected ';' after declaration\nconst x = 1\n           ^");

    // zon from the windows path
    try sendBytes(&plugin, "C:\\dir\\build.zig.zon");
    plugin.setFilePath();
    try sendBytes(&plugin, ".{ .a = 1, }");
    try testing.expectEqual(.changed, try plugin.format(1));
    try expectSharedBytes(&plugin, plugin.formattedText(), ".{\n    .a = 1,\n}\n");
}

test "format range leaves the file as it is" {
    var plugin: Plugin = .init(testing.allocator);
    defer plugin.deinit();
    try sendBytes(&plugin, "file.zig");
    plugin.setFilePath();
    try sendBytes(&plugin, "const   x = 1;");
    try testing.expectEqual(.no_change, plugin.formatRange(1, 0, 5));
    try testing.expectEqual(0, plugin.sharedBytes().len);
    try testing.expectEqual(0, plugin.file_path.len);
}
