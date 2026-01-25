//! Filter parsing - converts filter strings like ".foo.bar" or ".foo.[0]" into Filter type.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Filter = types.Filter;
const PathSegment = types.PathSegment;
const FilterParseError = types.FilterParseError;

/// Parse a jq-like filter string into a Filter.
///
/// Supported syntax:
/// - `.` or empty string: identity filter (output entire value)
/// - `.field`: extract field from struct
/// - `.a.b.c`: extract nested fields
/// - `.[n]`: extract array element by index (0-based, negative for end)
/// - `.field.[n].other`: combine field and index access
///
/// **Lifetime**: The returned `PathSegment.field` slices reference the input
/// `filter_str`. Callers must ensure `filter_str` outlives the returned Filter.
///
/// **Memory**: Caller owns the returned path slice and must free it with
/// `allocator.free(filter.path)` when done (only if filter is `.path`).
pub fn parseFilter(
    allocator: Allocator,
    filter_str: []const u8,
) (Allocator.Error || FilterParseError)!Filter {
    const trimmed = std.mem.trim(u8, filter_str, " \t\n\r");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) {
        return .identity;
    }
    if (trimmed[0] != '.') return error.InvalidFilter;

    // Use ArrayList to collect segments
    var segments: std.ArrayList(PathSegment) = .empty;
    errdefer segments.deinit(allocator);

    var pos: usize = 1; // Skip initial '.'
    while (pos < trimmed.len) {
        if (trimmed[pos] == '[') {
            // Array index: .[n] (supports negative indices like .[-1])
            const end = std.mem.indexOfScalarPos(u8, trimmed, pos, ']') orelse
                return error.InvalidFilter;
            const index_str = trimmed[pos + 1 .. end];
            const index = std.fmt.parseInt(isize, index_str, 10) catch
                return error.InvalidFilter;
            try segments.append(allocator, .{ .index = index });
            pos = end + 1;
        } else {
            // Field name
            var end = pos;
            while (end < trimmed.len and trimmed[end] != '.' and trimmed[end] != '[') : (end += 1) {}
            const field = trimmed[pos..end];
            if (!isValidIdentifier(field)) return error.InvalidFilter;
            try segments.append(allocator, .{ .field = field });
            pos = end;
        }
        if (pos < trimmed.len and trimmed[pos] == '.') pos += 1;
    }

    if (segments.items.len == 0) return .identity;
    return .{ .path = try segments.toOwnedSlice(allocator) };
}

fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

test "parseFilter identity" {
    const allocator = std.testing.allocator;
    const f1 = try parseFilter(allocator, ".");
    try std.testing.expect(f1 == .identity);

    const f2 = try parseFilter(allocator, "");
    try std.testing.expect(f2 == .identity);

    const f3 = try parseFilter(allocator, "  .  ");
    try std.testing.expect(f3 == .identity);
}

test "parseFilter single field" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, ".name");
    defer allocator.free(f.path);

    try std.testing.expectEqual(1, f.path.len);
    try std.testing.expectEqualStrings("name", f.path[0].field);
}

test "parseFilter nested path" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, ".outer.inner.deep");
    defer allocator.free(f.path);

    try std.testing.expectEqual(3, f.path.len);
    try std.testing.expectEqualStrings("outer", f.path[0].field);
    try std.testing.expectEqualStrings("inner", f.path[1].field);
    try std.testing.expectEqualStrings("deep", f.path[2].field);
}

test "parseFilter invalid - no leading dot" {
    const allocator = std.testing.allocator;
    const result = parseFilter(allocator, "name");
    try std.testing.expectError(error.InvalidFilter, result);
}

test "parseFilter invalid - empty segment" {
    const allocator = std.testing.allocator;
    const result = parseFilter(allocator, ".foo..bar");
    try std.testing.expectError(error.InvalidFilter, result);
}

test "parseFilter invalid - number start" {
    const allocator = std.testing.allocator;
    const result = parseFilter(allocator, ".123");
    try std.testing.expectError(error.InvalidFilter, result);
}

test "parseFilter valid with underscore" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, "._name.field_2");
    defer allocator.free(f.path);

    try std.testing.expectEqual(2, f.path.len);
    try std.testing.expectEqualStrings("_name", f.path[0].field);
    try std.testing.expectEqualStrings("field_2", f.path[1].field);
}

test "parseFilter array index" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, ".[0]");
    defer allocator.free(f.path);

    try std.testing.expectEqual(1, f.path.len);
    try std.testing.expectEqual(@as(isize, 0), f.path[0].index);
}

test "parseFilter negative index" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, ".[-1]");
    defer allocator.free(f.path);

    try std.testing.expectEqual(1, f.path.len);
    try std.testing.expectEqual(@as(isize, -1), f.path[0].index);
}

test "parseFilter negative index -2" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, ".items.[-2]");
    defer allocator.free(f.path);

    try std.testing.expectEqual(2, f.path.len);
    try std.testing.expectEqualStrings("items", f.path[0].field);
    try std.testing.expectEqual(@as(isize, -2), f.path[1].index);
}

test "parseFilter mixed field and index" {
    const allocator = std.testing.allocator;
    const f = try parseFilter(allocator, ".items.[1].name");
    defer allocator.free(f.path);

    try std.testing.expectEqual(3, f.path.len);
    try std.testing.expectEqualStrings("items", f.path[0].field);
    try std.testing.expectEqual(@as(isize, 1), f.path[1].index);
    try std.testing.expectEqualStrings("name", f.path[2].field);
}

test "parseFilter invalid - unclosed bracket" {
    const allocator = std.testing.allocator;
    const result = parseFilter(allocator, ".[0");
    try std.testing.expectError(error.InvalidFilter, result);
}

test "parseFilter invalid - non-numeric index" {
    const allocator = std.testing.allocator;
    const result = parseFilter(allocator, ".[abc]");
    try std.testing.expectError(error.InvalidFilter, result);
}
