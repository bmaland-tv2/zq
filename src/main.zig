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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const stdout_file = std.Io.File.stdout();
    const stdin_file = std.Io.File.stdin();
    const stderr_file = std.Io.File.stderr();

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

    // Parse command line arguments
    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();
    _ = args_it.skip(); // Skip program name

    var saw_any_arg = false;
    while (args_it.next()) |arg_str| {
        saw_any_arg = true;
        if (std.meta.stringToEnum(Arg, arg_str)) |arg| switch (arg) {
            .@"--version", .@"-V" => {
                try stdout_file.writeStreamingAll(io, build_options.version ++ "\n");
                return;
            },
            .@"--help", .@"-h" => {
                try stdout_file.writeStreamingAll(io, help_message);
                return;
            },
            .@"--monochrome-output", .@"-M" => monochrome = true,
            .@"--color-output", .@"-C" => force_color = true,
            .@"--tab" => use_tabs = true,
            .@"--raw-output", .@"-r" => raw_output = true,
            .@"--indent" => {
                const indent_err = "zq: --indent requires a number (0-7)\n";
                const value = args_it.next() orelse {
                    stderr_file.writeStreamingAll(io, indent_err) catch {};
                    std.process.exit(1);
                };
                indent_size = std.fmt.parseInt(usize, value, 10) catch {
                    stderr_file.writeStreamingAll(io, indent_err) catch {};
                    std.process.exit(1);
                };
                if (indent_size > 7) {
                    stderr_file.writeStreamingAll(io, indent_err) catch {};
                    std.process.exit(1);
                }
            },
        } else if (arg_str.len > 0 and arg_str[0] == '.') {
            filter_str = arg_str;
        } else {
            stderr_file.writeStreamingAll(io, "zq: unknown argument: ") catch {};
            stderr_file.writeStreamingAll(io, arg_str) catch {};
            stderr_file.writeStreamingAll(io, "\n") catch {};
            std.process.exit(1);
        }
    }

    // If no arguments and stdin is a TTY, show help
    if (!saw_any_arg and try stdin_file.isTty(io)) {
        try stdout_file.writeStreamingAll(io, help_message);
        return;
    }

    const filter = zq.parseFilter(
        gpa,
        filter_str,
    ) catch {
        stderr_file.writeStreamingAll(io, "zq: invalid filter\n") catch {};
        std.process.exit(1);
    };
    defer if (filter == .path) gpa.free(filter.path);

    // Read all input from stdin (100MB limit) as a sentinel-terminated slice
    // for the AST parser.
    const max_input_size = 100 * 1024 * 1024;
    var read_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin_file.reader(io, &read_buffer);
    const source = try stdin_reader.interface.allocRemainingAlignedSentinel(
        gpa,
        .limited(max_input_size),
        .of(u8),
        0,
    );
    defer gpa.free(source);

    // Setup stdout with buffer
    var buffer: [4096]u8 = undefined;
    var stdout = stdout_file.writer(io, &buffer);

    // Check if stdout is a TTY to decide on colors
    // -C forces colors on, -M forces colors off (monochrome takes precedence)
    const use_colors = !monochrome and (force_color or try stdout_file.isTty(io));

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
        gpa,
    )) |parse_error| {
        parse_error.write(io, stderr_file);
        std.process.exit(1);
    }

    stdout.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return,
    };
}
