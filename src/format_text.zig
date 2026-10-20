//! Formats Zig and ZON files the same way `zig fmt` does, with the parser and
//! renderer of Zig's std (`std.zig.Ast`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Writer = std.Io.Writer;

/// The file extensions `zig fmt` formats when walking a directory.
pub const file_extensions = [_][]const u8{ "zig", "zon" };

pub const FormatResult = union(enum) {
    /// The formatted text is the same as the file's text.
    no_change,
    /// The formatted text, which the caller owns.
    changed: []u8,
    /// Why the file couldn't be formatted, which the caller owns.
    failed: []u8,

    pub fn deinit(result: FormatResult, gpa: Allocator) void {
        switch (result) {
            .no_change => {},
            .changed, .failed => |text| gpa.free(text),
        }
    }
};

/// Formats the file the same way `zig fmt <file_path>` does.
pub fn formatText(gpa: Allocator, file_path: []const u8, file_bytes: []const u8) Allocator.Error!FormatResult {
    const source = decodeSource(gpa, file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedEncoding => return .{ .failed = try gpa.dupe(u8, "unsupported encoding: zig fmt only formats UTF-8 and UTF-16 little endian files") },
        error.InvalidEncoding => return .{ .failed = try gpa.dupe(u8, "invalid encoding: the file has a UTF-16 little endian byte order mark, but an odd number of bytes") },
    };
    defer gpa.free(source);

    var tree = try Ast.parse(gpa, source, .{ .mode = modeFromPath(file_path) });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        return .{ .failed = try renderParseErrors(gpa, tree) };
    }

    var output: Writer.Allocating = try .initCapacity(gpa, source.len);
    defer output.deinit();
    tree.render(gpa, &output.writer, .{}) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    if (std.mem.eql(u8, output.written(), file_bytes)) {
        return .no_change;
    }
    return .{ .changed = try output.toOwnedSlice() };
}

/// Gets whether to parse the file as Zig or ZON, the same way `zig fmt` does.
pub fn modeFromPath(file_path: []const u8) Ast.Mode {
    return if (std.mem.endsWith(u8, file_path, ".zon")) .zon else .zig;
}

/// Gets the null terminated source of the file, which is what
/// `std.zig.readSourceFileToEndAlloc` does after reading the file.
fn decodeSource(gpa: Allocator, file_bytes: []const u8) error{ OutOfMemory, UnsupportedEncoding, InvalidEncoding }![:0]u8 {
    const unsupported_boms = [_][]const u8{
        "\xff\xfe\x00\x00", // UTF-32 little endian
        "\xfe\xff\x00\x00", // UTF-32 big endian
        "\xfe\xff", // UTF-16 big endian
    };
    for (unsupported_boms) |bom| {
        if (std.mem.startsWith(u8, file_bytes, bom)) {
            return error.UnsupportedEncoding;
        }
    }

    // zig fmt translates UTF-16 little endian to UTF-8
    if (std.mem.startsWith(u8, file_bytes, "\xff\xfe")) {
        if (file_bytes.len % 2 != 0) return error.InvalidEncoding;
        // copied, since the file's bytes might not be aligned for u16
        const utf16 = try gpa.alloc(u16, file_bytes.len / 2);
        defer gpa.free(utf16);
        @memcpy(std.mem.sliceAsBytes(utf16), file_bytes);
        return std.unicode.utf16LeToUtf8AllocZ(gpa, utf16) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DanglingSurrogateHalf,
            error.ExpectedSecondSurrogateHalf,
            error.UnexpectedSecondSurrogateHalf,
            => error.UnsupportedEncoding,
        };
    }

    return gpa.dupeSentinel(u8, file_bytes, 0);
}

/// Renders the parse errors like `zig fmt` prints them, without the file path
/// at the start of each message, since dprint says which file failed.
///
/// Like `zig fmt`, this only reports the first error and its notes, since the
/// errors after it could be bogus. The messages and their locations are the ones
/// that `std.zig.AstGen` (or `std.zig.ZonGen` for ZON) makes from the parse
/// errors, and the text is what `std.zig.ErrorBundle` renders them as.
fn renderParseErrors(gpa: Allocator, tree: Ast) Allocator.Error![]u8 {
    var output: Writer.Allocating = .init(gpa);
    defer output.deinit();
    writeParseErrors(gpa, &output.writer, tree) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    // the last line ends with a newline, which dprint doesn't need
    const text = std.mem.trimEnd(u8, output.written(), "\n");
    return gpa.dupe(u8, text);
}

