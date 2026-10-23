//! The indexer must not write past the token buffer. It writes token indexes
//! in groups of 4, so it writes up to 3 entries past the last token. A
//! reused parser can hold a buffer whose capacity equals the request
//! exactly, so the request itself must include that slack.
const std = @import("std");
const zimdjson = @import("zimdjson");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Puts a canary after each allocation and records a changed canary at
/// free. It never resizes in place, so each buffer gets a fresh canary.
const CanaryAllocator = struct {
    child: Allocator,
    corrupted: bool = false,

    const canary_len = 64;
    const canary_byte = 0xAA;

    fn allocator(self: *CanaryAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CanaryAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len + canary_len, alignment, ret_addr) orelse return null;
        @memset(ptr[len..][0..canary_len], canary_byte);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CanaryAllocator = @ptrCast(@alignCast(ctx));
        for (memory.ptr[memory.len..][0..canary_len]) |byte| {
            if (byte != canary_byte) self.corrupted = true;
        }
        self.child.rawFree(memory.ptr[0 .. memory.len + canary_len], alignment, ret_addr);
    }
};

/// Primes a parser with a small document, then parses `[[[...` documents
/// with lengths near the primed capacity, so that the capacity can equal
/// the request exactly. In `[[[...` every byte is a token.
fn expectNoOverrun(comptime Parser: type) !void {
    var json: [1024]u8 = undefined;
    @memset(&json, '[');
    var primer: [256]u8 = undefined;
    @memset(&primer, ' ');
    primer[0] = '0';

    for (1..primer.len) |primed_len| {
        // Probe the capacity that this primer leaves behind.
        const capacity = brk: {
            var parser: Parser = .init;
            defer parser.deinit(std.testing.allocator);
            _ = try parser.parseFromSlice(std.testing.allocator, primer[0..primed_len]);
            break :brk parser.cursor.tokens.indexes.capacity;
        };

        for (capacity -| 8..capacity + 1) |len| {
            var canary: CanaryAllocator = .{ .child = std.testing.allocator };
            const gpa = canary.allocator();
            {
                var parser: Parser = .init;
                defer parser.deinit(gpa);
                _ = try parser.parseFromSlice(gpa, primer[0..primed_len]);
                // The document is invalid JSON. Only the indexer writes matter.
                _ = parser.parseFromSlice(gpa, json[0..len]) catch {};
            }
            if (canary.corrupted) {
                std.debug.print("overrun: primed_len={} capacity={} len={}\n", .{ primed_len, capacity, len });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "ondemand: indexer stays inside the token buffer" {
    try expectNoOverrun(zimdjson.ondemand.FullParser(.default));
}
