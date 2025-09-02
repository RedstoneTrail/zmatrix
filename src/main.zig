const std = @import("std");
const vaxis = @import("vaxis");
const clap = @import("clap");

const inactive_colour = .{ 0xff, 0xff, 0xff };
const active_colour = .{ 0x00, 0xff, 0x00 };

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

const Stream = struct {
    column: u16,
    current_row: u16,
    length: u16,
    finished: bool,
    last_character: u8,
};

// only want characters from hex 21 to 7e (dec 33 to 126) as they are ascii and continuous in number
const characters = blk: {
    @setEvalBranchQuota(100000);

    var ascii_chars: [93][1]u8 = undefined;

    for (0..93) |i| {
        ascii_chars[i][0] = i + 33;
    }

    break :blk ascii_chars;
};

const help_message =
    \\-i, --indefinite        Run forever (must be stopped via a signal)
    \\-m, --message     <str> Display a message onscreen at all times
    \\-d, --delay     <usize> The delay between updates in milliseconds (does not account for stdout speed)
    \\
    \\-h, --help              Print this help, then exit.
;

pub fn initialseStream() Stream {
    const stream: Stream = .{
        .column = 0,
        .length = 3,
        .current_row = 0,
        .finished = true,
        .last_character = 0,
    };
    return stream;
}

pub fn randomStream(window: vaxis.Window) Stream {
    const stream: Stream = .{
        // .length = random.intRangeLessThan(u16, 3, (window.height - 1) * 2 / 3),
        // .column = random.intRangeLessThan(u16, 0, window.width - 1),
        .length = (randomInt(u16) % ((window.height - 1) * 2 / 3 - 3)) + 3,
        .column = randomInt(u16) % (window.width - 1),
        .current_row = 0,
        .finished = false,
        .last_character = 0,
    };
    return stream;
}

// random number generation system inspired by the original doom engine
// this globally accessible list of numbers is assigned random values at the start of execution (as opposed to at compile time due to incremetal compilation)
// so only 1024 random calls are ever made to generate these values
// this benefit is only minor at first, but after a bit over 1024 random calls (very quick to reach) it becomes much more efficient
// little noticable difference in resulting visual effect due to how many random calls are made, it is unpredictable again
var random_values: [1024]usize = undefined;
var random_index: usize = undefined;

pub fn randomInt(T: type) T {
    const chosen_value: T = @truncate(random_values[random_index]);
    random_index += 1;
    if (random_index > (random_values.len - 1)) {
        random_index = 0;
    }
    return chosen_value;
}

