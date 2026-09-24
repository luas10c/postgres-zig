const std = @import("std");
const errors = @import("error.zig");

/// 2000-01-01T00:00:00Z
pub const pg_epoch_offset_sec: i64 = 946684800;

pub const Date = struct {
    /// Days since 2000-01-01.
    days: i32,

    pub fn fromCivil(y: i32, m: u8, d: u8) Date {
        return .{ .days = daysFromCivil(y, m, d) - days_from_1970_to_2000 };
    }
    pub fn toCivil(date: Date) struct { y: i32, m: u8, d: u8 } {
        return civilFromDays(date.days + days_from_1970_to_2000);
    }
};

pub const Time = struct {
    /// Microseconds since midnight.
    usec: i64,
};

pub const Timestamp = struct {
    /// Microseconds since 2000-01-01T00:00:00 (naive or UTC-normalized).
    usec: i64,

    pub fn now(io: std.Io) Timestamp {
        const unix_us = std.Io.Timestamp.now(io, .real).toMicroseconds();
        return .{ .usec = unix_us - pg_epoch_offset_sec * std.time.us_per_s };
    }
};

pub const Interval = struct {
    usec: i64,
    days: i32,
    months: i32,
};

pub const days_from_1970_to_2000: i32 = 10957;

/// Days since 1970-01-01 for a civil date (proleptic Gregorian).
pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i32 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @intCast(era * 146097 + doe - 719468);
}

pub fn civilFromDays(z_in: i32) struct { y: i32, m: u8, d: u8 } {
    var z: i64 = z_in;
    z += 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = @intCast(if (m <= 2) y + 1 else y), .m = m, .d = d };
}

/// Force an explicit PostgreSQL OID for a value (`sql.typed` parity).
pub fn Typed(comptime T: type) type {
    return struct { value: T, oid: u32 };
}

pub fn typed(v: anytype, o: u32) Typed(@TypeOf(v)) {
    return .{ .value = v, .oid = o };
}

/// Send as `bytea` (binary format).
pub const Bytea = struct { bytes: []const u8 };
pub fn bytea(bytes: []const u8) Bytea {
    return .{ .bytes = bytes };
}

/// Serialize with std.json and send as `json`.
pub fn Json(comptime T: type) type {
    return struct { value: T };
}
pub fn json(v: anytype) Json(@TypeOf(v)) {
    return .{ .value = v };
}

/// One fully-encoded protocol parameter.
/// `bytes` points either into `buf` (small fixed-size binary values) or to
/// user-owned memory (slices) or into the connection scratch (arrays/json).
/// Built-in type object IDs (pg_type.oid).
pub const oid = struct {
    pub const bool_: u32 = 16;
    pub const bytea: u32 = 17;
    pub const char: u32 = 18;
    pub const name: u32 = 19;
    pub const int8: u32 = 20;
    pub const int2: u32 = 21;
    pub const int4: u32 = 23;
    pub const text: u32 = 25;
    pub const oid: u32 = 26;
    pub const xid: u32 = 28;
    pub const json: u32 = 114;
    pub const float4: u32 = 700;
    pub const float8: u32 = 701;
    pub const unknown: u32 = 705;
    pub const bpchar: u32 = 1042;
    pub const varchar: u32 = 1043;
    pub const date: u32 = 1082;
    pub const time: u32 = 1083;
    pub const timestamp: u32 = 1114;
    pub const timestamptz: u32 = 1184;
    pub const _timestamp: u32 = 1115;
    pub const _timestamptz: u32 = 1185;
    pub const interval: u32 = 1186;
    pub const _interval: u32 = 1187;
    pub const _date: u32 = 1182;
    pub const _time: u32 = 1183;
    pub const numeric: u32 = 1700;
    pub const uuid: u32 = 2950;
    pub const _uuid: u32 = 2951;
    pub const jsonb: u32 = 3802;
    pub const _jsonb: u32 = 3807;
    pub const _json: u32 = 199;
    pub const _bool: u32 = 1000;
    pub const _bytea: u32 = 1001;
    pub const _name: u32 = 1003;
    pub const _int2: u32 = 1005;
    pub const _int4: u32 = 1007;
    pub const _text: u32 = 1009;
    pub const _bpchar: u32 = 1014;
    pub const _varchar: u32 = 1015;
    pub const _int8: u32 = 1016;
    pub const _float4: u32 = 1021;
    pub const _float8: u32 = 1022;
    pub const _numeric: u32 = 1231;
};

pub const Enc = struct {
    /// 0 = let the server infer.
    oid: u32,
    /// 0 = text, 1 = binary.
    format: u8,
    bytes: []const u8,
    buf: [16]u8 = undefined,
    /// protocol length -1 (vs an empty value with length 0).
    is_null: bool = false,
};