fn writeParseErrors(gpa: Allocator, w: *Writer, tree: Ast) (Writer.Error || Allocator.Error)!void {
    var message: Writer.Allocating = .init(gpa);
    defer message.deinit();

    const first_error = tree.errors[0];
    if (tree.mode == .zig) {
        // AstGen points at the invalid byte of a string literal or comment
        const token = first_error.token + @intFromBool(first_error.token_is_prev);
        if (invalidByteOffset(tree, token)) |offset| {
            try tree.renderError(.{ .tag = .invalid_byte, .token = token, .extra = .{ .offset = offset } }, &message.writer);
            const span = tokenSpan(tree, token, offset, offset);
            _ = try writeMessage(w, tree.source, "error", message.written(), span, null);
            return;
        }
    }

    try tree.renderError(first_error, &message.writer);
    const error_offset = tree.errorOffset(first_error);
    const error_span = tokenSpan(tree, first_error.token, error_offset, error_offset);
    const error_location = try writeMessage(w, tree.source, "error", message.written(), error_span, null);

    for (tree.errors[1..]) |note| {
        if (!note.is_note) break;
        message.clearRetainingCapacity();
        try tree.renderError(note, &message.writer);
        // AstGen shortens the span of a note by the error's offset, but ZonGen doesn't
        const end_offset = switch (tree.mode) {
            .zig => error_offset,
            .zon => 0,
        };
        const note_span = tokenSpan(tree, note.token, 0, end_offset);
        _ = try writeMessage(w, tree.source, "note", message.written(), note_span, error_location);
    }
}

/// Gets the offset of the first invalid byte in an invalid string literal or
/// comment token, the same way `std.zig.AstGen` finds it.
fn invalidByteOffset(tree: Ast, token: Ast.TokenIndex) ?u32 {
    if (tree.tokenTag(token) != .invalid) return null;
    const start = tree.tokenStart(token);
    const rest = tree.source[start..];
    switch (rest[0]) {
        '"', '\'', '/' => {},
        else => if (!std.mem.startsWith(u8, rest, "\\\\")) return null,
    }
    const slice = tree.tokenSlice(token);
    for (slice, 0..) |byte, i| {
        switch (byte) {
            0x00...0x09, 0x0b...0x1f, 0x7f => return @intCast(i),
            else => {},
        }
    }
    return @intCast(slice.len);
}

/// Gets the span of a token for an error message, which starts `offset` bytes
/// into the token and ends `end_offset` bytes before the token's end.
fn tokenSpan(tree: Ast, token: Ast.TokenIndex, offset: u32, end_offset: u32) Ast.Span {
    const start = tree.tokenStart(token) + offset;
    const token_len: u32 = @intCast(tree.tokenSlice(token).len);
    const end = (start + token_len) -| end_offset;
    return .{ .start = start, .end = end, .main = start };
}

/// Writes a message the way `std.zig.ErrorBundle` renders one without color.
/// A note only shows its source line when it's at a different location than its
/// error.
fn writeMessage(
    w: *Writer,
    source: []const u8,
    kind: []const u8,
    message: []const u8,
    span: Ast.Span,
    error_location: ?std.zig.Loc,
) Writer.Error!std.zig.Loc {
    const location = std.zig.findLineColumn(source, span.main);
    try w.print("{d}:{d}: {s}: {s}\n", .{ location.line + 1, location.column + 1, kind, message });
    if (error_location) |other| {
        if (location.eql(other)) return location;
    }

    for (location.source_line) |byte| {
        try w.writeByte(if (byte == '\t') ' ' else byte);
    }
    try w.writeByte('\n');
    const before_caret = span.main - span.start;
    const after_caret = span.end -| span.main -| 1;
    try w.splatByteAll(' ', location.column - before_caret);
    try w.splatByteAll('~', before_caret);
    try w.writeByte('^');
    try w.splatByteAll('~', after_caret);
    try w.writeByte('\n');
    return location;
}

const testing = std.testing;

