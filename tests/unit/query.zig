//! Query-builder unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");

test "query builder: classic injection payloads cannot enter SQL text" {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(std.testing.allocator);
    var encs: std.ArrayList(postgres.types.Enc) = .empty;
    defer encs.deinit(std.testing.allocator);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);

    var ctx = postgres.query.RenderCtx{
        .gpa = std.testing.allocator,
        .sql = &sql,
        .encs = &encs,
        .scratch = &scratch,
    };

    const payload = "' OR 1=1 --";
    try postgres.query.renderQuery(&ctx, "select * from users where name = {}", .{payload});
    try std.testing.expectEqualStrings("select * from users where name = $1", sql.items);
    try std.testing.expectEqual(@as(usize, 1), encs.items.len);
    // the payload lives only in the parameter bytes, never in SQL text
    try std.testing.expectEqualStrings(payload, encs.items[0].bytes);

    const payload2 = "Robert'); DROP TABLE students;--";
    sql.clearRetainingCapacity();
    encs.clearRetainingCapacity();
    try postgres.query.renderQuery(&ctx, "insert into t values ({})", .{payload2});
    try std.testing.expectEqualStrings("insert into t values ($1)", sql.items);
    try std.testing.expectEqualStrings(payload2, encs.items[0].bytes);
}

test "query builder: raw fragment is explicit" {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(std.testing.allocator);
    var encs: std.ArrayList(postgres.types.Enc) = .empty;
    defer encs.deinit(std.testing.allocator);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    var ctx = postgres.query.RenderCtx{
        .gpa = std.testing.allocator,
        .sql = &sql,
        .encs = &encs,
        .scratch = &scratch,
    };
    try postgres.query.renderQuery(&ctx, "select 1 where {}", .{postgres.raw("1=1")});
    try std.testing.expectEqualStrings("select 1 where 1=1", sql.items);
}

test "statement name derives from content" {
    var buf: [20]u8 = undefined;
    var buf2: [20]u8 = undefined;
    const n = postgres.query.stmtNameRuntime("select 1", &buf);
    try std.testing.expectEqualStrings("pgz_", n[0..4]);
    try std.testing.expectEqual(@as(usize, 20), n.len);

    const n2 = postgres.query.stmtNameRuntime("select 1", &buf2);
    try std.testing.expectEqualStrings(n, n2);

    const n3 = postgres.query.stmtNameRuntime("select 2", &buf2);
    try std.testing.expect(!std.mem.eql(u8, n, n3));
}