/// Infer the parameter OID for a Zig type (0 = unspecified/inferred).
pub fn inferOid(comptime T: type) u32 {
    return switch (T) {
        bool => oid.bool_,
        i16 => oid.int2,
        i32, u8, u16 => oid.int4,
        i64, u32 => oid.int8,
        f32 => oid.float4,
        f64 => oid.float8,
        Date => oid.date,
        Time => oid.time,
        Timestamp => oid.timestamp,
        Interval => oid.interval,
        [16]u8 => oid.uuid,
        else => blk: {
            const info = @typeInfo(T);
            switch (info) {
                .optional => break :blk inferOid(info.optional.child),
                .pointer => |p| {
                    if (p.size == .one) {
                        const child_info = @typeInfo(p.child);
                        if (child_info == .array and child_info.array.child == u8) break :blk 0;
                        break :blk inferOid(p.child);
                    }
                    if (p.size == .slice) {
                        if (p.child == u8) break :blk 0;
                        break :blk arrayOid(inferOid(p.child));
                    }
                    break :blk 0;
                },
                .array => |a| {
                    if (a.child == u8) break :blk 0;
                    break :blk arrayOid(inferOid(a.child));
                },
                .@"enum" => break :blk 0,
                .int => |i| if (i.signedness == .signed) {
                    break :blk if (i.bits <= 16) oid.int2 else if (i.bits <= 32) oid.int4 else oid.int8;
                } else {
                    break :blk if (i.bits <= 31) oid.int4 else oid.int8;
                },
                .float => break :blk if (info.float.bits <= 32) oid.float4 else oid.float8,
                .comptime_int, .comptime_float => break :blk 0,
                else => break :blk 0,
            }
        },
    };
}

fn arrayOid(elem_oid: u32) u32 {
    const pairs = [_][2]u32{
        .{ oid.bool_, oid._bool },
        .{ oid.bytea, oid._bytea },
        .{ oid.int2, oid._int2 },
        .{ oid.int4, oid._int4 },
        .{ oid.int8, oid._int8 },
        .{ oid.float4, oid._float4 },
        .{ oid.float8, oid._float8 },
        .{ oid.text, oid._text },
        .{ oid.varchar, oid._varchar },
        .{ oid.numeric, oid._numeric },
        .{ oid.uuid, oid._uuid },
        .{ oid.date, oid._date },
        .{ oid.time, oid._time },
        .{ oid.timestamp, oid._timestamp },
        .{ oid.timestamptz, oid._timestamptz },
        .{ oid.interval, oid._interval },
        .{ oid.json, oid._json },
        .{ oid.jsonb, oid._jsonb },
    };
    for (pairs) |p| if (p[0] == elem_oid) return p[1];
    return 0;
}

/// True when the type must be sent as text format (server inference).
fn isTextualOid(o: u32) bool {
    return o == 0 or o == oid.text or o == oid.varchar or
        o == oid.bpchar or o == oid.name or o == oid.char or
        o == oid.json or o == oid.jsonb or o == oid.numeric or
        o == oid.unknown;
}

pub const EncodeCtx = struct {
    encs: *std.ArrayList(Enc),
    scratch: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
};

/// Append one encoded parameter for a Zig value (comptime-dispatched).
/// Append an Enc, rewiring `bytes` (which points into the stack-local
/// `item.buf`) to the appended copy's own buffer — avoiding dangling
/// stack pointers (SQLi-adjacent memory-safety fix).
fn appendEnc(ctx: *EncodeCtx, item: Enc, comptime n: usize) errors.Error!void {
    const idx = ctx.encs.items.len;
    try ctx.encs.append(ctx.gpa, item);
    if (n > 0) ctx.encs.items[idx].bytes = ctx.encs.items[idx].buf[0..n];
}

