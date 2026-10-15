const std = @import("std");
const zimdjson = @import("zimdjson");
const tracy = @import("tracy");
const dom = zimdjson.dom;
const ondemand = zimdjson.ondemand;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const path = args[1];

    var parser = dom.FullParser(.default).init;
    defer parser.deinit(allocator);

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(init.io, &read_buf);
    _ = try parser.parseFromReader(allocator, &file_reader.interface);
}
