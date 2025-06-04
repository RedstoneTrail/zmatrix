const std = @import("std");
const vaxis = @import("vaxis");

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
    last_character: []u8,
};

// // only want characters from hex 21 to 7e (dec 33 to 126) as they are ascii and continuous in number

// std.debug.print("character: {c}\n", .{});

pub fn main() !void {
    // prng
    var time = std.time.nanoTimestamp();
    if (time <= 0) {
        time = 0 - time;
    }
    var prng = std.Random.DefaultPrng.init(@intCast(time));
    const random = prng.random();

    // allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

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

    var running: u8 = 3;

    var streams: [100]Stream = undefined;

    for (0..(streams.len - 1)) |current_stream| {
        streams[current_stream] = .{
            .column = random.intRangeLessThan(u16, 0, vx.window().width - 1),
            .length = random.intRangeLessThan(u16, 0, vx.window().height - 1),
            .current_row = random.intRangeLessThan(u16, 0, vx.window().height - 1),
            .finished = false,
            .last_character = @constCast(" "),
        };
    }

    // main loop
    while (running >= 1) {
        const window = vx.window();
        var tty_bw = tty.bufferedWriter();

        for (0..(streams.len - 1)) |current_stream| {
            var current_character: [1]u8 = undefined;
            current_character[0] = random.intRangeLessThan(u8, 33, 126);

            _ = window.print(&.{
                .{
                    .text = try allocator.dupe(u8, &current_character),
                    .style = vaxis.Style{
                        .bold = true,
                        .fg = .{
                            // .rgb = .{ 0xAA, 0xAA, 0xAA },
                            .index = 7,
                        },
                    },
                },
            }, .{
                .row_offset = streams[current_stream].current_row + 1,
                .col_offset = streams[current_stream].column,
            });

            // const green_coefficient = random.intRangeLessThan(u8, 1, 5);

            _ = window.print(&.{
                .{
                    .text = try allocator.dupe(u8, streams[current_stream].last_character),
                    .style = vaxis.Style{
                        .bold = false,
                        .fg = .{
                            // .rgb = .{
                            //     0x00,
                            //     0xAA / green_coefficient,
                            //     0x00,
                            // },
                            .index = 2,
                        },
                    },
                },
            }, .{
                .row_offset = streams[current_stream].current_row,
                .col_offset = streams[current_stream].column,
            });

            const length: i64 = streams[current_stream].length;
            const current_row: i64 = streams[current_stream].current_row;
            const clearing_position: i64 = current_row - length;
            const clearing_position_absoluted: i64 = @max(clearing_position, 0);
            const clearing_position_casted: u63 = @intCast(clearing_position_absoluted);
            const clearing_position_truncated: u16 = @truncate(clearing_position_casted);

            window.writeCell(streams[current_stream].column, clearing_position_truncated, .{
                .char = .{
                    .grapheme = " ",
                },
            });

            streams[current_stream].last_character = &current_character;
            streams[current_stream].current_row += 1;
        }

        {
            const event = event_loop.tryEvent();
            if (event != null) {
                switch (event.?) {
                    .key_press => running -= 1,
                    .winsize => |ws| {
                        try vx.resize(allocator, tty.anyWriter(), ws);
                    },
                    else => {},
                }
            }
        }

        try vx.render(tty_bw.writer().any());
        try tty_bw.flush();

        for (0..(streams.len - 1)) |current_stream| {
            if (streams[current_stream].current_row == (window.height + 1)) {
                streams[current_stream].finished = true;
            }

            if (streams[current_stream].finished) {
                streams[current_stream] = .{
                    .length = random.intRangeLessThan(u16, 0, (window.height - 1) * 2 / 3),
                    .column = random.intRangeLessThan(u16, 0, window.width - 1),
                    .current_row = 0,
                    .finished = false,
                    .last_character = @constCast(" "),
                };
            }
        }

        std.time.sleep(std.time.ns_per_ms * 100);
    }
}
