const std = @import("std");
const vaxis = @import("vaxis");
const clap = @import("clap");

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
    \\-i, --indefinite          Run forever (must be stopped via a signal)
    \\-m, --message     <str>   Display a message onscreen at all times
    \\
    \\-h, --help                Print this help, then exit.
;

pub fn main() !void {
    // prng
    var time = std.time.nanoTimestamp();
    if (time <= 0) {
        time = 0 - time;
    }
    var prng = std.Random.DefaultPrng.init(@intCast(time));
    // var prng = std.Random.DefaultPrng.init(@intCast(0));
    const random = prng.random();

    // allocator
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // const allocator = arena.allocator();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    // defer gpa.deinit();
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
        const indefinite = blk: {
            if (result.args.indefinite != 0) {
                break :blk true;
            } else {
                break :blk false;
            }
        };

        const message = result.args.message;

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

        var streams: []Stream = try allocator.alloc(Stream, vx.window().width * vx.window().height / 20);
        defer allocator.free(streams);

        for (0..(streams.len - 1)) |current_stream| {
            streams[current_stream] = .{
                .column = 0,
                .length = 3,
                .current_row = 0,
                .finished = true,
                .last_character = 0,
            };
        }

        // main loop
        while (running >= 1) {
            const window = vx.window();
            var tty_bw = tty.bufferedWriter();

            for (0..(streams.len - 1)) |current_stream_number| {
                const random_number = random.intRangeLessThan(u8, 0, 93);
                const current_stream = &streams[current_stream_number];

                _ = window.print(&.{
                    .{
                        .text = &characters[random_number],
                        .style = vaxis.Style{
                            .bold = true,
                            .fg = .{
                                .index = 7,
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
                                .index = 2,
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

                        // awful method, doesn't fully print otherwise (not sure why)
                        _ = window.print(&.{
                            .{
                                .text = @constCast(msg),
                                .style = vaxis.Style{
                                    .bold = true,
                                },
                            },
                        }, .{
                            .row_offset = window.height / 2,
                            .col_offset = @min(@max(0, (window.width - msg.len) / 2), std.math.pow(u16, 2, 15) - 1),
                        });
                    }
                }

                // {
                //     var active: u64 = 0;
                //     var inactive: u64 = 0;
                //     const total: u64 = streams.len;
                //     for (0..streams.len - 1) |current| {
                //         if (streams[current].finished) {
                //             inactive += 1;
                //         } else {
                //             active += 1;
                //         }
                //     }

                //     std.debug.print("active: {}, inactive: {}, total: {}\n", .{ active, inactive, total });
                // }
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
                            } else {
                                for (0..(streams.len - 1)) |current_stream| {
                                    streams[current_stream].finished = true;
                                }
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
                    // streams[current_stream].finished = true;
                    streams[current_stream] = .{
                        .length = random.intRangeLessThan(u16, 3, (window.height - 1) * 2 / 3),
                        .column = random.intRangeLessThan(u16, 0, window.width - 1),
                        .current_row = 0,
                        .finished = false,
                        .last_character = 0,
                    };
                    // break;
                }
            }

            for (0..window.width / window.height * 4) |_| {
                for (0..(streams.len - 1)) |current_stream| {
                    if (streams[current_stream].finished) {
                        streams[current_stream] = .{
                            .length = random.intRangeLessThan(u16, 3, (window.height - 1) * 2 / 3),
                            .column = random.intRangeLessThan(u16, 0, window.width - 1),
                            .current_row = 0,
                            .finished = false,
                            .last_character = 0,
                        };
                        streams[current_stream].finished = false;
                        break;
                    }
                }
            }

            std.Thread.sleep(std.time.ns_per_ms * 100);
        }
    }
}
