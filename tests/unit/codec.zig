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
const valueToText = types.valueToText;

fn decodeTextForTest(text: []const u8, type_oid: u32) !types.Value {
    return types.decodeText(std.testing.allocator, .{
        .name = "v",
        .type_oid = type_oid,
        .typlen = -1,
        .format = 0,
        .table_oid = 0,
        .attnum = 0,
    }, text);
}

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

test "coerce accepts text wire values for int/bool/float" {
    try std.testing.expectEqual(@as(i32, 42), try coerce(i32, .{ .text = "42" }));
    try std.testing.expectEqual(@as(i16, -7), try coerce(i16, .{ .text = "-7" }));
    try std.testing.expectEqual(@as(i64, 9007199254740993), try coerce(i64, .{ .text = "9007199254740993" }));
    try std.testing.expectEqual(@as(u32, 7), try coerce(u32, .{ .text = "7" }));
    try std.testing.expectEqual(@as(f64, 1.5), try coerce(f64, .{ .text = "1.5" }));

    try std.testing.expectEqual(true, try coerce(bool, .{ .text = "t" }));
    try std.testing.expectEqual(true, try coerce(bool, .{ .text = "true" }));
    try std.testing.expectEqual(false, try coerce(bool, .{ .text = "f" }));
    try std.testing.expectEqual(false, try coerce(bool, .{ .text = "0" }));

    // unparseable text is a value error, not a type error
    try std.testing.expectError(error.InvalidValue, coerce(i32, .{ .text = "hello" }));
    try std.testing.expectError(error.InvalidValue, coerce(bool, .{ .text = "maybe" }));
    // out of range stays a type error, and other kinds are still rejected
    try std.testing.expectError(error.TypeMismatch, coerce(i16, .{ .int = 40000 }));
    try std.testing.expectError(error.TypeMismatch, coerce(i32, .{ .bool_ = true }));
    try std.testing.expectError(error.TypeMismatch, coerce(i32, .{ .uuid = [_]u8{0} ** 16 }));
}

test "valueToText renders every scalar the way PostgreSQL does" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1098316516774129684", try valueToText(.{ .int = 1098316516774129684 }, &buf));
    try std.testing.expectEqualStrings("-9223372036854775808", try valueToText(.{ .int = std.math.minInt(i64) }, &buf));
    try std.testing.expectEqualStrings("t", try valueToText(.{ .bool_ = true }, &buf));
    try std.testing.expectEqualStrings("f", try valueToText(.{ .bool_ = false }, &buf));
    try std.testing.expectEqualStrings("1.5", try valueToText(.{ .float = 1.5 }, &buf));
    try std.testing.expectEqualStrings("plain", try valueToText(.{ .text = "plain" }, &buf));
    try std.testing.expectEqualStrings("\\xdeadbeef", try valueToText(.{ .bytea = &[_]u8{ 0xde, 0xad, 0xbe, 0xef } }, &buf));

    var uuid: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&uuid, "550e8400e29b41d4a716446655440000") catch unreachable;
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", try valueToText(.{ .uuid = uuid }, &buf));

    const days: i32 = daysFromCivil(2026, 9, 23) - days_from_1970_to_2000;
    try std.testing.expectEqualStrings("2026-09-23", try valueToText(.{ .date = .{ .days = days } }, &buf));
    try std.testing.expectEqualStrings("00:00:00", try valueToText(.{ .time = .{ .usec = 0 } }, &buf));
    try std.testing.expectEqualStrings("18:53:00.5", try valueToText(.{ .time = .{ .usec = 18 * 3600 * std.time.us_per_s + 53 * 60 * std.time.us_per_s + 500_000 } }, &buf));

    const ts_usec = @as(i64, days) * 86_400 * std.time.us_per_s +
        (18 * 3600 + 53 * 60) * std.time.us_per_s + 500_000;
    try std.testing.expectEqualStrings("2026-09-23 18:53:00.5", try valueToText(.{ .timestamp = .{ .usec = ts_usec } }, &buf));
    try std.testing.expectEqualStrings("2026-09-23 18:53:00.5+00", try valueToText(.{ .timestamptz = .{ .usec = ts_usec } }, &buf));

    // unsupported / NULL have no text form through this API
    try std.testing.expectError(error.TypeMismatch, valueToText(.null_, &buf));
    try std.testing.expectError(error.TypeMismatch, valueToText(.{ .array = .{ .elems = &.{}, .elem_oid = 23 } }, &buf));
    try std.testing.expectError(error.WriteFailed, valueToText(.{ .text = "0123456789" }, buf[0..4]));
}

test "uuid text parsing accepts hyphens and rejects junk" {
    var buf2: [64]u8 = undefined;
    const good = try decodeTextForTest("550e8400-e29b-41d4-a716-446655440000", 2950);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", try valueToText(good, &buf2));
    const nohyphen = try decodeTextForTest("550e8400e29b41d4a716446655440000", 2950);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", try valueToText(nohyphen, &buf2));
    try std.testing.expectError(error.InvalidValue, decodeTextForTest("not-a-uuid", 2950));
    try std.testing.expectError(error.InvalidValue, decodeTextForTest("550e8400-e29b-41d4-a716-44665544000", 2950));
}
