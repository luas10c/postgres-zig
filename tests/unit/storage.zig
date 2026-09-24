//! Row-storage unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");
const Bump = postgres.conn_mod.Bump;
const testing = std.testing;

test "Bump serves aligned slices, grows chunks and resets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var b = Bump{ .arena = arena_state.allocator() };
    const a = b.allocator();

    const first = try a.alloc(u8, 10);
    try std.testing.expectEqual(@as(usize, 10), first.len);
    @memset(first, 0xaa);

    const wide = try a.alloc(u64, 4);
    try std.testing.expectEqual(@as(usize, 4), wide.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(wide.ptr) % @alignOf(u64));
    for (wide, 0..) |*v, i| v.* = @intCast(i);

    // large enough to force a new chunk
    const big = try a.alloc(u8, Bump.max_chunk * 2);
    try std.testing.expectEqual(Bump.max_chunk * 2, big.len);
    big[0] = 1;
    big[big.len - 1] = 2;

    // earlier allocations are untouched by the growth
    try std.testing.expectEqual(@as(u8, 0xaa), first[0]);
    try std.testing.expectEqual(@as(u64, 3), wide[3]);

    // reset reuses the current chunk from the start
    const before = big.ptr;
    b.reset();
    const again = try a.alloc(u8, 64);
    try std.testing.expectEqual(before, again.ptr);

    try std.testing.expectEqual(@as(usize, 0), (try a.alloc(u8, 0)).len);
}