pub fn encodeParam(ctx: *EncodeCtx, value: anytype) errors.Error!void {
    const T = @TypeOf(value);
    const encs = ctx.encs;
    const scratch = ctx.scratch;
    const gpa = ctx.gpa;

    switch (@typeInfo(T)) {
        .optional => {
            if (value) |v| {
                return encodeParam(ctx, v);
            }
            try encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = &.{}, .is_null = true });
        },
        .null => try encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = &.{}, .is_null = true }),
        .bool => {
            var item = Enc{ .oid = oid.bool_, .format = 1, .bytes = undefined };
            item.buf[0] = @intFromBool(value);
            try appendEnc(ctx, item, 1);
        },
        .int => |i| {
            if (i.signedness == .signed) {
                const int_oid: u32 = if (i.bits <= 16) oid.int2 else if (i.bits <= 32) oid.int4 else oid.int8;
                var item = Enc{ .oid = int_oid, .format = 1, .bytes = undefined };
                switch (oidLen(int_oid)) {
                    2 => std.mem.writeInt(i16, item.buf[0..2], @intCast(value), .big),
                    4 => std.mem.writeInt(i32, item.buf[0..4], @intCast(value), .big),
                    else => std.mem.writeInt(i64, item.buf[0..8], @intCast(value), .big),
                }
                try appendEnc(ctx, item, oidLen(int_oid));
            } else {
                if (@as(u64, value) > std.math.maxInt(i64)) return error.InvalidValue;
                var item = Enc{ .oid = oid.int8, .format = 1, .bytes = undefined };
                std.mem.writeInt(i64, item.buf[0..8], @intCast(value), .big);
                try appendEnc(ctx, item, 8);
            }
        },
        .float => {
            const is_f32 = @typeInfo(T).float.bits <= 32;
            var item = Enc{ .oid = if (is_f32) oid.float4 else oid.float8, .format = 1, .bytes = undefined };
            if (is_f32) {
                std.mem.writeInt(u32, item.buf[0..4], @bitCast(@as(f32, @floatCast(value))), .big);
                try appendEnc(ctx, item, 4);
            } else {
                std.mem.writeInt(u64, item.buf[0..8], @bitCast(@as(f64, value)), .big);
                try appendEnc(ctx, item, 8);
            }
        },
        .@"enum" => {
            const name = @tagName(value);
            try encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = name });
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    try encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = value });
                } else {
                    return encodeArray(ctx, value, inferOid(p.child));
                }
            },
            .one => {
                const ci = @typeInfo(p.child);
                if (ci == .array and ci.array.child == u8) {
                    try encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = value });
                } else if (ci == .array) {
                    return encodeParam(ctx, value.*);
                } else if (p.child == Date) {
                    try encodeDate(ctx, value.*);
                } else if (p.child == Time) {
                    var item = Enc{ .oid = oid.time, .format = 1, .bytes = undefined };
                    std.mem.writeInt(i64, item.buf[0..8], value.usec, .big);
                    try appendEnc(ctx, item, 8);
                } else if (p.child == Timestamp) {
                    var item = Enc{ .oid = oid.timestamp, .format = 1, .bytes = undefined };
                    std.mem.writeInt(i64, item.buf[0..8], value.usec, .big);
                    try appendEnc(ctx, item, 8);
                } else if (p.child == Interval) {
                    var item = Enc{ .oid = oid.interval, .format = 1, .bytes = undefined };
                    std.mem.writeInt(i64, item.buf[0..8], value.usec, .big);
                    std.mem.writeInt(i32, item.buf[8..12], value.days, .big);
                    std.mem.writeInt(i32, item.buf[12..16], value.months, .big);
                    try appendEnc(ctx, item, 16);
                } else if (p.child == Bytea) {
                    try encs.append(gpa, .{ .oid = oid.bytea, .format = 1, .bytes = value.bytes });
                } else {
                    @compileError("unsupported pointer parameter type: " ++ @typeName(p.child) ++ " (wrap values with pg.typed/pg.json/pg.bytea)");
                }
            },
            else => @compileError("unsupported pointer parameter type"),
        },
        .array => |a| {
            if (a.child == u8) {
                try encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = &value });
            } else {
                return encodeArray(ctx, value, inferOid(a.child));
            }
        },
        .@"struct" => {
            const start = scratch.items.len;
            if (T == Date) {
                try encodeDate(ctx, value);
            } else if (T == Time) {
                var item = Enc{ .oid = oid.time, .format = 1, .bytes = undefined };
                std.mem.writeInt(i64, item.buf[0..8], value.usec, .big);
                try appendEnc(ctx, item, 8);
            } else if (T == Timestamp) {
                var item = Enc{ .oid = oid.timestamp, .format = 1, .bytes = undefined };
                std.mem.writeInt(i64, item.buf[0..8], value.usec, .big);
                try appendEnc(ctx, item, 8);
            } else if (T == Interval) {
                var item = Enc{ .oid = oid.interval, .format = 1, .bytes = undefined };
                std.mem.writeInt(i64, item.buf[0..8], value.usec, .big);
                std.mem.writeInt(i32, item.buf[8..12], value.days, .big);
                std.mem.writeInt(i32, item.buf[12..16], value.months, .big);
                try appendEnc(ctx, item, 16);
            } else if (T == Bytea) {
                try encs.append(gpa, .{ .oid = oid.bytea, .format = 1, .bytes = value.bytes });
            } else if (@hasField(T, "value") and @hasField(T, "oid") and isTyped(T)) {
                if (isTextualOid(value.oid)) {
                    try encs.append(gpa, .{ .oid = value.oid, .format = 0, .bytes = asText(value.value) });
                } else {
                    const before = encs.items.len;
                    try encodeParam(ctx, value.value);
                    encs.items[before].oid = value.oid;
                }
            } else if (comptime isJsonWrapper(T)) {
                const text = std.json.Stringify.valueAlloc(gpa, value.value, .{}) catch return error.OutOfMemory;
                defer gpa.free(text);
                try scratch.appendSlice(gpa, text);
                try encs.append(gpa, .{ .oid = oid.json, .format = 0, .bytes = scratch.items[start..] });
            } else {
                @compileError("unsupported struct parameter type: " ++ @typeName(T) ++ " (use pg.json(v), pg.typed(v, oid) or pass fields individually)");
            }
        },
        .comptime_int => {
            if (value > std.math.maxInt(i32) or value < std.math.minInt(i32)) {
                if (value > std.math.maxInt(i64) or value < std.math.minInt(i64)) {
                    @compileError("comptime_int parameter does not fit int8");
                }
                var item = Enc{ .oid = oid.int8, .format = 1, .bytes = undefined };
                std.mem.writeInt(i64, item.buf[0..8], value, .big);
                try appendEnc(ctx, item, 8);
            } else {
                var item = Enc{ .oid = oid.int4, .format = 1, .bytes = undefined };
                std.mem.writeInt(i32, item.buf[0..4], @intCast(value), .big);
                try appendEnc(ctx, item, 4);
            }
        },
        .comptime_float => try encodeParam(ctx, @as(f64, value)),
        else => @compileError("unsupported parameter type: " ++ @typeName(T)),
    }
}

