//! ZON entry splitting - splits multi-entry ZON input into separate entries.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Split input into separate ZON entries based on brace balancing.
/// Handles strings and line comments correctly.
/// Returns slices pointing into the original source.
pub fn splitZonEntries(source: []const u8, entries: *std.ArrayList([]const u8), gpa: Allocator) !void {
    var start: usize = 0;
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;

    while (i < source.len) : (i += 1) {
        const c = source[i];

        // Handle string literals (skip their contents)
        if (c == '"' and !isEscaped(source, i)) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        // Skip line comments (// to end of line)
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }

        if (c == '{') {
            if (depth == 0) start = findEntryStart(source, i);
            depth += 1;
        } else if (c == '}') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0) {
                    try entries.append(gpa, source[start .. i + 1]);
                }
            }
        }
    }
}

/// Check if the character at pos is escaped by counting preceding backslashes.
/// An odd number of backslashes means the character is escaped.
fn isEscaped(source: []const u8, pos: usize) bool {
    var backslashes: usize = 0;
    var j = pos;
    while (j > 0 and source[j - 1] == '\\') {
        backslashes += 1;
        j -= 1;
    }
    return backslashes % 2 == 1;
}

/// Find the start of a ZON entry (the '.' before the '{')
fn findEntryStart(source: []const u8, brace_pos: usize) usize {
    if (brace_pos > 0 and source[brace_pos - 1] == '.') {
        return brace_pos - 1;
    }
    return brace_pos;
}

test "split basic two entries" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries(".{.a=1}.{.b=2}", &entries, allocator);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expectEqualStrings(".{.a=1}", entries.items[0]);
    try std.testing.expectEqualStrings(".{.b=2}", entries.items[1]);
}

test "split escaped quotes in string" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    // String contains escaped quote - should not break parsing
    try splitZonEntries(".{.x=\"\\\"\"}.{.y=1}", &entries, allocator);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expectEqualStrings(".{.x=\"\\\"\"}", entries.items[0]);
    try std.testing.expectEqualStrings(".{.y=1}", entries.items[1]);
}

test "split nested braces" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries(".{.outer=.{.inner=1}}.{.b=2}", &entries, allocator);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expectEqualStrings(".{.outer=.{.inner=1}}", entries.items[0]);
    try std.testing.expectEqualStrings(".{.b=2}", entries.items[1]);
}

test "split empty input" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries("", &entries, allocator);
    try std.testing.expectEqual(0, entries.items.len);
}

test "split single entry" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries(".{.name=\"test\"}", &entries, allocator);
    try std.testing.expectEqual(1, entries.items.len);
    try std.testing.expectEqualStrings(".{.name=\"test\"}", entries.items[0]);
}

test "split whitespace between entries" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries(".{.a=1}  \n  .{.b=2}", &entries, allocator);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expectEqualStrings(".{.a=1}", entries.items[0]);
    try std.testing.expectEqualStrings(".{.b=2}", entries.items[1]);
}

test "split string containing braces" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries(".{.x=\"{}\"}  .{.y=1}", &entries, allocator);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expectEqualStrings(".{.x=\"{}\"}", entries.items[0]);
    try std.testing.expectEqualStrings(".{.y=1}", entries.items[1]);
}

test "split with line comments" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    // Comment contains braces that should be ignored
    try splitZonEntries(".{.a=1}// comment with {braces}\n.{.b=2}", &entries, allocator);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expectEqualStrings(".{.a=1}", entries.items[0]);
    try std.testing.expectEqualStrings(".{.b=2}", entries.items[1]);
}

test "split with comment at end" {
    const allocator = std.testing.allocator;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    try splitZonEntries(".{.a=1} // trailing comment", &entries, allocator);
    try std.testing.expectEqual(1, entries.items.len);
    try std.testing.expectEqualStrings(".{.a=1}", entries.items[0]);
}
