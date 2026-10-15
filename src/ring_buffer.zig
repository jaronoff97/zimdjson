const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const native_os = builtin.os.tag;
const w = std.os.windows;

pub const default_chunk_length = 1024 * 64;
const min_chunk_length = if (native_os == .windows) 1024 * 64 else std.heap.page_size_min;

pub const Error =
    std.posix.MemFdCreateError ||
    error{ FileTooBig, InputOutput, AccessDenied, FileBusy } ||
    std.posix.MMapError ||
    error{ PathAlreadyExists, NameTooLong };

fn truncate(handle: posix.fd_t, length: usize) Error!void {
    while (true) {
        switch (posix.errno(std.c.ftruncate(handle, @intCast(length)))) {
            .SUCCESS => return,
            .INTR => continue,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .ACCES, .PERM => return error.AccessDenied,
            .TXTBSY => return error.FileBusy,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn RingBuffer(comptime T: type, comptime length: usize) type {
    const byte_len = @sizeOf(T) * length;
    assert(byte_len >= min_chunk_length and std.math.isPowerOfTwo(byte_len));
    assert(if (native_os == .macos) byte_len <= 1024 * 1024 * 4 else true);

    return struct {
        const Self = @This();
        pub const capacity = length;

        base: Buffer,

        const Buffer = struct {
            buffer: [*]align(std.heap.page_size_min) u8,
            handle: if (native_os == .windows) w.HANDLE else posix.fd_t,

            pub fn init() Error!Buffer {
                switch (native_os) {
                    .windows => {
                        if (!(builtin.os.isAtLeast(native_os, .win10) orelse false))
                            @compileError("Streaming capabilities are supported on Windows 10 and later");

                        // from https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualalloc2#examples
                        const MEM_RESERVE = 0x02000;
                        const MEM_RESERVE_PLACEHOLDER = 0x40000;
                        const MEM_REPLACE_PLACEHOLDER = 0x04000;

                        const buffer: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(VirtualAlloc2(
                            null,
                            null,
                            byte_len * 2,
                            MEM_RESERVE | MEM_RESERVE_PLACEHOLDER,
                            .{ .NOACCESS = true },
                            null,
                            0,
                        ) orelse switch (w.GetLastError()) {
                            else => |err| return w.unexpectedError(err),
                        }));

                        var free_buffer = true;
                        defer if (free_buffer) assert(VirtualFree(buffer, 0, .{ .RELEASE = true }).toBool());

                        assert(VirtualFree(buffer, byte_len, .{ .RELEASE = true, .PRESERVE_PLACEHOLDER = true }).toBool());

                        var free_mirror = true;
                        defer if (free_mirror) assert(VirtualFree(buffer + byte_len, 0, .{ .RELEASE = true }).toBool());

                        const handle = CreateFileMappingW(
                            w.INVALID_HANDLE_VALUE,
                            null,
                            .{ .READWRITE = true },
                            0,
                            byte_len,
                            null,
                        ) orelse switch (w.GetLastError()) {
                            else => |err| return w.unexpectedError(err),
                        };
                        errdefer w.CloseHandle(handle);

                        const mirror1 = MapViewOfFile3(
                            handle,
                            null,
                            buffer,
                            0,
                            byte_len,
                            MEM_REPLACE_PLACEHOLDER,
                            .{ .READWRITE = true },
                            null,
                            0,
                        ) orelse switch (w.GetLastError()) {
                            else => |err| return w.unexpectedError(err),
                        };
                        errdefer assert(UnmapViewOfFileEx(mirror1, 0).toBool());
                        free_buffer = false;

                        const mirror2 = MapViewOfFile3(
                            handle,
                            null,
                            buffer + byte_len,
                            0,
                            byte_len,
                            MEM_REPLACE_PLACEHOLDER,
                            .{ .READWRITE = true },
                            null,
                            0,
                        ) orelse switch (w.GetLastError()) {
                            else => |err| return w.unexpectedError(err),
                        };
                        errdefer assert(UnmapViewOfFileEx(mirror2, 0).toBool());
                        free_mirror = false;

                        return .{ .buffer = buffer, .handle = handle };
                    },
                    .macos => {
                        // taken from https://github.com/marler8997/zigx/blob/master/src/DoubleBuffer.zig

                        const pshmnamlen = 31;
                        const shm_prefix = "zimdrb_"; // 7
                        const base64_len = pshmnamlen - shm_prefix.len; // 24
                        const encoder: std.base64.Base64Encoder = comptime .init(std.base64.url_safe_alphabet_chars, '=');
                        var encoded_buffer: [pshmnamlen + 1]u8 = undefined;
                        @memcpy(encoded_buffer[0..shm_prefix.len], shm_prefix);
                        var rand_bytes: [18]u8 = undefined; // 18 is the required bytes for 24 base64 encoded bytes
                        std.c.arc4random_buf(&rand_bytes, rand_bytes.len);
                        const encoded = encoder.encode(encoded_buffer[shm_prefix.len..], &rand_bytes);
                        assert(encoded.len == base64_len);
                        encoded_buffer[pshmnamlen] = 0;
                        const name: [*:0]const u8 = @ptrCast(encoded_buffer[0 .. shm_prefix.len + encoded.len]);

                        const handle = std.c.shm_open(
                            name,
                            @bitCast(std.posix.O{
                                .ACCMODE = .RDWR,
                                .CREAT = true,
                                .EXCL = true,
                            }),
                            @as(c_uint, std.posix.S.IRUSR | std.posix.S.IWUSR),
                        );
                        if (handle == -1) switch (@as(std.posix.E, @fromBackingInt(@intCast(std.c._errno().*)))) {
                            .EXIST => return error.PathAlreadyExists,
                            .NAMETOOLONG => return error.NameTooLong,
                            else => |err| return std.posix.unexpectedErrno(err),
                        };
                        errdefer _ = std.c.close(handle);

                        try truncate(handle, byte_len);

                        const buffer = try posix.mmap(
                            null,
                            byte_len * 2,
                            .{ .READ = true, .WRITE = true },
                            .{
                                .TYPE = .PRIVATE,
                                .ANONYMOUS = true,
                            },
                            -1,
                            0,
                        );
                        errdefer posix.munmap(buffer);

                        _ = try posix.mmap(
                            @alignCast(buffer.ptr),
                            byte_len,
                            .{ .READ = true, .WRITE = true },
                            .{
                                .TYPE = .SHARED,
                                .FIXED = true,
                            },
                            handle,
                            0,
                        );

                        _ = try posix.mmap(
                            @alignCast(buffer.ptr + byte_len),
                            byte_len,
                            .{ .READ = true, .WRITE = true },
                            .{
                                .TYPE = .SHARED,
                                .FIXED = true,
                            },
                            handle,
                            0,
                        );

                        // Unlink the shared memory object immediately - the memory mappings
                        // keep the underlying object alive, but this removes the name from
                        // the filesystem and allows the fd to be closed.
                        _ = std.c.shm_unlink(name);

                        // Close the fd now - it's no longer needed after mmap completes.
                        // This prevents fd exhaustion in high-concurrency scenarios.
                        _ = std.c.close(handle);

                        return .{ .buffer = buffer.ptr, .handle = -1 };
                    },
                    else => {
                        const handle = try posix.memfd_create("zimdjson_ringbuffer", posix.MFD.CLOEXEC);
                        errdefer _ = std.c.close(handle);
                        try truncate(handle, byte_len);

                        const buffer = try posix.mmap(
                            null,
                            byte_len * 2,
                            .{ .READ = true, .WRITE = true },
                            .{
                                .TYPE = .PRIVATE,
                                .ANONYMOUS = true,
                            },
                            -1,
                            0,
                        );
                        errdefer posix.munmap(buffer);

                        _ = try posix.mmap(
                            @alignCast(buffer.ptr),
                            byte_len,
                            .{ .READ = true, .WRITE = true },
                            .{
                                .TYPE = .SHARED,
                                .FIXED = true,
                            },
                            handle,
                            0,
                        );

                        _ = try posix.mmap(
                            @alignCast(buffer.ptr + byte_len),
                            byte_len,
                            .{ .READ = true, .WRITE = true },
                            .{
                                .TYPE = .SHARED,
                                .FIXED = true,
                            },
                            handle,
                            0,
                        );

                        return .{ .buffer = buffer.ptr, .handle = handle };
                    },
                }
            }
            pub fn deinit(self: Buffer) void {
                switch (native_os) {
                    .windows => {
                        assert(UnmapViewOfFile(self.buffer).toBool());
                        assert(UnmapViewOfFile(self.buffer + byte_len).toBool());
                        w.CloseHandle(self.handle);
                    },
                    .macos => {
                        // On macOS, we close the fd immediately after mmap, so just unmap.
                        posix.munmap(self.buffer[0 .. byte_len * 2]);
                    },
                    else => {
                        posix.munmap(self.buffer[0 .. byte_len * 2]);
                        _ = std.c.close(self.handle);
                    },
                }
            }
        };

        pub fn init() Error!Self {
            return .{
                .base = try .init(),
            };
        }

        pub fn deinit(self: Self) void {
            self.base.deinit();
        }

        pub inline fn ptr(self: Self) [*]T {
            return @ptrCast(self.base.buffer);
        }

        pub inline fn mask(_: Self, n: usize) usize {
            return n & (length - 1);
        }
    };
}

extern "api-ms-win-core-memory-l1-1-6" fn VirtualAlloc2(Process: ?w.HANDLE, BaseAddress: ?w.PVOID, Size: w.SIZE_T, AllocationType: w.ULONG, PageProtection: w.PAGE, ExtendedParameters: ?*anyopaque, ParameterCount: w.ULONG) callconv(.winapi) ?w.PVOID;
extern "api-ms-win-core-memory-l1-1-6" fn CreateFileMappingW(hFile: w.HANDLE, lpFileMappingAttributes: ?*anyopaque, flProtect: w.PAGE, dwMaximumSizeHigh: w.DWORD, dwMaximumSizeLow: w.DWORD, lpName: ?w.LPCWSTR) callconv(.winapi) ?w.HANDLE;
extern "api-ms-win-core-memory-l1-1-6" fn MapViewOfFile3(FileMapping: w.HANDLE, Process: ?w.HANDLE, BaseAddress: w.PVOID, Offset: w.ULONG64, ViewSize: w.SIZE_T, AllocationType: w.ULONG, PageProtection: w.PAGE, ExtendedParameters: ?*anyopaque, ParameterCount: w.ULONG) callconv(.winapi) ?w.PVOID;
extern "api-ms-win-core-memory-l1-1-6" fn UnmapViewOfFileEx(BaseAddress: w.PVOID, UnmapFlags: w.ULONG) callconv(.winapi) w.BOOL;
extern "api-ms-win-core-memory-l1-1-6" fn UnmapViewOfFile(lpBaseAddress: w.LPCVOID) callconv(.winapi) w.BOOL;
extern "kernel32" fn VirtualFree(lpAddress: w.PVOID, dwSize: w.SIZE_T, dwFreeType: w.MEM.FREE) callconv(.winapi) w.BOOL;