fn asText(v: anytype) []const u8 {
    const T = @TypeOf(v);
    const info = @typeInfo(T);
    if (info == .pointer) {
        if (info.pointer.size == .slice and info.pointer.child == u8) return v;
        if (info.pointer.size == .one) {
            const ci = @typeInfo(info.pointer.child);
            if (ci == .array and ci.array.child == u8) return v;
        }
    }
    if (info == .array and info.array.child == u8) return &v;
    if (info == .@"enum") return @tagName(v);
    @compileError("pg.typed with a text OID requires a string/enum value, got " ++ @typeName(T));
}

fn isTyped(comptime T: type) bool {
    const f = @typeInfo(T).@"struct".fields;
    return f.len == 2 and std.mem.eql(u8, f[1].name, "oid") and f[1].type == u32 and std.mem.eql(u8, f[0].name, "value");
}

fn isJsonWrapper(comptime T: type) bool {
    const f = @typeInfo(T).@"struct".fields;
    return f.len == 1 and std.mem.eql(u8, f[0].name, "value");
}

fn oidLen(o: u32) usize {
    return switch (o) {
        oid.int2 => 2,
        oid.int4 => 4,
        else => 8,
    };
}

fn encodeDate(ctx: *EncodeCtx, d: Date) errors.Error!void {
    var item = Enc{ .oid = oid.date, .format = 1, .bytes = undefined };
    std.mem.writeInt(i32, item.buf[0..4], d.days, .big);
    try appendEnc(ctx, item, 4);
}

/// Binary array encode for primitive element types. `elem_oid` must be
/// non-zero, otherwise the caller should use a text array literal.
fn encodeArray(ctx: *EncodeCtx, slice: anytype, elem_oid: u32) errors.Error!void {
    if (elem_oid == 0) return encodeArrayTextLiteral(ctx, slice);
    const gpa = ctx.gpa;
    const start = ctx.scratch.items.len;

    var hdr: [20]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 1, .big);
    std.mem.writeInt(u32, hdr[4..8], 0, .big);
    std.mem.writeInt(u32, hdr[8..12], elem_oid, .big);
    std.mem.writeInt(u32, hdr[12..16], @intCast(slice.len), .big);
    std.mem.writeInt(u32, hdr[16..20], 1, .big);
    try ctx.scratch.appendSlice(gpa, &hdr);

    const Elem = switch (@typeInfo(@TypeOf(slice))) {
        .array => |a| a.child,
        .pointer => |p| p.child,
        else => @compileError("expected array or slice"),
    };
    const has_nulls = comptime @typeInfo(Elem) == .optional;
    const bitmap_start = ctx.scratch.items.len;
    const bitmap_len = if (has_nulls) (slice.len + 7) / 8 else 0;
    try ctx.scratch.appendNTimes(gpa, 0, bitmap_len);

    for (slice, 0..) |elem, i| {
        var item_buf: [16]u8 = undefined;
        var bytes: []const u8 = undefined;
        var is_null = false;
        if (has_nulls) {
            if (elem) |e| {
                bytes = try encodeElemBytes(@TypeOf(e), elem_oid, e, &item_buf);
            } else is_null = true;
        } else {
            bytes = try encodeElemBytes(Elem, elem_oid, elem, &item_buf);
        }
        if (is_null) {
            ctx.scratch.items[bitmap_start + i / 8] |= @as(u8, 0x80) >> @intCast(i % 8);
            var lb: [4]u8 = undefined;
            std.mem.writeInt(i32, lb[0..4], -1, .big);
            try ctx.scratch.appendSlice(gpa, &lb);
        } else {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(i32, lb[0..4], @intCast(bytes.len), .big);
            try ctx.scratch.appendSlice(gpa, &lb);
            try ctx.scratch.appendSlice(gpa, bytes);
        }
    }
    try ctx.encs.append(gpa, .{ .oid = arrayOid(elem_oid), .format = 1, .bytes = ctx.scratch.items[start..] });
}

