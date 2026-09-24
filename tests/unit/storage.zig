//! Row-storage unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");
const Bump = postgres.conn_mod.Bump;
const parseResultOids = postgres.conn_mod.parseResultOids;
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

/// Builds a RowDescription payload with the exact wire length the server
/// would send for these column OIDs/names.
fn rowDescription(comptime cols: []const u32) []const u8 {
    return struct {
        const built = build(cols);
        fn build(comptime cs: []const u32) []const u8 {
            var len: usize = 2;
            for (cs, 0..) |_, k| {
                const name = switch (k) {
                    0 => "a",
                    1 => "bb",
                    else => "ccc",
                };
                len += name.len + 1 + 18;
            }
            var buf: [len]u8 = undefined;
            std.mem.writeInt(u16, buf[0..2], @intCast(cols.len), .big);
            var i: usize = 2;
            for (cs, 0..) |o, k| {
                const name = switch (k) {
                    0 => "a",
                    1 => "bb",
                    else => "ccc",
                };
                @memcpy(buf[i..][0..name.len], name);
                i += name.len;
                buf[i] = 0;
                i += 1;
                std.mem.writeInt(u32, buf[i..][0..4], 16384, .big); // table oid
                std.mem.writeInt(i16, buf[i + 4 ..][0..2], @intCast(k + 1), .big); // attnum
                std.mem.writeInt(u32, buf[i + 6 ..][0..4], o, .big); // type oid
                std.mem.writeInt(i16, buf[i + 10 ..][0..2], -1, .big); // typlen
                std.mem.writeInt(i32, buf[i + 12 ..][0..4], -1, .big); // typmod
                std.mem.writeInt(u16, buf[i + 16 ..][0..2], 0, .big); // format
                i += 18;
            }
            const fin: [len]u8 = buf;
            return &fin;
        }
    }.built;
}

test "parseResultOids reads every column OID" {
    var out: [8]u32 = undefined;
    const msg = rowDescription(&.{ 20, 23, 16, 2950, 1184, 25 })[0..];
    const n = parseResultOids(msg, &out);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u32, &.{ 20, 23, 16, 2950, 1184, 25 }, out[0..n]);

    // malformed / too wide must not report partial data
    try std.testing.expectEqual(@as(usize, 0), parseResultOids(&.{0}, &out));
    try std.testing.expectEqual(@as(usize, 0), parseResultOids(msg[0 .. msg.len - 3], &out));
    try std.testing.expectEqual(@as(usize, 0), parseResultOids(msg, out[0..3]));
    const empty = rowDescription(&.{});
    try std.testing.expectEqual(@as(usize, 0), parseResultOids(empty[0..], &out));
}
