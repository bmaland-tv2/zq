const std = @import("std");
const zq = @import("zq");
const build_options = @import("build_options");

const Arg = enum {
    @"--version",
    @"-V",
    @"--help",
    @"-h",
    @"--monochrome-output",
    @"-M",
    @"--color-output",
    @"-C",
    @"--tab",
    @"--indent",
    @"--raw-output",
    @"-r",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_file = std.fs.File.stdout();
    var monochrome = false;
    var force_color = false;
    var use_tabs = false;
    var raw_output = false;
    var indent_size: usize = 2;
    var filter_str: []const u8 = ".";

    const help_message =
        \\Usage: zq [OPTIONS] [FILTER]
        \\
        \\A jq-like pretty printer for Zig ZON files.
        \\Reads ZON from stdin and outputs formatted ZON with syntax highlighting.
        \\
        \\Filter:
        \\  .             Output entire value (default)
        \\  .field        Extract field from struct
        \\  .a.b.c        Extract nested field
        \\  .[n]          Extract array element by index
        \\  .field.[n]    Combine field and index access
        \\
        \\Options:
        \\  -C, --color-output       Colorize output (override TTY detection)
        \\  -h, --help               Print this help message
        \\  --indent n               Number of spaces per indentation level (default 2, max 7)
        \\  -M, --monochrome-output  Disable colored output
        \\  -r, --raw-output         Output strings without quotes
        \\  --tab                    Use tabs for indentation
        \\  -V, --version            Print version information
        \\
        \\Examples:
        \\  cat file.zon | zq
        \\  zq < file.zon
        \\  echo '.{.name="test",.value=42}' | zq
        \\  zq .name < file.zon
        \\  zq .dependencies.zq.path < build.zig.zon
        \\  echo '.{"a","b","c"}' | zq '.[1]'
        \\
    ;

    // If no arguments and stdin is a TTY, show help
    const stdin = std.fs.File.stdin();
    if (args.len == 1 and stdin.isTty()) {
        try stdout_file.writeAll(help_message);
        return;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg_str = args[i];
        if (std.meta.stringToEnum(Arg, arg_str)) |arg| switch (arg) {
            .@"--version", .@"-V" => {
                try stdout_file.writeAll(build_options.version ++ "\n");
                return;
            },
            .@"--help", .@"-h" => {
                try stdout_file.writeAll(help_message);
                return;
            },
            .@"--monochrome-output", .@"-M" => monochrome = true,
            .@"--color-output", .@"-C" => force_color = true,
            .@"--tab" => use_tabs = true,
            .@"--raw-output", .@"-r" => raw_output = true,
            .@"--indent" => {
                const indent_err = "zq: --indent requires a number (0-7)\n";
                i += 1;
                if (i >= args.len) {
                    std.fs.File.stderr().writeAll(indent_err) catch {};
                    std.process.exit(1);
                }
                indent_size = std.fmt.parseInt(usize, args[i], 10) catch {
                    std.fs.File.stderr().writeAll(indent_err) catch {};
                    std.process.exit(1);
                };
                if (indent_size > 7) {
                    std.fs.File.stderr().writeAll(indent_err) catch {};
                    std.process.exit(1);
                }
            },
        } else if (arg_str.len > 0 and arg_str[0] == '.') {
            filter_str = arg_str;
        } else {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("zq: unknown argument: ") catch {};
            stderr.writeAll(arg_str) catch {};
            stderr.writeAll("\n") catch {};
            std.process.exit(1);
        }
    }

    const filter = zq.parseFilter(
        allocator,
        filter_str,
    ) catch {
        std.fs.File.stderr().writeAll("zq: invalid filter\n") catch {};
        std.process.exit(1);
    };
    defer if (filter == .path) allocator.free(filter.path);

    // Read all input from stdin (100MB limit)
    const max_input_size = 100 * 1024 * 1024;
    const source_raw = try stdin.readToEndAlloc(allocator, max_input_size);
    defer allocator.free(source_raw);

    // Create sentinel-terminated slice for the AST parser
    const source = try allocator.dupeZ(u8, source_raw);
    defer allocator.free(source);

    // Setup stdout with buffer
    var buffer: [4096]u8 = undefined;
    var stdout = stdout_file.writer(&buffer);

    // Check if stdout is a TTY to decide on colors
    // -C forces colors on, -M forces colors off (monochrome takes precedence)
    const use_colors = !monochrome and (force_color or stdout_file.isTty());

    // Format and write output (supports multi-entry ZON files)
    if (try zq.formatZonMulti(
        source,
        &stdout.interface,
        .{
            .use_colors = use_colors,
            .use_tabs = use_tabs,
            .indent_size = indent_size,
            .filter = filter,
            .raw_output = raw_output,
        },
        allocator,
    )) |parse_error| {
        parse_error.write(std.fs.File.stderr());
        std.process.exit(1);
    }

    stdout.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return,
    };
}