pub fn main() !void {
    // wait half a second before starting to ensure that the window is the right size (in case a new one is opened for the program)
    std.Thread.sleep(std.time.ns_per_s / 2);

    const time: usize = @intCast(std.time.nanoTimestamp());
    var prng = std.Random.DefaultPrng.init(@intCast(time));
    const random_generator = prng.random();

    // generate random values for doom-style random table
    random_values = blk: {
        var set: @TypeOf(random_values) = undefined;

        for (0..(set.len - 1)) |i| {
            set[i] = random_generator.int(@TypeOf(set[i]));
        }

        break :blk set;
    };
    random_index = 0;

    // allocator
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // clap
    const parameters = comptime clap.parseParamsComptime(help_message);

    var diagnostic = clap.Diagnostic{};
    var result = clap.parse(clap.Help, &parameters, clap.parsers.default, .{
        .diagnostic = &diagnostic,
        .allocator = allocator,
    }) catch |err| {
        try diagnostic.report(std.io.getStdErr().writer(), err);
        return err;
    };
    defer result.deinit();

    if (result.args.help != 0) {
        std.debug.print("{s}\n", .{help_message});
    } else {
        const indefinite = result.args.indefinite != 0;

        const message = result.args.message;

        const delay = blk: {
            if (result.args.delay) |delay| {
                break :blk delay;
            } else {
                break :blk 100;
            }
        };

        // vaxis
        var tty = try vaxis.Tty.init();
        defer tty.deinit();

        var vx = try vaxis.init(allocator, .{});
        defer vx.deinit(allocator, tty.anyWriter());

        var event_loop: vaxis.Loop(Event) = .{
            .tty = &tty,
            .vaxis = &vx,
        };

        try event_loop.start();
        defer event_loop.stop();

        try vx.enterAltScreen(tty.anyWriter());

        try vx.queryTerminal(tty.anyWriter(), std.time.ns_per_s);

        {
            const event = event_loop.nextEvent();
            switch (event) {
                .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
                else => {},
            }
        }

        {
            var tty_bw = tty.bufferedWriter();
            try vx.render(tty_bw.writer().any());
            try tty_bw.flush();
        }

        var running: u8 = 3; // magic number, multiple "key presses" are always sent, so we count down from 3

        // var streams: []Stream = try allocator.alloc(Stream, vx.window().width * vx.window().height / 20);
        var streams: []Stream = try allocator.alloc(Stream, vx.window().width * (vx.window().height / 40 + 1));
        defer allocator.free(streams);

        for (0..(streams.len - 1)) |current_stream| {
            streams[current_stream] = initialseStream();
        }

        // main loop
        while (running >= 1) {
            const window = vx.window();
            var tty_bw = tty.bufferedWriter();

            for (0..(streams.len - 1)) |current_stream_number| {
                var random_number = randomInt(u7);
                random_number = random_number % 93;
                const current_stream = &streams[current_stream_number];

                _ = window.print(&.{
                    .{
                        .text = &characters[random_number],
                        .style = vaxis.Style{
                            .bold = true,
                            .fg = .{
                                .rgb = inactive_colour,
                            },
                        },
                    },
                }, .{
                    .row_offset = current_stream.current_row + 1,
                    .col_offset = current_stream.column,
                });

                _ = window.print(&.{
                    .{
                        .text = &characters[random_number],
                        .style = vaxis.Style{
                            .bold = false,
                            .fg = .{
                                .rgb = active_colour,
                            },
                        },
                    },
                }, .{
                    .row_offset = current_stream.current_row,
                    .col_offset = current_stream.column,
                });

                if (@as(i17, current_stream.current_row) - @as(i17, current_stream.length) >= -1) {
                    window.writeCell(current_stream.column, @as(u16, @max(0, @as(i17, current_stream.current_row) - @as(i17, current_stream.length))), .{
                        .char = .{
                            .grapheme = " ",
                        },
                    });
                }

                current_stream.last_character = random_number;
                current_stream.current_row += 1;
            }

            if (message) |msg| {
                for (0..3) |row_offset| {
                    const row = @min(@max(0, window.height / 2 - 1 + row_offset), std.math.pow(u16, 2, 15) - 1);
                    {
                        const column = @min(@max(0, (window.width - msg.len) / 2 - 1), std.math.pow(u16, 2, 15) - 1);
                        window.writeCell(column, row, .{
                            .char = .{
                                .grapheme = " ",
                            },
                        });
                    }
                    {
                        const column = @min(@max(0, (window.width + msg.len) / 2), std.math.pow(u16, 2, 15) - 1);
                        window.writeCell(column, row, .{
                            .char = .{
                                .grapheme = " ",
                            },
                        });
                    }
                }

                for (0..msg.len) |msg_index| {
                    const column = @min(@max(0, (window.width - msg.len) / 2 + msg_index), std.math.pow(u16, 2, 15) - 1);
                    if (column < window.width) {
                        window.writeCell(column, window.height / 2 - 1, .{
                            .char = .{
                                .grapheme = " ",
                            },
                        });
                        window.writeCell(column, window.height / 2 + 1, .{
                            .char = .{
                                .grapheme = " ",
                            },
                        });
                    }
                }
            }

            try vx.render(tty_bw.writer().any());
            try tty_bw.flush();

            {
                const event = event_loop.tryEvent();
                if (event != null) {
                    switch (event.?) {
                        .key_press => {
                            if (!indefinite) {
                                running -= 1;
                            }
                        },
                        .winsize => |ws| {
                            try vx.resize(allocator, tty.anyWriter(), ws);
                        },
                        else => {},
                    }
                }
            }

            for (0..(streams.len - 1)) |current_stream| {
                if (streams[current_stream].current_row > (window.height + streams[current_stream].length)) {
                    streams[current_stream] = randomStream(window);
                }
            }

            for (0..window.width / window.height * 4) |_| {
                for (0..(streams.len - 1)) |current_stream| {
                    if (streams[current_stream].finished) {
                        streams[current_stream] = randomStream(window);
                        break;
                    }
                }
            }

            std.Thread.sleep(std.time.ns_per_ms * delay);
        }
    }
}
