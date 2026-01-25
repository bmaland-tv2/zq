//! Shared types for the ZON formatter.
const std = @import("std");

/// Error information from parsing or filtering ZON.
pub const ParseError = struct {
    message: []const u8,
    line: usize = 0,
    column: usize = 0,
    /// Optional context (e.g., field name that wasn't found)
    context: ?[]const u8 = null,

    pub fn write(self: ParseError, file: std.fs.File) void {
        var buf: [256]u8 = undefined;
        const has_location = self.line > 0 and self.column > 0;
        const msg = if (self.context) |ctx|
            if (has_location)
                std.fmt.bufPrint(&buf, "zq: {s}: '{s}' at line {d}, column {d}\n", .{
                    self.message,
                    ctx,
                    self.line,
                    self.column,
                }) catch return
            else
                std.fmt.bufPrint(&buf, "zq: {s}: '{s}'\n", .{
                    self.message,
                    ctx,
                }) catch return
        else if (has_location)
            std.fmt.bufPrint(&buf, "zq: {s} at line {d}, column {d}\n", .{
                self.message,
                self.line,
                self.column,
            }) catch return
        else
            std.fmt.bufPrint(&buf, "zq: {s}\n", .{self.message}) catch return;
        file.writeAll(msg) catch {};
    }
};

/// ANSI color codes for syntax highlighting
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";

    // Token colors (similar to jq's default colors)
    pub const null_literal = "\x1b[1;30m"; // bold black/gray for null
    pub const boolean = "\x1b[0;33m"; // yellow for booleans
    pub const number = "\x1b[0;36m"; // cyan for numbers
    pub const string = "\x1b[0;32m"; // green for strings
    pub const field_name = "\x1b[1;34m"; // bold blue for field names
    pub const punctuation = "\x1b[0m"; // default for punctuation
    pub const enum_literal = "\x1b[0;35m"; // magenta for enum literals
};

/// Options controlling ZON formatting behavior.
pub const FormatterOptions = struct {
    /// Number of spaces per indentation level (default: 2)
    indent_size: usize = 2,
    /// Whether to use ANSI color codes in output (default: true)
    use_colors: bool = true,
    /// Use tabs instead of spaces for indentation (default: false)
    use_tabs: bool = false,
    /// Filter to apply when extracting values (default: identity)
    filter: Filter = .identity,
    /// Output string values without quotes (default: false)
    raw_output: bool = false,
};

/// A segment in a filter path, representing either a field access or array index.
pub const PathSegment = union(enum) {
    /// Field access by name (e.g., .fieldName)
    field: []const u8,
    /// Array index access (e.g., .[0], or negative for .[−1])
    index: isize,
};

/// A filter for extracting values from ZON data.
/// Filters are parsed from jq-like expressions such as ".field.[0].nested".
pub const Filter = union(enum) {
    /// Identity filter "." - output the entire value unchanged
    identity,
    /// Path filter - extract a nested value via a sequence of field/index accesses
    path: []const PathSegment,
};

/// Error returned when a filter string cannot be parsed.
pub const FilterParseError = error{InvalidFilter};
