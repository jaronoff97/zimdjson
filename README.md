# zimdjson

> JSON is everywhere on the Internet. Servers spend a _lot_ of time parsing it. We need a fresh approach.

Welcome to zimdjson: a high-performance JSON parser that takes advantage of SIMD vector instructions, based on the paper [Parsing Gigabytes of JSON per Second](https://arxiv.org/abs/1902.08318).

The majority of the source code is based on the C++ implementation https://github.com/simdjson/simdjson with the addition of some fundamental features like:

- Streaming support which can handle arbitrarily large documents with O(1) of memory usage.
- An ergonomic, [Serde](https://serde.rs)-like deserialization interface thanks to Zig's compile-time reflection. See [Reflection-based JSON](#reflection-based-json).
- More efficient memory usage.

## Getting started

Install the zimdjson library by running the following command in your project root:

```
zig fetch --save git+https://github.com/ezequielramis/zimdjson#0.1.1
```

Then write the following in your `build.zig`:

```zig
const zimdjson = b.dependency("zimdjson", .{});
exe.root_module.addImport("zimdjson", zimdjson.module("zimdjson"));
```

As an example, download a sample file called [`twitter.json`](https://github.com/simdjson/simdjson-data/blob/master/jsonexamples/twitter.json).

Then execute the following:

```zig
const std = @import("std");
const zimdjson = @import("zimdjson");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var parser = zimdjson.ondemand.StreamParser(.default).init;
    defer parser.deinit(allocator);

    const file = try std.Io.Dir.cwd().openFile(init.io, "twitter.json", .{});
    defer file.close(init.io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(init.io, &read_buf);
    const document = try parser.parseFromReader(allocator, &file_reader.interface);

    const metadata_count = try document.at("search_metadata").at("count").asUnsigned();
    std.debug.print("{} results.", .{metadata_count});
}
```

```
> zig build run

100 results.
```

To see how the streaming parser above handles multi-gigabyte JSON documents with minimal memory usage, download one of [these dumps](https://www.edsm.net/en/nightly-dumps) or play it with a file of your choice.

## Requirements

This fork requires Zig 0.17.0.
The runtime port reuses the Edge port of upstream commit `6199cafec64280fcd9fd1df70b52809fc5a70052`.
The fork retains its full build, benchmarks, tools, optional Tracy support, and external test data.

Zig 0.17.0's default x86_64 debug backend rejects the parser's SIMD instructions.
It reports `InvalidInstruction` for `vpclmulqdq` and `vpmaddubsw`.
Use LLVM for tests on x86_64:

```sh
zig build tests -Dllvm=true
zig build tests/check -Dtarget=x86_64-linux -Dllvm=true
```

The second command compiles all suites without execution.
The `test` and `test/check` steps select the standalone module tests.
The `tests` step also runs the external suites.
The schema suite skips the `std.SegmentedList` test because Zig 0.17 removed that container.

Use `-Dfile=...` instead of arguments after `--` for tools and benchmarks:

```sh
zig build tools/print -Dfile=small/demo.json
zig build bench/dom -Dfile=twitter.json --release=fast
zig build tools/print -Duse-cwd -Dfile=/absolute/path/to/document.json
zig build bench/schema/check
zig build tools/profile/check
zig fmt --check build.zig build.zig.zon src build bench tools tests
```

Each `bench/<suite>/check` step compiles that suite without execution.
The tool steps `tools/print/check`, `tools/profile/check`, and `tools/profile-cpp/check` also compile without execution.
The profile tools require the system `TracyClient` library.
The schema benchmark uses Cargo and the existing lock files.
The native debug index benchmark triggers a sanitizer failure in the external simdjson library's `__builtin_clzll(0)` call.
The same benchmark completes with `--release=fast`.

The Nix shell still selects Zig 0.14.0 and does not support this port.
Its locked overlay lacks Zig 0.17.0.
Overlay revision `290ee50a903c5a301ebc71b7c94491f0db7d6917` lists Zig 0.17.0.
Update and verify the Nix inputs and lock file on a host with Nix.

Currently, targets with Linux, Windows, or macOS operating systems and CPUs with SIMD capabilities are supported. Missing targets can be added by contributing.

## Documentation

The most recent documentation can be found in https://zimdjson.ramis.ar.

## Reflection-based JSON

Although the provided interfaces are simple enough, it is expected to have unnecessary boilerplate when deserializing lots of data structures. Thank to Zig's compile-time reflection, we can eliminate it:

```zig
const std = @import("std");
const zimdjson = @import("zimdjson");

const Film = struct {
    name: []const u8,
    year: u32,
    characters: []const []const u8, // we could also use std.ArrayListUnmanaged([]const u8)
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var parser = zimdjson.ondemand.FullParser(.default).init;
    defer parser.deinit(allocator);

    const json =
        \\{
        \\  "name": "Esperando la carroza",
        \\  "year": 1985,
        \\  "characters": [
        \\    "Mamá Cora",
        \\    "Antonio",
        \\    "Sergio",
        \\    "Emilia",
        \\    "Jorge"
        \\  ]
        \\}
    ;

    const document = try parser.parseFromSlice(allocator, json);

    const film = try document.as(Film, allocator, .{});
    defer film.deinit();

    try std.testing.expectEqualDeep(
        Film{
            .name = "Esperando la carroza",
            .year = 1985,
            .characters = &.{
                "Mamá Cora",
                "Antonio",
                "Sergio",
                "Emilia",
                "Jorge",
            },
        },
        film.value,
    );
}
```

This is just a simple example, but this way of deserializing is as powerful as [Serde](https://serde.rs), so there is a lot of more features we can use, such as:

- Deserializing data structures from the Zig Standard Library.
- Renaming fields.
- Using different union representations.
- Custom handling unknown fields.

To see all available options it offers checkout its [reference](https://zimdjson.ramis.ar/#zimdjson.ondemand.Parser.schema).

To see all supported Zig Standard Library's data structures checkout [this list](https://zimdjson.ramis.ar/#zimdjson.ondemand.Parser.schema.std).

To see how it can be really used checkout the [test suite](https://github.com/ezequielramis/zimdjson/blob/main/tests/schema.zig) for more examples.

## Performance

> [!NOTE]
> As a rule of thumb, do not trust any benchmark — always verify it yourself. There may be biases that favor a particular candidate, including mine.

The following picture represents parsing speed in GB/s of similar tasks presented in the paper [On-Demand JSON: A Better Way to Parse
Documents?](https://arxiv.org/pdf/2312.17149), where the first three tasks iterate over `twitter.json` and the others iterate over a 626MB JSON file called `systemsPopulated.json` from [these dumps](https://www.edsm.net/en/nightly-dumps).

![](./docs/assets/bench_ondemand_find_tweet.png)

Ok, it seems the benchmark got borked but it is not, because of how cache works on small files and how the streaming parser happily ended finding out the tweet in the middle of the file.

Let's get rid of that task to see better the other results.

![](./docs/assets/bench_ondemand.png)

The following picture corresponds to a second simple benchmark, representing parsing speed in GB/s for near-complete parsing of the `twitter.json` file with reflection-based parsers (`serde_json`, `std.json`).

![](./docs/assets/bench_schema.png)

**Note**: If you look closely, you'll notice that "zimdjson (On-Demand, Unordered)" is the slowest of all. This is, unfortunately, a behaviour that also occurs with `simdjson` when object keys are unordered. If you do not know the order, it can be mitigated by using an schema. Thanks to the [glaze library author](https://github.com/stephenberry/glaze) for pointing this out.

All benchmarks were run on a 3.30GHz Intel Skylake processor.
