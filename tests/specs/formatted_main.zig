//! Already formatted, so the plugin reports no change.

const std = @import("std");

pub fn main() void {
    const message =
        \\hello
        \\world
    ;
    std.debug.print("{s}\n", .{message});
}

const Color = enum {
    red,
    green,
    blue,

    pub fn isRed(color: Color) bool {
        return color == .red;
    }
};
