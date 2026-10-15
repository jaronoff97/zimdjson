//! Welcome to zimdjson: a high-performance JSON parser that takes advantage of
//! SIMD vector instructions, based on the paper
//! [Parsing Gigabytes JSON per Second](https://arxiv.org/abs/1902.08318).
//!
//! The majority of the source code is based on the C++ implementation
//! https://github.com/simdjson/simdjson with the addition of some fundamental features
//! like:
//! * Streaming support which can handle arbitrarily large documents with O(1) of memory usage.
//! * An ergonomic, [Serde](https://serde.rs)-like deserialization interface thanks to
//! Zig's compile-time reflection.
//! See [`ondemand.Parser.schema`](#zimdjson.ondemand.Parser.schema).
//! * More efficient memory usage.
//!
//! To get started, choose one of the following parsing approaches:
//! * `dom`: A simple and "user friendly" API in which an intermediate tree-like
//! structure is constructed for the whole document and can be traversed.
//! * `ondemand`: At the cost of incomplete validation, this API allows you to do
//! just-in-time parsing, without the need to store an entire document structure in
//! memory.
//!
//! For daily use, the `ondemand` approach is recommended, as it is more efficient and
//! has an API similar to `dom`.
//!
//! For more infomation, including code examples and benchmarks, check out
//! https://github.com/ezequielramis/zimdjson.

const std = @import("std");
const types = @import("types.zig");

pub const dom = @import("dom.zig");
pub const ondemand = @import("ondemand.zig");

pub const Number = @import("types.zig").Number;

/// Depending on the processor, aligned SIMD vector instructions may provide higher
/// performance (benchmarking is recommended). To enforce the use of these instructions,
/// the input must be properly aligned.
pub const alignment = types.Aligned(true).alignment;

/// The input does not need to be padded to be parsed, as it is handled automatically.
/// However, if you assume it has a sufficient padding, it must be at least this size.
pub const padding = std.simd.suggestVectorLength(u8) orelse @compileError("No SIMD features available");

test {
    std.testing.refAllDecls(@This());
}

test "reader parsers" {
    inline for (.{ dom.FullParser(.default), dom.StreamParser(.default), ondemand.FullParser(.default), ondemand.StreamParser(.default) }) |Parser| {
        var parser = Parser.init;
        defer parser.deinit(std.testing.allocator);
        var reader = std.Io.Reader.fixed("{\"value\":42}");
        const document = try parser.parseFromReader(std.testing.allocator, &reader);
        try std.testing.expectEqual(42, try document.at("value").asUnsigned());
    }
}

test "on-demand schema" {
    const Record = struct { value: u64, name: []const u8, enabled: bool = true };
    var parser = ondemand.FullParser(.default).init;
    defer parser.deinit(std.testing.allocator);
    const document = try parser.parseFromSlice(std.testing.allocator, "{\"value\":42,\"name\":\"Edge\"}");
    const record = try document.asLeaky(Record, std.testing.allocator, .{});
    try std.testing.expectEqual(42, record.value);
    try std.testing.expectEqualStrings("Edge", record.name);
    try std.testing.expect(record.enabled);
}

test "on-demand enum and union schemas" {
    const State = enum { ready, stopped };
    const Payload = union(enum) { value: u64, name: []const u8 };
    var parser = ondemand.FullParser(.default).init;
    defer parser.deinit(std.testing.allocator);
    const state_document = try parser.parseFromSlice(std.testing.allocator, "\"ready\"");
    try std.testing.expectEqual(State.ready, try state_document.asLeaky(State, null, .{}));
    const payload_document = try parser.parseFromSlice(std.testing.allocator, "{\"value\":42}");
    const payload = try payload_document.asLeaky(Payload, null, .{});
    try std.testing.expectEqual(42, payload.value);
}