fn expectFormat(file_path: []const u8, input: []const u8, expected: FormatResult) !void {
    const result = try formatText(testing.allocator, file_path, input);
    defer result.deinit(testing.allocator);
    switch (expected) {
        .no_change => try testing.expectEqual(.no_change, std.meta.activeTag(result)),
        .changed => |text| {
            try testing.expectEqual(.changed, std.meta.activeTag(result));
            try testing.expectEqualStrings(text, result.changed);
        },
        .failed => |text| {
            try testing.expectEqual(.failed, std.meta.activeTag(result));
            try testing.expectEqualStrings(text, result.failed);
        },
    }
}

test "formats zig" {
    try expectFormat("file.zig", "const   x = 1;\nfn  f() void {}", .{ .changed = @constCast("const x = 1;\nfn f() void {}\n") });
}

test "no change when already formatted" {
    try expectFormat("file.zig", "const x = 1;\n", .no_change);
    try expectFormat("file.zig", "", .no_change);
}

test "normalizes crlf to lf like zig fmt" {
    try expectFormat("file.zig", "const x = 1;\r\nconst y = 2;\r\n", .{ .changed = @constCast("const x = 1;\nconst y = 2;\n") });
}

test "removes the utf-8 bom like zig fmt" {
    try expectFormat("file.zig", "\xef\xbb\xbfconst x = 1;\n", .{ .changed = @constCast("const x = 1;\n") });
}

test "translates utf-16 le to utf-8 like zig fmt" {
    try expectFormat("file.zig", "\xff\xfe" ++ "c\x00o\x00n\x00s\x00t\x00 \x00x\x00=\x001\x00;\x00", .{ .changed = @constCast("const x = 1;\n") });
}

test "errors on unsupported encodings" {
    try expectFormat("file.zig", "\xfe\xffabc", .{ .failed = @constCast("unsupported encoding: zig fmt only formats UTF-8 and UTF-16 little endian files") });
    try expectFormat("file.zig", "\xff\xfeabc", .{ .failed = @constCast("invalid encoding: the file has a UTF-16 little endian byte order mark, but an odd number of bytes") });
}

test "formats zon by the file extension" {
    try expectFormat("build.zig.zon", ".{ .a = 1, .b = 2, }", .{ .changed = @constCast(".{\n    .a = 1,\n    .b = 2,\n}\n") });
    // a declaration isn't valid zon
    try expectFormat("file.zon", "const x = 1;\n", .{ .failed = @constCast("1:1: error: expected expression, found 'const'\nconst x = 1;\n^~~~~") });
    try expectFormat("file.zig", "const x = 1;\n", .no_change);
}

test "parse error points after the previous token" {
    try expectFormat("file.zig", "const x = 1\nconst y = 2;\n", .{ .failed = @constCast("1:12: error: expected ';' after declaration\nconst x = 1\n           ^") });
}

test "parse error replaces tabs in the source line" {
    try expectFormat("file.zig", "fn f() void {\n\tconst x = ;\n}\n", .{ .failed = @constCast("2:12: error: expected expression, found ';'\n const x = ;\n           ^") });
}

test "parse error with a note" {
    try expectFormat("file.zig", "const S = struct {\n    a: u8,\n    const x = 1;\n    b: u8,\n};\n", .{
        .failed = @constCast("3:5: error: declarations are not allowed between container fields\n    const x = 1;\n    ^~~~~\n" ++
            "2:5: note: field before declarations here\n    a: u8,\n    ^\n" ++
            "4:5: note: field after declarations here\n    b: u8,\n    ^"),
    });
}

test "parse error at an invalid byte" {
    try expectFormat("file.zig", "const s = \"a\x01b\";\n", .{ .failed = @constCast("1:13: error: string literal contains invalid byte: '\\x01'\nconst s = \"a\x01b\";\n            ^~~~") });
}

test "mode from path" {
    try testing.expectEqual(.zon, modeFromPath("build.zig.zon"));
    try testing.expectEqual(.zon, modeFromPath("/a/b/c.zon"));
    try testing.expectEqual(.zig, modeFromPath("/a/b/c.zig"));
    // zig fmt only checks the extension case sensitively
    try testing.expectEqual(.zig, modeFromPath("/a/b/c.ZON"));
}
