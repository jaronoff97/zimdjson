const std = @import("std");
const zimdjson = @import("zimdjson");
const builtin = @import("builtin");

const allocator = std.testing.allocator;

test "streaming parser concurrent instances" {
    // This is the real-world scenario that was failing: multiple streaming parsers
    // running concurrently would exhaust file descriptors on macOS.
    // Before the fix, on macOS each StreamParser would hold an fd open for its
    // ring buffer until deinit(), causing EMFILE (errno 24) with many parsers.
    const Parser = zimdjson.ondemand.StreamParser(.default);

    const json = "[1, 2, 3]";
    const num_parsers = 50;

    var parsers: [num_parsers]Parser = undefined;
    var initialized: usize = 0;

    // Initialize all parsers
    for (&parsers) |*parser| {
        parser.* = Parser.init;
        initialized += 1;
    }

    // Parse with each parser
    for (&parsers) |*parser| {
        var reader = std.Io.Reader.fixed(json);
        const doc = try parser.parseFromReader(allocator, &reader);

        var sum: i64 = 0;
        var arr = (try doc.asArray()).iterator();
        while (try arr.next()) |el| {
            sum += try el.asSigned();
        }
        try std.testing.expectEqual(@as(i64, 6), sum);
    }

    // Cleanup
    for (parsers[0..initialized]) |*parser| {
        parser.deinit(allocator);
    }
}

test "streaming parser create and destroy cycle" {
    // Test that we can create and destroy streaming parsers repeatedly without leaking fds.
    // Before the fix, this would eventually fail on macOS due to fd exhaustion.
    const Parser = zimdjson.ondemand.StreamParser(.default);

    const json = "[1, 2, 3]";

    for (0..200) |_| {
        var parser = Parser.init;
        defer parser.deinit(allocator);

        var reader = std.Io.Reader.fixed(json);
        const doc = try parser.parseFromReader(allocator, &reader);

        var sum: i64 = 0;
        var arr = (try doc.asArray()).iterator();
        while (try arr.next()) |el| {
            sum += try el.asSigned();
        }
        try std.testing.expectEqual(@as(i64, 6), sum);
    }
}

test "streaming dom parser concurrent instances" {
    // Also test the DOM streaming parser variant
    const Parser = zimdjson.dom.StreamParser(.default);

    const json = "[1, 2, 3]";
    const num_parsers = 50;

    var parsers: [num_parsers]Parser = undefined;
    var initialized: usize = 0;

    // Initialize all parsers
    for (&parsers) |*parser| {
        parser.* = Parser.init;
        initialized += 1;
    }

    // Parse with each parser
    for (&parsers) |*parser| {
        var reader = std.Io.Reader.fixed(json);
        const doc = try parser.parseFromReader(allocator, &reader);

        var sum: i64 = 0;
        const arr = try doc.asArray();
        var it = arr.iterator();
        while (it.next()) |el| {
            sum += try el.asSigned();
        }
        try std.testing.expectEqual(@as(i64, 6), sum);
    }

    // Cleanup
    for (parsers[0..initialized]) |*parser| {
        parser.deinit(allocator);
    }
}

test "fd not leaked after streaming parse on macOS" {
    // On macOS, verify that file descriptors are not held open after parsing.
    // We do this by checking that we can create many more parsers than the typical
    // fd limit would allow if fds were being held.
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const Parser = zimdjson.ondemand.StreamParser(.default);
    const json = "{}";

    // Create and immediately destroy many parsers with parsing
    // If fds were leaking, this would fail well before 500 iterations
    // on a system with default ulimit (usually 256)
    for (0..500) |_| {
        var parser = Parser.init;
        var reader = std.Io.Reader.fixed(json);
        _ = try parser.parseFromReader(allocator, &reader);
        parser.deinit(allocator);
    }
}

test "high concurrency streaming parsers" {
    // Stress test with many concurrent parsers to verify fd management
    const Parser = zimdjson.ondemand.StreamParser(.default);

    const json =
        \\{"name": "test", "value": 42, "nested": {"a": 1, "b": 2}}
    ;
    const num_parsers = 100;

    var parsers: [num_parsers]Parser = undefined;

    // Initialize all parsers
    for (&parsers) |*parser| {
        parser.* = Parser.init;
    }

    // Parse with each parser and verify results
    for (&parsers) |*parser| {
        var reader = std.Io.Reader.fixed(json);
        const doc = try parser.parseFromReader(allocator, &reader);

        const name = try doc.at("name").asString();
        try std.testing.expectEqualStrings("test", name);

        const value = try doc.at("value").asUnsigned();
        try std.testing.expectEqual(@as(u64, 42), value);
    }

    // Cleanup all parsers
    for (&parsers) |*parser| {
        parser.deinit(allocator);
    }
}
