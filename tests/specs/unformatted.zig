const std = @import( "std" );
const   Allocator=std.mem.Allocator;

/// A point.
pub const Point = struct { x: i32, y: i32,
    pub fn add(self: Point, other: Point) Point {
    return .{ .x = self.x+other.x, .y = self.y + other.y };
    }
};

pub fn sum(values: []const i32) i32 {
    var total: i32 = 0;
    for (values) |value| { total += value; }
    return total;
}

test "sum" {
	try std.testing.expectEqual(@as(i32, 6), sum(&.{ 1, 2, 3 }));
}

fn kind(c: u8) []const u8 {
    return switch (c) { 'a'...'z' => "lower", 'A'...'Z' => "upper", else => "other" };
}
// trailing comment   
