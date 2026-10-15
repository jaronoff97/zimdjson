const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();
const zimdjson = @import("zimdjson");
const TracedAllocator = @import("TracedAllocator");

var traced = TracedAllocator{ .wrapped = std.heap.c_allocator };
const allocator = traced.allocator();

var json: []u8 = undefined;
var size: usize = 0;
var parser = zimdjson.ondemand.FullParser(.{ .assume_padding = true }).init;

pub fn init(path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    size = (try file.stat(io)).size;
    json = try allocator.alloc(u8, size + zimdjson.padding);
    @memset(json[size..], ' ');
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    // Read all bytes (equivalent to old readAll)
    var total_read: usize = 0;
    while (total_read < size) {
        const bytes_read = try file_reader.interface.readSliceShort(json[total_read..size]);
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }
}

pub fn prerun() !void {}

pub fn run() !void {
    _ = try parser.parseFromSlice(allocator, json[0..size]);
}

pub fn postrun() !void {}

pub fn deinit() void {
    parser.deinit(allocator);
    allocator.free(json);
}

pub fn memusage() usize {
    return traced.total;
}