fn encodeElemBytes(comptime E: type, elem_oid: u32, elem: E, buf: *[16]u8) errors.Error![]const u8 {
    const info = @typeInfo(E);
    switch (info) {
        .optional => {
            return encodeElemBytes(info.optional.child, elem_oid, elem.?, buf);
        },
        .bool => {
            buf[0] = @intFromBool(elem);
            return buf[0..1];
        },
        .int, .comptime_int => {
            const v: i64 = switch (info) {
                .int => @intCast(elem),
                else => @intCast(elem),
            };
            switch (elem_oid) {
                oid.int2 => {
                    std.mem.writeInt(i16, buf[0..2], @intCast(v), .big);
                    return buf[0..2];
                },
                oid.int4 => {
                    std.mem.writeInt(i32, buf[0..4], @intCast(v), .big);
                    return buf[0..4];
                },
                else => {
                    std.mem.writeInt(i64, buf[0..8], v, .big);
                    return buf[0..8];
                },
            }
        },
        .float, .comptime_float => {
            const v: f64 = switch (info) {
                .float => @floatCast(elem),
                else => @floatCast(elem),
            };
            if (elem_oid == oid.float4) {
                std.mem.writeInt(u32, buf[0..4], @bitCast(@as(f32, @floatCast(v))), .big);
                return buf[0..4];
            }
            std.mem.writeInt(u64, buf[0..8], @bitCast(v), .big);
            return buf[0..8];
        },
        else => {
            switch (E) {
                [16]u8 => {
                    @memcpy(buf, &elem);
                    return buf[0..16];
                },
                Date => {
                    std.mem.writeInt(i32, buf[0..4], elem.days, .big);
                    return buf[0..4];
                },
                Timestamp => {
                    std.mem.writeInt(i64, buf[0..8], elem.usec, .big);
                    return buf[0..8];
                },
                Time => {
                    std.mem.writeInt(i64, buf[0..8], elem.usec, .big);
                    return buf[0..8];
                },
                else => return error.TypeMismatch,
            }
        },
    }
}

fn asI64(v: anytype, comptime E: type) i64 {
    return switch (@typeInfo(E)) {
        .int => @intCast(v),
        .comptime_int => @intCast(v),
        .optional => asI64(v.?, @typeInfo(E).optional.child),
        else => @compileError("expected integer element"),
    };
}

fn asF64(v: anytype, comptime E: type) f64 {
    return switch (@typeInfo(E)) {
        .float => @floatCast(v),
        .comptime_float => @floatCast(v),
        .optional => asF64(v.?, @typeInfo(E).optional.child),
        else => @compileError("expected float element"),
    };
}

/// Text array literal for element types without binary array encoding
/// (strings, etc.) — `{v1,v2,"quoted",NULL}` with proper escaping.
fn encodeArrayTextLiteral(ctx: *EncodeCtx, slice: anytype) errors.Error!void {
    const gpa = ctx.gpa;
    const start = ctx.scratch.items.len;
    try ctx.scratch.append(gpa, '{');
    for (slice, 0..) |elem, i| {
        if (i != 0) try ctx.scratch.append(gpa, ',');
        const E = switch (@typeInfo(@TypeOf(slice))) {
            .array => |a| a.child,
            .pointer => |p| p.child,
            else => @compileError("expected array or slice"),
        };
        const optional = @typeInfo(E) == .optional;
        if (optional and elem == null) {
            try ctx.scratch.appendSlice(gpa, "NULL");
        } else if (optional) {
            try appendArrayElemText(ctx, elem.?);
        } else {
            try appendArrayElemText(ctx, elem);
        }
    }
    try ctx.scratch.append(gpa, '}');
    try ctx.encs.append(gpa, .{ .oid = 0, .format = 0, .bytes = ctx.scratch.items[start..] });
}

fn appendArrayElemText(ctx: *EncodeCtx, elem: anytype) errors.Error!void {
    const gpa = ctx.gpa;
    const E = @TypeOf(elem);
    switch (@typeInfo(E)) {
        .pointer => |p| if (p.size == .slice and p.child == u8) {
            try appendQuotedArrayElem(ctx, elem);
        } else if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) {
            try appendQuotedArrayElem(ctx, elem);
        } else @compileError("unsupported array element type"),
        .array => |a| if (a.child == u8) {
            try appendQuotedArrayElem(ctx, &elem);
        } else @compileError("unsupported array element type"),
        .@"enum" => try appendQuotedArrayElem(ctx, @tagName(elem)),
        .int => {
            var b: [24]u8 = undefined;
            try ctx.scratch.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{elem}) catch return error.Unexpected);
        },
        .comptime_int => {
            var b: [24]u8 = undefined;
            try ctx.scratch.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{elem}) catch return error.Unexpected);
        },
        .float => {
            var b: [48]u8 = undefined;
            try ctx.scratch.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{elem}) catch return error.Unexpected);
        },
        .optional => {
            if (elem) |e| try appendArrayElemText(ctx, e) else try ctx.scratch.appendSlice(gpa, "NULL");
        },
        else => @compileError("unsupported array element type: " ++ @typeName(E)),
    }
}

fn appendQuotedArrayElem(ctx: *EncodeCtx, s: []const u8) errors.Error!void {
    const gpa = ctx.gpa;
    try ctx.scratch.append(gpa, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try ctx.scratch.append(gpa, '\\');
        try ctx.scratch.append(gpa, c);
    }
    try ctx.scratch.append(gpa, '"');
}

