//! Truncated documents must fail with an error, never read past the token
//! array. Each case stops on the first error, as a correct caller does.
const std = @import("std");
const zimdjson = @import("zimdjson");
const Parser = zimdjson.ondemand.FullParser(.default);

fn keys(doc: Parser.Document) !void {
    var it = (try doc.asObject()).iterator();
    while (try it.next()) |field| _ = try field.key.get();
}

fn elements(doc: Parser.Document) !void {
    var it = (try doc.asArray()).iterator();
    while (try it.next()) |_| {}
}

fn lookup(doc: Parser.Document) !void {
    _ = try doc.at("missing").asAny();
}

fn expectError(expected: anyerror, json: []const u8, run: fn (Parser.Document) anyerror!void) !void {
    const gpa = std.testing.allocator;
    var parser: Parser = .init;
    defer parser.deinit(gpa);
    const doc = try parser.parseFromSlice(gpa, json);
    try std.testing.expectError(expected, run(doc));
}

test "truncated object: skipping the missing value" {
    try expectError(error.IncompleteObject, "{\"a\":", keys);
    try expectError(error.IncompleteObject, "{\"a\":1,\"b\":", keys);
}

test "truncated array: skipping the missing element" {
    try expectError(error.IncompleteArray, "[", elements);
    try expectError(error.IncompleteArray, "[1,", elements);
}

test "truncated object: lookup of a missing key" {
    try expectError(error.IncompleteObject, "{\"a\":", lookup);
}
