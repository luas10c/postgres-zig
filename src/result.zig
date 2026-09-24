const std = @import("std");
const errors = @import("error.zig");
const types = @import("types.zig");
const options = @import("options.zig");

pub const Column = types.Column;
pub const Value = types.Value;

pub const State = struct {
    pid: u32,
    secret: u32,
};

pub const Result = struct {
    arena_state: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    columns: []Column = &.{},
    count: i64 = 0,
    command_tag: []const u8 = "",
    statement_name: []const u8 = "",
    state: State = .{ .pid = 0, .secret = 0 },
    transform: options.ColumnTransform = .none,

    pub fn deinit(self: *Result) void {
        self.arena_state.deinit();
    }

    pub fn arena(self: *Result) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn first(self: *const Result) ?Row {
        if (self.rows.len == 0) return null;
        return .{ .values = self.rows[0].values, .columns = self.columns };
    }

    /// Comptime-decode all rows into `[]T` (allocated in the result arena;
    /// freed on `deinit`). Fields are matched by column name — exact, or
    /// snake_case-transformed per the connection's `transform_column`.
    pub fn to(self: *Result, comptime T: type) errors.Error![]T {
        const n = self.rows.len;
        const out = self.arena().alloc(T, n) catch return error.OutOfMemory;
        const fields = @typeInfo(T).@"struct".fields;
        for (self.rows, 0..) |row, ri| {
            inline for (fields) |f| {
                const idx = findColumn(self.columns, f.name, self.transform) orelse return error.UndefinedColumn;
                @field(out[ri], f.name) = try types.coerce(f.type, row.values[idx]);
            }
        }
        return out;
    }

    fn findColumn(columns: []const Column, comptime field_name: []const u8, transform: options.ColumnTransform) ?usize {
        const snake = comptime toSnake(field_name);
        for (columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, field_name)) return i;
        }
        if (transform != .none and !std.mem.eql(u8, snake, field_name)) {
            for (columns, 0..) |col, i| {
                if (std.mem.eql(u8, col.name, snake)) return i;
            }
        }
        return null;
    }
};

pub const Row = struct {
    values: []const Value,
    columns: []const Column,

    pub fn get(self: Row, comptime T: type, name: []const u8) errors.Error!T {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) {
                return types.coerce(T, self.values[i]);
            }
        }
        return error.UndefinedColumn;
    }

    pub fn getAt(self: Row, comptime T: type, index: usize) errors.Error!T {
        if (index >= self.values.len) return error.UndefinedColumn;
        return types.coerce(T, self.values[index]);
    }
};

/// Describe-only result (`` sql`...`.describe() `` parity).
pub const Describe = struct {
    arena_state: std.heap.ArenaAllocator,
    sql: []const u8 = "",
    columns: []Column = &.{},
    param_oids: []u32 = &.{},
    statement_name: []const u8 = "",

    pub fn deinit(self: *Describe) void {
        self.arena_state.deinit();
    }
};

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

/// Convert a Zig field name (any case) to snake_case (column convention).
pub fn toSnake(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len * 2]u8 = undefined;
        var o: usize = 0;
        for (name, 0..) |c, i| {
            if (isUpper(c)) {
                if (i != 0) {
                    buf[o] = '_';
                    o += 1;
                }
                buf[o] = c + ('a' - 'A');
                o += 1;
            } else {
                buf[o] = c;
                o += 1;
            }
        }
        const fin: [o]u8 = buf[0..o].*;
        return &fin;
    }
}

test "toSnake" {
    try std.testing.expectEqualStrings("user_id", comptime toSnake("userId"));
    try std.testing.expectEqualStrings("user_id", comptime toSnake("UserId"));
    try std.testing.expectEqualStrings("a", comptime toSnake("a"));
    try std.testing.expectEqualStrings("http_client", comptime toSnake("httpClient"));
}

test "result.to comptime decode" {
    var res = Result{
        .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer res.deinit();

    const a = res.arena();
    const cols = a.dupe(Column, &.{
        .{ .name = "user_id", .type_oid = 20, .typlen = 8, .format = 0, .table_oid = 0, .attnum = 0 },
        .{ .name = "name", .type_oid = 25, .typlen = -1, .format = 0, .table_oid = 0, .attnum = 0 },
        .{ .name = "age", .type_oid = 23, .typlen = 4, .format = 0, .table_oid = 0, .attnum = 0 },
    }) catch unreachable;
    res.columns = cols;

    const vals = a.dupe(Value, &.{
        .{ .int = 7 },
        .{ .text = a.dupe(u8, "Murray") catch unreachable },
        .{ .null_ = {} },
    }) catch unreachable;
    const vals2 = a.dupe(Value, &.{
        .{ .int = 8 },
        .{ .text = a.dupe(u8, "Walter") catch unreachable },
        .{ .int = 80 },
    }) catch unreachable;

    const rows = a.dupe(Row, &.{
        .{ .values = vals, .columns = cols },
        .{ .values = vals2, .columns = cols },
    }) catch unreachable;
    res.rows = rows;

    const User = struct { user_id: i64, name: []const u8, age: ?i32 };
    const users = try res.to(User);
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqual(@as(i64, 7), users[0].user_id);
    try std.testing.expectEqualStrings("Murray", users[0].name);
    try std.testing.expectEqual(@as(?i32, null), users[0].age);
    try std.testing.expectEqual(@as(i32, 80), users[1].age.?);

    const Bad = struct { nope: i64 };
    try std.testing.expectError(error.UndefinedColumn, res.to(Bad));
}