pub const Value = union(enum) {
    null_,
    bool_: bool,
    /// All integer widths decoded to i64 (lossless).
    int: i64,
    /// All float widths decoded to f64.
    float: f64,
    /// Any textual type (text/varchar/numeric/json/unknown/interval text...).
    text: []const u8,
    bytea: []const u8,
    date: Date,
    time: Time,
    timestamp: Timestamp,
    timestamptz: Timestamp,
    uuid: [16]u8,
    array: struct { elems: []const Value, elem_oid: u32 },
};

pub const Column = struct {
    name: []const u8,
    type_oid: u32,
    typlen: i16,
    format: u16,
    table_oid: u32,
    attnum: i16,
};

/// Decode one field received in TEXT format (results use text format in
/// this version — same wire format postgres.js consumes).
pub fn decodeText(arena: std.mem.Allocator, col: Column, bytes: []const u8) errors.Error!Value {
    const o = col.type_oid;
    switch (o) {
        oid.bool_ => return .{ .bool_ = bytes.len > 0 and bytes[0] == 't' },
        oid.int2, oid.int4, oid.int8, oid.oid, oid.xid => {
            return .{ .int = std.fmt.parseInt(i64, bytes, 10) catch return error.InvalidValue };
        },
        oid.float4, oid.float8 => {
            return .{ .float = std.fmt.parseFloat(f64, bytes) catch return error.InvalidValue };
        },
        oid.bytea => {
            if (bytes.len >= 2 and bytes[0] == '\\' and bytes[1] == 'x') {
                const hex = bytes[2..];
                const out = arena.alloc(u8, hex.len / 2) catch return error.OutOfMemory;
                _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidValue;
                return .{ .bytea = out };
            }
            return .{ .text = arena.dupe(u8, bytes) catch return error.OutOfMemory };
        },
        oid.date, oid.time, oid.timestamp, oid.timestamptz => {
            return .{ .text = arena.dupe(u8, bytes) catch return error.OutOfMemory };
        },
        oid.uuid => {
            var out: [16]u8 = undefined;
            _ = std.fmt.hexToBytes(&out, bytes) catch return error.InvalidValue;
            return .{ .uuid = out };
        },
        else => {
            if (isArrayOid(o)) {
                const elems = try parseArrayLiteral(arena, bytes, elemOidOfArray(o));
                return .{ .array = .{ .elems = elems, .elem_oid = elemOidOfArray(o) } };
            }
            return .{ .text = arena.dupe(u8, bytes) catch return error.OutOfMemory };
        },
    }
}

/// True when this driver can decode the type from the BINARY wire
/// format (direct memory reads, no text parsing). Everything else is
/// requested — and decoded — as text.
pub fn binResultOid(o: u32) bool {
    return switch (o) {
        oid.bool_,
        oid.bytea,
        oid.int2,
        oid.int4,
        oid.int8,
        oid.oid,
        oid.xid,
        oid.float4,
        oid.float8,
        oid.date,
        oid.time,
        oid.timestamp,
        oid.timestamptz,
        oid.uuid,
        => true,
        else => false,
    };
}

/// Decode one field received in BINARY format. Lengths are validated
/// strictly (hostile-server hardening): any mismatch is an error,
/// never undefined behavior.
pub fn decodeBinary(arena: std.mem.Allocator, col: Column, bytes: []const u8) errors.Error!Value {
    const o = col.type_oid;
    switch (o) {
        oid.bool_ => {
            if (bytes.len != 1) return error.InvalidValue;
            return .{ .bool_ = bytes[0] != 0 };
        },
        oid.int2 => {
            if (bytes.len != 2) return error.InvalidValue;
            return .{ .int = std.mem.readInt(i16, bytes[0..2], .big) };
        },
        oid.int4 => {
            if (bytes.len != 4) return error.InvalidValue;
            return .{ .int = std.mem.readInt(i32, bytes[0..4], .big) };
        },
        oid.int8 => {
            if (bytes.len != 8) return error.InvalidValue;
            return .{ .int = std.mem.readInt(i64, bytes[0..8], .big) };
        },
        oid.oid, oid.xid => {
            if (bytes.len != 4) return error.InvalidValue;
            return .{ .int = std.mem.readInt(u32, bytes[0..4], .big) };
        },
        oid.float4 => {
            if (bytes.len != 4) return error.InvalidValue;
            const bits = std.mem.readInt(u32, bytes[0..4], .big);
            return .{ .float = @as(f32, @bitCast(bits)) };
        },
        oid.float8 => {
            if (bytes.len != 8) return error.InvalidValue;
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            return .{ .float = @as(f64, @bitCast(bits)) };
        },
        oid.date => {
            if (bytes.len != 4) return error.InvalidValue;
            return .{ .date = .{ .days = std.mem.readInt(i32, bytes[0..4], .big) } };
        },
        oid.time, oid.timestamp, oid.timestamptz => {
            if (bytes.len != 8) return error.InvalidValue;
            const usec = std.mem.readInt(i64, bytes[0..8], .big);
            if (o == oid.time) return .{ .time = .{ .usec = usec } };
            if (o == oid.timestamp) return .{ .timestamp = .{ .usec = usec } };
            return .{ .timestamptz = .{ .usec = usec } };
        },
        oid.uuid => {
            if (bytes.len != 16) return error.InvalidValue;
            var out: [16]u8 = undefined;
            @memcpy(&out, bytes[0..16]);
            return .{ .uuid = out };
        },
        oid.bytea => {
            return .{ .bytea = arena.dupe(u8, bytes) catch return error.OutOfMemory };
        },
        else => return error.TypeMismatch,
    }
}

