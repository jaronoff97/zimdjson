const std = @import("std");
const zimdjson = @import("zimdjson");
const tracy = @import("tracy");
const Parser = zimdjson.ondemand.FullParser(.default);

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());

    if (args.len == 1) return;

    var tracy_alloc = tracy.tracyAllocator(std.heap.c_allocator);
    const allocator = tracy_alloc.allocator();

    const path = args[1];

    var parser = Parser.init;
    defer parser.deinit(allocator);

    // const rand = std.crypto.random;
    while (true) {
        var tracer = tracy.traceNamed(@src(), "parser");
        defer tracer.end();
        const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
        defer file.close(init.io);
        // const index = rand.uintLessThan(u8, 100);
        var read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(init.io, &read_buf);
        _ = try parser.parseFromReader(allocator, &file_reader.interface);
        // const created_at = try document.at(index).at("reportedOn").getString();
        // tracy.messageCopy(created_at);
    }
}
