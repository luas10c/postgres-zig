//! Types-codec unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");

test "binary decode roundtrips wire values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const col = struct {
        fn c(oid: u32) postgres.Column {
            return .{ .name = "x", .type_oid = oid, .typlen = 0, .format = 1, .table_oid = 0, .attnum = 0 };
        }
    }.c;

    try std.testing.expect(postgres.types.binResultOid(23));
    try std.testing.expect(!postgres.types.binResultOid(25));
    try std.testing.expect(!postgres.types.binResultOid(1700));

    var b4 = [_]u8{ 0, 0, 0, 42 };
    try std.testing.expectEqual(@as(i64, 42), (try postgres.types.decodeBinary(a, col(23), &b4)).int);
    var b8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 42 };
    try std.testing.expectEqual(@as(i64, 42), (try postgres.types.decodeBinary(a, col(20), &b8)).int);
    var neg = [_]u8{ 255, 255, 255, 254 };
    try std.testing.expectEqual(@as(i64, -2), (try postgres.types.decodeBinary(a, col(23), &neg)).int);
    var f8 = [_]u8{ 64, 9, 33, 251, 84, 68, 45, 24 }; // pi
    try std.testing.expectApproxEqAbs(std.math.pi, (try postgres.types.decodeBinary(a, col(701), &f8)).float, 1e-12);
    var bt = [_]u8{1};
    try std.testing.expect((try postgres.types.decodeBinary(a, col(16), &bt)).bool_);
    var dt = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(i32, 0), (try postgres.types.decodeBinary(a, col(1082), &dt)).date.days);
    var ts = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(i64, 0), (try postgres.types.decodeBinary(a, col(1114), &ts)).timestamp.usec);

    // strict lengths: hostile/short payloads must error, never misread
    try std.testing.expectError(error.InvalidValue, postgres.types.decodeBinary(a, col(23), b4[0..3]));
    try std.testing.expectError(error.InvalidValue, postgres.types.decodeBinary(a, col(20), &b4));
    try std.testing.expectError(error.TypeMismatch, postgres.types.decodeBinary(a, col(25), &b4));
}

test "array literal parse adversarial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const int4: u32 = 23;
    const text_oid: u32 = 25;

    // truncated / malformed inputs must error, never panic
    try std.testing.expectError(error.InvalidValue, postgres.types.parseArrayLiteral(a, "{1,", int4));
    try std.testing.expectError(error.InvalidValue, postgres.types.parseArrayLiteral(a, "no braces", int4));
    try std.testing.expectError(error.InvalidValue, postgres.types.parseArrayLiteral(a, "{\"unterminated}", text_oid));

    const ok = try postgres.types.parseArrayLiteral(a, "{a,b}", text_oid);
    try std.testing.expectEqual(@as(usize, 2), ok.len);
}