fn isArrayOid(o: u32) bool {
    return elemOidOfArray(o) != 0;
}

fn elemOidOfArray(o: u32) u32 {
    const pairs = [_][2]u32{
        .{ oid._bool, oid.bool_ },
        .{ oid._int2, oid.int2 },
        .{ oid._int4, oid.int4 },
        .{ oid._int8, oid.int8 },
        .{ oid._float4, oid.float4 },
        .{ oid._float8, oid.float8 },
        .{ oid._text, oid.text },
        .{ oid._varchar, oid.varchar },
        .{ oid._bpchar, oid.bpchar },
        .{ oid._numeric, oid.numeric },
        .{ oid._uuid, oid.uuid },
        .{ oid._bytea, oid.bytea },
        .{ oid._date, oid.date },
        .{ oid._time, oid.time },
        .{ oid._timestamp, oid.timestamp },
        .{ oid._timestamptz, oid.timestamptz },
        .{ oid._json, oid.json },
        .{ oid._jsonb, oid.jsonb },
        .{ oid._name, oid.name },
    };
    for (pairs) |p| if (p[0] == o) return p[1];
    return 0;
}

fn decodeDateText(bytes: []const u8) !Value {
    var y_end: usize = 4;
    while (y_end < bytes.len and bytes[y_end] != '-') y_end += 1;
    const y = try std.fmt.parseInt(i32, bytes[0..y_end], 10);
    if (bytes.len < y_end + 6) return error.InvalidValue;
    const m = try std.fmt.parseInt(u8, bytes[y_end + 1 .. y_end + 3], 10);
    const d = try std.fmt.parseInt(u8, bytes[y_end + 4 .. y_end + 6], 10);
    var days = daysFromCivil(y, m, d) - days_from_1970_to_2000;
    if (std.mem.endsWith(u8, bytes, " BC")) days = -days;
    return .{ .date = .{ .days = days } };
}

fn decodeTimeText(bytes: []const u8) !Value {
    if (bytes.len < 8 or bytes[2] != ':' or bytes[5] != ':') return error.InvalidValue;
    const h = try std.fmt.parseInt(i64, bytes[0..2], 10);
    const m = try std.fmt.parseInt(i64, bytes[3..5], 10);
    const s = try std.fmt.parseInt(i64, bytes[6..8], 10);
    if (h < 0 or h > 23 or m < 0 or m > 59 or s < 0 or s > 60) return error.InvalidValue;
    var total: i64 = ((h * 60 + m) * 60 + s) * std.time.us_per_s;
    var i: usize = 8;
    if (i < bytes.len and bytes[i] == '.') {
        i += 1;
        var frac: i64 = 0;
        var digits: usize = 0;
        while (i < bytes.len and std.ascii.isDigit(bytes[i])) : (i += 1) {
            if (digits < 6) frac = frac * 10 + (bytes[i] - '0');
            digits += 1;
        }
        while (digits < 6) : (digits += 1) frac *= 10;
        total += frac;
    }
    return .{ .time = .{ .usec = total } };
}

pub fn decodeTimestampText(bytes: []const u8, tz: bool) !Value {
    const sp = std.mem.indexOfScalar(u8, bytes, ' ') orelse return error.InvalidValue;
    const date_part = bytes[0..sp];
    var rest = bytes[sp + 1 ..];

    const date_val = try decodeDateText(date_part);
    const time_val = try decodeTimeText(rest);
    var usec: i64 = @as(i64, date_val.date.days) * 86_400 * std.time.us_per_s + time_val.time.usec;

    if (std.mem.indexOfScalar(u8, rest, '+') orelse std.mem.indexOfScalarPos(u8, rest, 8, '-')) |oi| {
        const sign: i64 = if (rest[oi] == '+') 1 else -1;
        const tz_str = rest[oi + 1 ..];
        const colon = std.mem.indexOfScalar(u8, tz_str, ':');
        const hh = try std.fmt.parseInt(i64, tz_str[0..@min(tz_str.len, if (colon) |c| c else 2)], 10);
        var mm: i64 = 0;
        if (colon) |c| {
            if (c + 3 <= tz_str.len) mm = try std.fmt.parseInt(i64, tz_str[c + 1 .. c + 3], 10);
        }
        usec -= sign * (hh * 60 + mm) * 60 * std.time.us_per_s;
    }
    _ = &rest;
    return if (tz) .{ .timestamptz = .{ .usec = usec } } else .{ .timestamp = .{ .usec = usec } };
}

