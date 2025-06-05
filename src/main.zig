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
    // var prng = std.Random.DefaultPrng.init(@intCast(0));
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

    var running: u8 = 3; // magic number, multiple "key presses" are always sent, so we count down from 3

    var streams: []Stream = try allocator.alloc(Stream, vx.window().width * vx.window().height);

    for (0..(streams.len / 2 - 1)) |current_stream| {
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

            window.writeCell(current_stream.column, current_stream.current_row - current_stream.length, .{
                .char = .{
                    .grapheme = " ",
                },
            });

            current_stream.last_character = random_number;
            current_stream.current_row += 1;
        }

        try vx.render(tty_bw.writer().any());
        try tty_bw.flush();

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

        for (0..(streams.len - 1)) |current_stream| {
            if (streams[current_stream].current_row >= (window.height + streams[current_stream].length + 2)) {
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
