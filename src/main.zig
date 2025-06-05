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
    last_character: u8,
};

const characters = blk: {
    @setEvalBranchQuota(100000);

    var ascii_chars: [93][1]u8 = undefined;

    for (0..93) |i| {
        ascii_chars[i][0] = i + 33;
    }

    break :blk ascii_chars;
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
    var tty = vaxis.Tty.init() catch std.debug.panic("could not init tty", .{});
    defer tty.deinit();

    var vx = vaxis.init(allocator, .{}) catch std.debug.panic("could not init vaxis", .{});
    defer vx.deinit(allocator, tty.anyWriter());

    var event_loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };

    event_loop.start() catch std.debug.panic("could not start event loop", .{});
    defer event_loop.stop();

    vx.enterAltScreen(tty.anyWriter()) catch std.debug.panic("could not enter alt screen", .{});

    vx.queryTerminal(tty.anyWriter(), std.time.ns_per_s) catch std.debug.panic("could not query terminal", .{});

    {
        const event = event_loop.nextEvent();
        switch (event) {
            .winsize => |ws| vx.resize(allocator, tty.anyWriter(), ws) catch std.debug.panic("could not do initial resize", .{}),
            else => {},
        }
    }

    {
        var tty_bw = tty.bufferedWriter();
        vx.render(tty_bw.writer().any()) catch std.debug.panic("could not render screen", .{});
        tty_bw.flush() catch std.debug.panic("could not flush screen", .{});
    }

    var running: u8 = 3; // magic number, multiple "key presses" are always sent, so we count down from 3

    var streams: []Stream = allocator.alloc(Stream, vx.window().width * vx.window().height / 2) catch std.debug.panic("oom on initial streams alloc", .{});

    for (0..(streams.len / 2 - 1)) |current_stream| {
        streams[current_stream] = .{
            .column = 0,
            .length = 3,
            .current_row = 0,
            .finished = true,
            .last_character = 0,
        };
    }
    // for (0..(streams.len / 2 - 1)) |current_stream| {
    //     streams[current_stream] = .{
    //         .column = random.intRangeLessThan(u16, 0, vx.window().width - 1),
    //         .length = random.intRangeLessThan(u16, 0, vx.window().height - 1),
    //         .current_row = random.intRangeLessThan(u16, 0, vx.window().height - 1),
    //         .finished = false,
    //         .last_character = 0,
    //     };
    // }

    // main loop
    while (running >= 1) {
        const window = vx.window();
        var tty_bw = tty.bufferedWriter();

        for (0..(streams.len - 1)) |current_stream| {
            const random_number = random.intRangeLessThan(u8, 0, 93);

            _ = window.print(&.{
                .{
                    .text = &characters[random_number],
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

            streams[current_stream].last_character = random_number;
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
            if (streams[current_stream].current_row == (window.height + streams[current_stream].length + 2)) {
                streams[current_stream].finished = true;
                break;
            }
        }

        for (0..4) |_| {
            for (0..(streams.len - 1)) |current_stream| {
                if (streams[current_stream].finished) {
                    streams[current_stream] = .{
                        .length = random.intRangeLessThan(u16, 3, (window.height - 1) * 2 / 3),
                        .column = random.intRangeLessThan(u16, 0, window.width - 1),
                        // .current_row = random.intRangeLessThan(u16, 0, (window.height - 1) / 3),
                        .current_row = 0,
                        .finished = false,
                        .last_character = 0,
                    };
                    break;
                }
            }
        }

        std.time.sleep(std.time.ns_per_ms * 100);
    }
}