/// Parse a PostgreSQL array literal: `{elem,elem}` (with `[lb:ub]=` prefix
/// skipped). Elements may be double-quoted with `"`/`\` escapes; `NULL`
/// (unquoted) is a null element. Never panics on hostile input.
pub fn parseArrayLiteral(arena: std.mem.Allocator, bytes: []const u8, elem_oid: u32) errors.Error![]const Value {
    var s = bytes;
    if (s.len >= 2 and s[0] == '[') {
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse return error.InvalidValue;
        s = s[eq + 1 ..];
    }
    if (s.len < 2 or s[0] != '{' or s[s.len - 1] != '}') return error.InvalidValue;
    const inner = s[1 .. s.len - 1];
    var out = std.ArrayList(Value).empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    var any = false;
    while (i < inner.len) {
        if (i > 0) {
            if (inner[i] != ',') return error.InvalidValue;
            i += 1;
        }
        if (i >= inner.len) break;
        var raw: []const u8 = undefined;
        var is_null = false;
        if (inner[i] == '"') {
            const qstart = i + 1;
            var j = qstart;
            var buf = std.ArrayList(u8).empty;
            errdefer buf.deinit(arena);
            while (j < inner.len) {
                if (inner[j] == '\\' and j + 1 < inner.len) {
                    try buf.append(arena, inner[j + 1]);
                    j += 2;
                } else if (inner[j] == '"') {
                    // "" inside a quoted element is a literal quote
                    if (j + 1 < inner.len and inner[j + 1] == '"') {
                        try buf.append(arena, '"');
                        j += 2;
                        continue;
                    }
                    break;
                } else {
                    try buf.append(arena, inner[j]);
                    j += 1;
                }
            }
            if (j >= inner.len) return error.InvalidValue;
            raw = buf.items;
            i = j + 1;
        } else {
            const cend = std.mem.indexOfScalarPos(u8, inner, i, ',') orelse inner.len;
            raw = inner[i..cend];
            i = cend;
            if (std.mem.eql(u8, raw, "NULL")) is_null = true;
        }
        any = true;
        if (is_null) {
            try out.append(arena, .null_);
        } else {
            const col = Column{ .name = "", .type_oid = elem_oid, .typlen = 0, .format = 0, .table_oid = 0, .attnum = 0 };
            try out.append(arena, try decodeText(arena, col, raw));
        }
    }
    if (!any and inner.len == 0) return &.{};
    return out.items;
}

pub fn coerce(comptime T: type, v: Value) errors.Error!T {
    switch (v) {
        .null_ => {
            const info = @typeInfo(T);
            if (info == .optional) return null;
            return error.TypeMismatch;
        },
        else => {},
    }
    return coerceNonNull(T, v);
}

fn coerceNonNull(comptime T: type, v: Value) errors.Error!T {
    switch (T) {
        bool => if (v == .bool_) return v.bool_ else return error.TypeMismatch,
        i16 => if (v == .int) return @intCast(v.int) else return error.TypeMismatch,
        i32 => if (v == .int) return @intCast(v.int) else return error.TypeMismatch,
        i64 => if (v == .int) return v.int else return error.TypeMismatch,
        u16, u32 => if (v == .int) {
            if (v.int < 0 or v.int > std.math.maxInt(T)) return error.TypeMismatch;
            return @intCast(v.int);
        } else return error.TypeMismatch,
        f32 => return switch (v) {
            .float => |f| @floatCast(f),
            .int => |i| @floatFromInt(i),
            else => error.TypeMismatch,
        },
        f64 => return switch (v) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => error.TypeMismatch,
        },
        []const u8 => return switch (v) {
            .text => |t| t,
            .bytea => |b| b,
            else => error.TypeMismatch,
        },
        Date => switch (v) {
            .date => |d| return d,
            .text => |t| return (decodeDateText(t) catch return error.InvalidValue).date,
            else => return error.TypeMismatch,
        },
        Time => switch (v) {
            .time => |t| return t,
            .text => |t| return (decodeTimeText(t) catch return error.InvalidValue).time,
            else => return error.TypeMismatch,
        },
        Timestamp => switch (v) {
            .timestamp => |t| return t,
            .timestamptz => |t| return t,
            .text => |t| return (decodeTimestampText(t, true) catch return error.InvalidValue).timestamptz,
            else => return error.TypeMismatch,
        },
        Interval => return error.TypeMismatch,
        [16]u8 => if (v == .uuid) return v.uuid else return error.TypeMismatch,
        else => {},
    }
    const info = @typeInfo(T);
    if (info == .optional) {
        return try coerceNonNull(info.optional.child, v);
    }
    if (info == .pointer and info.pointer.size == .slice) {
        if (v == .array) {
            const Elem = info.pointer.child;
            const out = std.heap.page_allocator.alloc(Elem, v.array.elems.len) catch return error.OutOfMemory;
            for (v.array.elems, 0..) |e, i| out[i] = try coerce(Elem, e);
            return out;
        }
        return error.TypeMismatch;
    }
    if (info == .@"enum") {
        if (v == .text) {
            return std.meta.stringToEnum(T, v.text) orelse error.TypeMismatch;
        }
        return error.TypeMismatch;
    }
    return error.TypeMismatch;
}
