//! Codec/civil-date unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");
const types = postgres.types;
const testing = std.testing;
const coerce = types.coerce;
const parseArrayLiteral = types.parseArrayLiteral;
const decodeTimestampText = types.decodeTimestampText;
const daysFromCivil = types.daysFromCivil;
const civilFromDays = types.civilFromDays;
const days_from_1970_to_2000 = types.days_from_1970_to_2000;
const oid = types.oid;

test "civil roundtrip" {
    try std.testing.expectEqual(@as(i32, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(days_from_1970_to_2000, daysFromCivil(2000, 1, 1));
    const c = civilFromDays(10957);
    try std.testing.expectEqual(@as(i32, 2000), c.y);
    try std.testing.expectEqual(@as(u8, 1), c.m);
    try std.testing.expectEqual(@as(u8, 1), c.d);
    const c2 = civilFromDays(0);
    try std.testing.expectEqual(@as(i32, 1970), c2.y);
    try std.testing.expectEqual(@as(i32, 20719), daysFromCivil(2026, 9, 23));
}

test "coerce basics" {
    try std.testing.expectEqual(@as(i64, 42), try coerce(i64, .{ .int = 42 }));
    try std.testing.expectEqual(@as(?i64, null), try coerce(?i64, .null_));
    try std.testing.expectEqual(@as(i16, 7), try coerce(i16, .{ .int = 7 }));
    try std.testing.expectError(error.TypeMismatch, coerce(bool, .{ .int = 1 }));
}

test "array literal parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const vals = try parseArrayLiteral(a, "{1,2,NULL,4}", oid.int4);
    try std.testing.expectEqual(@as(usize, 4), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 2), vals[1].int);
    try std.testing.expect(vals[2] == .null_);
    try std.testing.expectEqual(@as(i64, 4), vals[3].int);

    const strs = try parseArrayLiteral(a, "{\"a b\",\"c\"\"d\",e}", oid.text);
    try std.testing.expectEqualStrings("a b", strs[0].text);
    try std.testing.expectEqualStrings("c\"d", strs[1].text);
    try std.testing.expectEqualStrings("e", strs[2].text);
}

test "timestamp text decode" {
    const v = try decodeTimestampText("2026-09-23 18:53:00.5", true);
    const ts = v.timestamptz;
    const days: i64 = @as(i64, daysFromCivil(2026, 9, 23) - days_from_1970_to_2000);
    const expect_usec = days * 86_400 * std.time.us_per_s +
        (18 * 3600 + 53 * 60) * std.time.us_per_s + 500_000;
    try std.testing.expectEqual(expect_usec, ts.usec);
}
