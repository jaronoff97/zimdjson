const std = @import("std");
const zimdjson = @import("zimdjson");
const Parser = zimdjson.ondemand.StreamParser(.default);

var gpa = std.heap.DebugAllocator(.{}).init;
const allocator = gpa.allocator();

var w: *std.Io.Writer = undefined;

var depth: usize = 0;

fn printDepth() !void {
    try w.writeByte('\n');
    for (0..depth) |_| try w.writeAll("  ");
}

fn walk(v: Parser.Value) !void {
    const any = try v.asAny();
    switch (any) {
        .object => |c| {
            try w.writeByte('{');
            depth += 1;
            var size: usize = 0;
            var it = c.iterator();
            while (try it.next()) |field| : (size += 1) {
                try printDepth();
                try w.print("{s}: ", .{try field.key.getTemporal()});
                try walk(field.value);
            }
            depth -= 1;
            if (size != 0) try printDepth();
            try w.writeByte('}');
        },
        .array => |c| {
            try w.writeByte('[');
            depth += 1;
            var size: usize = 0;
            var it = c.iterator();
            while (try it.next()) |value| : (size += 1) {
                try printDepth();
                try walk(value);
            }
            depth -= 1;
            if (size != 0) try printDepth();
            try w.writeByte(']');
        },
        .string => |value| try w.print("\"{s}\"", .{try value.getTemporal()}),
        .number => |value| switch (value) {
            inline else => |n| try w.print("{}", .{n}),
        },
        .bool => |value| try w.print("{}", .{value}),
        .null => try w.print("null", .{}),
    }
}

pub fn main(init: std.process.Init) !void {
    defer _ = gpa.deinit();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1) return;

    var write_buf: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &write_buf);
    w = &output.interface;
    var parser = Parser.init;
    defer parser.deinit(allocator);

    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(init.io, &read_buf);
    const json = try parser.parseFromReader(allocator, &file_reader.interface);
    try walk(json.asValue());
    try w.flush();
}
