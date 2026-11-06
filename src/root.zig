//! ZON formatter library - pretty prints ZON with indentation and colors.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const AstFormatter = @import("formatter.zig");
const ParseError = @import("types.zig").ParseError;
const Color = @import("types.zig").Color;
const FormatterOptions = @import("types.zig").FormatterOptions;
const splitZonEntries = @import("split.zig").splitZonEntries;

pub const Filter = @import("types.zig").Filter;
pub const FilterParseError = @import("types.zig").FilterParseError;
pub const parseFilter = @import("filter.zig").parseFilter;

/// Format multi-entry ZON source and write to the given writer
/// Handles files with multiple ZON entries (one per line or adjacent)
/// Returns a ParseError if any entry is invalid ZON, null on success
pub fn formatZonMulti(source: [:0]const u8, writer: *std.Io.Writer, options: FormatterOptions, gpa: Allocator) !?ParseError {
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(gpa);

    try splitZonEntries(source, &entries, gpa);

    // If single entry or empty, use existing path
    if (entries.items.len <= 1) {
        return formatZon(source, writer, options, gpa);
    }

    // Format each entry separately
    for (entries.items) |entry| {
        const entry_z = try gpa.dupeSentinel(u8, entry, 0);
        defer gpa.free(entry_z);

        if (try formatZon(entry_z, writer, options, gpa)) |err| {
            return err;
        }
    }
    return null;
}

/// Format ZON source and write to the given writer
/// Returns a ParseError if the input is invalid ZON, null on success
pub fn formatZon(source: [:0]const u8, writer: *std.Io.Writer, options: FormatterOptions, gpa: Allocator) !?ParseError {
    var ast = Ast.parse(gpa, source, .{ .mode = .zon }) catch {
        return .{ .message = "failed to parse ZON" };
    };
    defer ast.deinit(gpa);

    if (ast.errors.len > 0) {
        const err = ast.errors[0];
        const loc = ast.tokenLocation(0, err.token);
        return .{
            .message = @tagName(err.tag),
            .line = loc.line + 1,
            .column = loc.column + 1,
        };
    }

    var formatter = AstFormatter{
        .ast = &ast,
        .options = options,
        .writer = writer,
    };

    try formatter.format(@fromBackingInt(0)); // Root is always node 0

    // Check for semantic errors (e.g., invalid identifiers)
    if (formatter.semantic_error) |err| {
        return err;
    }
    return null;
}

test "format simple zon" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.name=\"test\",.value=42}";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result == null);

    const expected =
        \\.{
        \\  .name = "test",
        \\  .value = 42
        \\}
        \\
    ;
    const written = buffer[0 .. buffer.len - writer.unusedCapacityLen()];
    try std.testing.expectEqualStrings(expected, written);
}

test "parse error on invalid character" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.x=`}";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(1, result.?.line);
    try std.testing.expectEqual(6, result.?.column);
}

test "parse error on unclosed brace" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.name=\"test\"";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
}

test "parse error on unexpected closing brace" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.x=1}}";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
}

test "parse error on missing identifier after dot" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.name=\"test\",.=42}";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
}

test "parse error on bare identifier at top level" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = "asdf.{.name=\"test\"}";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
    // AST parser reports error at the `.{` position, not the start
}

test "parse error on bare identifier inside struct" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.name=\"test\",asdf.value=42}";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
}

test "parse error on standalone invalid identifier" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = "foo";
    const result = try formatZon(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("invalid identifier in ZON", result.?.message);
}

test "multi-entry: adjacent entries" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.a=1}.{.b=2}";
    const result = try formatZonMulti(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result == null);

    const expected =
        \\.{
        \\  .a = 1
        \\}
        \\.{
        \\  .b = 2
        \\}
        \\
    ;
    const written = buffer[0 .. buffer.len - writer.unusedCapacityLen()];
    try std.testing.expectEqualStrings(expected, written);
}

test "multi-entry: newline separated" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.a=1}\n.{.b=2}";
    const result = try formatZonMulti(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result == null);

    const expected =
        \\.{
        \\  .a = 1
        \\}
        \\.{
        \\  .b = 2
        \\}
        \\
    ;
    const written = buffer[0 .. buffer.len - writer.unusedCapacityLen()];
    try std.testing.expectEqualStrings(expected, written);
}

test "multi-entry: single entry still works" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.name=\"test\"}";
    const result = try formatZonMulti(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result == null);

    const expected =
        \\.{
        \\  .name = "test"
        \\}
        \\
    ;
    const written = buffer[0 .. buffer.len - writer.unusedCapacityLen()];
    try std.testing.expectEqualStrings(expected, written);
}

test "multi-entry: empty input" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = "";
    const result = try formatZonMulti(input, &writer, .{ .use_colors = false }, allocator);
    // Empty input goes through formatZon which handles it
    try std.testing.expect(result != null);
}

test "multi-entry: entries with strings containing braces" {
    const allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const input = ".{.x=\"{}\"}.{.y=1}";
    const result = try formatZonMulti(input, &writer, .{ .use_colors = false }, allocator);
    try std.testing.expect(result == null);

    const expected =
        \\.{
        \\  .x = "{}"
        \\}
        \\.{
        \\  .y = 1
        \\}
        \\
    ;
    const written = buffer[0 .. buffer.len - writer.unusedCapacityLen()];
    try std.testing.expectEqualStrings(expected, written);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("formatter.zig");
    _ = @import("filter.zig");
    _ = @import("split.zig");
    _ = @import("types.zig");
}
