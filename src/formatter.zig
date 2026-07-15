//! AST formatter - walks ZON AST and outputs with indentation and colors.
const std = @import("std");
const Ast = std.zig.Ast;
const types = @import("types.zig");
const Color = types.Color;
const FormatterOptions = types.FormatterOptions;
const ParseError = types.ParseError;
const Filter = types.Filter;
const PathSegment = types.PathSegment;

ast: *const Ast,
options: FormatterOptions,
writer: *std.Io.Writer,
indent_level: usize = 0,
at_line_start: bool = true,
semantic_error: ?ParseError = null,

fn isStructInit(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma => true,
        else => false,
    };
}

fn isArrayInit(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma => true,
        else => false,
    };
}

fn writeColor(self: *@This(), color: []const u8) !void {
    if (self.options.use_colors) {
        try self.writer.writeAll(color);
    }
}

fn writeIndent(self: *@This()) !void {
    if (self.at_line_start) {
        if (self.options.use_tabs) {
            try self.writer.splatByteAll('\t', self.indent_level);
        } else {
            const spaces = self.indent_level * self.options.indent_size;
            try self.writer.splatByteAll(' ', spaces);
        }
        self.at_line_start = false;
    }
}

fn writeNewline(self: *@This()) !void {
    try self.writer.writeByte('\n');
    self.at_line_start = true;
}

fn writeColored(self: *@This(), color: []const u8, prefix: ?u8, text: []const u8) !void {
    try self.writeColor(color);
    if (prefix) |p| try self.writer.writeByte(p);
    try self.writer.writeAll(text);
    try self.writeColor(Color.reset);
}

fn tokenSlice(self: *@This(), token_index: Ast.TokenIndex) []const u8 {
    return self.ast.tokenSlice(token_index);
}

/// Note: uses anyerror due to mutual recursion with formatFilteredPath
pub fn format(self: *@This(), node: Ast.Node.Index) anyerror!void {
    const tag = self.ast.nodeTag(node);
    const data = self.ast.nodeData(node);

    switch (tag) {
        .root => {
            // Root contains the actual ZON expression in data.node
            const inner_node = data.node;
            switch (self.options.filter) {
                .identity => {
                    try self.format(inner_node);
                    if (!self.at_line_start) {
                        try self.writeNewline();
                    }
                },
                .path => |path| {
                    try self.formatFilteredPath(inner_node, path);
                },
            }
        },
        .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma => {
            try self.formatInit(node, true);
        },
        .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma => {
            try self.formatInit(node, false);
        },
        .number_literal => {
            const token = self.ast.nodeMainToken(node);
            try self.writeIndent();
            try self.writeColored(Color.number, null, self.tokenSlice(token));
        },
        .string_literal, .char_literal => {
            const token = self.ast.nodeMainToken(node);
            try self.writeIndent();
            try self.writeColored(Color.string, null, self.tokenSlice(token));
        },
        .multiline_string_literal => {
            const src = self.ast.getNodeSource(node);
            try self.writeIndent();
            try self.writeColored(Color.string, null, src);
        },
        .enum_literal => {
            const token = self.ast.nodeMainToken(node);
            try self.writeIndent();
            try self.writeColored(Color.enum_literal, '.', self.tokenSlice(token));
        },
        .identifier => {
            const token = self.ast.nodeMainToken(node);
            const ident = self.tokenSlice(token);
            if (std.mem.eql(u8, ident, "null")) {
                try self.writeIndent();
                try self.writeColored(Color.null_literal, null, "null");
            } else if (std.mem.eql(u8, ident, "true") or std.mem.eql(u8, ident, "false")) {
                try self.writeIndent();
                try self.writeColored(Color.boolean, null, ident);
            } else {
                // Invalid identifier in ZON - only null/true/false are allowed
                const loc = self.ast.tokenLocation(0, token);
                self.semantic_error = .{
                    .message = "invalid identifier in ZON",
                    .line = loc.line + 1,
                    .column = loc.column + 1,
                };
            }
        },
        .negation => {
            const operand = data.node;
            const operand_token = self.ast.nodeMainToken(operand);
            try self.writeIndent();
            try self.writeColored(Color.number, '-', self.tokenSlice(operand_token));
        },
        else => {
            const token = self.ast.nodeMainToken(node);
            const loc = self.ast.tokenLocation(0, token);
            self.semantic_error = .{
                .message = "unexpected node in ZON",
                .line = loc.line + 1,
                .column = loc.column + 1,
            };
        },
    }
}

