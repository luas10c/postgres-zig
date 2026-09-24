//! Query-rendering unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");
const qb = postgres.query;
const finalSql = qb.finalSql;
const segsFor = qb.segsFor;
const ident = qb.ident;
const quoteIdentInto = qb.quoteIdentInto;
const testing = std.testing;

test "final sql comptime" {
    const Args = struct { i64, []const u8 };
    const sql = comptime finalSql("select * from t where a = {} and b = {}", Args);
    try std.testing.expectEqualStrings("select * from t where a = $1 and b = $2", sql);

    const esc = comptime finalSql("select '{{a,b}}'::text[] where a = {}", struct { y: []const u8 });
    try std.testing.expectEqualStrings("select '{a,b}'::text[] where a = $1", esc);
}

test "segments unescape braces" {
    const segs = comptime segsFor("select '{{a}}' {}", struct { i32 });
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(testing.allocator);
    for (segs) |s| switch (s) {
        .sql => |t| try combined.appendSlice(testing.allocator, t),
        .ph => try combined.appendSlice(testing.allocator, "<PH>"),
    };
    try std.testing.expectEqualStrings("select '{a}' <PH>", combined.items);
}

test "ident quoting adversarial" {
    // empty parts and control characters are rejected outright
    try std.testing.expectError(error.InvalidIdent, ident(""));
    try std.testing.expectError(error.InvalidIdent, ident("a\x00b"));
    try std.testing.expectError(error.InvalidIdent, ident("a\nb"));
    try std.testing.expectError(error.InvalidIdent, ident("schema."));

    // anything else is quoted, so it cannot escape the identifier
    const nasty = try ident("users; drop table x");
    try std.testing.expectEqualStrings("\"users; drop table x\"", nasty.quoted());
    try std.testing.expectEqualStrings("\"a\"\"b\"", (try ident("a\"b")).quoted());
    try std.testing.expectEqualStrings("\"public\".\"users\"", (try ident("public.users")).quoted());

    const ok = try ident("users");
    try std.testing.expectEqualStrings("\"users\"", ok.quoted());

    var buf: [200]u8 = undefined;
    const q = try quoteIdentInto(&buf, "we\"ird");
    try std.testing.expectEqualStrings("\"we\"\"ird\"", q);

    var long: [64]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectError(error.InvalidIdent, ident(&long));
}
