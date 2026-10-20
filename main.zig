//! The Wasm exports of the dprint plugin interface (schema version 4).
//! See https://github.com/dprint/dprint/blob/main/docs/wasm-plugin-development.md
//!
//! This is at the root of the repo so it can embed the VERSION and LICENSE files.

const std = @import("std");
const Plugin = @import("src/plugin.zig").Plugin;

const version = std.mem.trim(u8, @embedFile("VERSION"), " \r\n");
const license_text = @embedFile("LICENSE") ++ "\n\n---\n\nZig (its std is compiled into the plugin):\n\n" ++ @embedFile("third_party/zig/LICENSE");

var instance: Plugin = .init(std.heap.wasm_allocator);

export fn dprint_plugin_version_4() u32 {
    return 4;
}

export fn get_shared_bytes_ptr() u32 {
    return ptr(instance.sharedBytes());
}

export fn clear_shared_bytes(size: u32) u32 {
    return ptr(instance.clearSharedBytes(size) catch outOfMemory());
}

export fn get_plugin_info() u32 {
    return len(instance.pluginInfo(version));
}

export fn get_license_text() u32 {
    return len(instance.licenseText(license_text));
}

export fn register_config(config_id: u32) void {
    instance.registerConfig(config_id) catch outOfMemory();
}

export fn release_config(config_id: u32) void {
    instance.releaseConfig(config_id);
}

export fn get_config_diagnostics(config_id: u32) u32 {
    return len(instance.configDiagnostics(config_id));
}

export fn get_resolved_config(config_id: u32) u32 {
    return len(instance.resolvedConfigJson(config_id));
}

export fn get_config_file_matching(config_id: u32) u32 {
    return len(instance.configFileMatching(config_id));
}

export fn check_config_updates() u32 {
    return len(instance.checkConfigUpdates());
}

export fn set_file_path() void {
    instance.setFilePath();
}

export fn set_override_config() void {
    instance.setOverrideConfig();
}

export fn format(config_id: u32) u32 {
    const result = instance.format(config_id) catch outOfMemory();
    return @backingInt(result);
}

export fn format_range(config_id: u32, range_start: u32, range_end: u32) u32 {
    return @backingInt(instance.formatRange(config_id, range_start, range_end));
}

export fn get_formatted_text() u32 {
    return @intCast(instance.formattedText());
}

export fn get_error_text() u32 {
    return @intCast(instance.errorText());
}

fn ptr(bytes: []u8) u32 {
    return if (bytes.len == 0) 0 else @intCast(@intFromPtr(bytes.ptr));
}

fn len(result: std.mem.Allocator.Error!usize) u32 {
    return @intCast(result catch outOfMemory());
}

// traps, which makes the cli restart the plugin
fn outOfMemory() noreturn {
    @panic("out of memory");
}