/// Extract a value at the given path (e.g., [.field, .index] for .field.[0])
/// Note: uses anyerror due to mutual recursion with format
fn formatFilteredPath(self: *@This(), node: Ast.Node.Index, path: []const PathSegment) anyerror!void {
    if (path.len == 0) {
        // Base case: path exhausted, format the current node
        // Handle raw output for string literals
        if (self.options.raw_output) {
            const tag = self.ast.nodeTag(node);
            if (tag == .string_literal) {
                const token = self.ast.nodeMainToken(node);
                const slice = self.tokenSlice(token);
                // Strip surrounding quotes
                if (slice.len >= 2 and slice[0] == '"' and slice[slice.len - 1] == '"') {
                    try self.writer.writeAll(slice[1 .. slice.len - 1]);
                    try self.writeNewline();
                    return;
                }
            }
        }
        try self.format(node);
        if (!self.at_line_start) {
            try self.writeNewline();
        }
        return;
    }

    const tag = self.ast.nodeTag(node);
    switch (path[0]) {
        .field => |target_field| {
            if (!isStructInit(tag)) {
                self.semantic_error = .{
                    .message = "cannot extract field from non-struct",
                    .context = target_field,
                };
                return;
            }

            var buf: [2]Ast.Node.Index = undefined;
            const full = self.ast.fullStructInit(&buf, node) orelse return;

            for (full.ast.fields) |elem| {
                const first_token = self.ast.firstToken(elem);
                const field_name = self.tokenSlice(first_token - 2);
                if (std.mem.eql(u8, field_name, target_field)) {
                    // Recurse with remaining path
                    try self.formatFilteredPath(elem, path[1..]);
                    return;
                }
            }

            self.semantic_error = .{
                .message = "field not found",
                .context = target_field,
            };
        },
        .index => |target_index| {
            if (!isArrayInit(tag)) {
                self.semantic_error = .{
                    .message = "cannot index non-array value",
                };
                return;
            }

            var buf: [2]Ast.Node.Index = undefined;
            const full = self.ast.fullArrayInit(&buf, node) orelse return;
            const len: isize = @intCast(full.ast.elements.len);

            // Handle negative indices (e.g., -1 = last element)
            const actual_index: usize = if (target_index < 0)
                @intCast(len + target_index)
            else
                @intCast(target_index);

            if (actual_index >= full.ast.elements.len) {
                self.semantic_error = .{
                    .message = "array index out of bounds",
                };
                return;
            }
            try self.formatFilteredPath(full.ast.elements[actual_index], path[1..]);
        },
    }
}

/// Format struct or array initializer. When is_struct is true, prints field names.
fn formatInit(self: *@This(), node: Ast.Node.Index, is_struct: bool) !void {
    var buf: [2]Ast.Node.Index = undefined;
    const items = if (is_struct)
        (self.ast.fullStructInit(&buf, node) orelse return).ast.fields
    else
        (self.ast.fullArrayInit(&buf, node) orelse return).ast.elements;

    try self.writeIndent();
    try self.writeColored(Color.punctuation, null, ".{");

    if (items.len == 0) {
        try self.writer.writeByte('}');
        return;
    }

    self.indent_level += 1;
    try self.writeNewline();

    for (items, 0..) |elem, i| {
        if (is_struct) {
            // Field names are: . identifier = value
            // firstToken points to the start of value, so we look 2 tokens back for the identifier
            const first_token = self.ast.firstToken(elem);
            const field_name = self.tokenSlice(first_token - 2);
            try self.writeIndent();
            try self.writeColored(Color.field_name, '.', field_name);
            try self.writer.writeAll(" = ");
            self.at_line_start = false;
        }

        try self.format(elem);

        if (i < items.len - 1) {
            try self.writeColored(Color.punctuation, null, ",");
        }
        try self.writeNewline();
    }

    self.indent_level -= 1;
    try self.writeIndent();
    try self.writeColored(Color.punctuation, null, "}");
}
