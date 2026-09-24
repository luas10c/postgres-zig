const std = @import("std");
const types = @import("types.zig");
const errors = @import("error.zig");

pub const max_params: u32 = 65534;

pub const Seg = union(enum) {
    sql: []const u8,
    ph: u16,
};

fn comptimeIntDigits(comptime n: usize) []const u8 {
    comptime {
        var buf: [20]u8 = undefined;
        var i: usize = 0;
        var v = n;
        if (v == 0) return "0";
        while (v > 0) : (v /= 10) {
            buf[i] = @intCast('0' + v % 10);
            i += 1;
        }
        var out: [20]u8 = undefined;
        var o: usize = 0;
        while (o < i) : (o += 1) out[o] = buf[i - 1 - o];
        const res = out[0..i];
        return res;
    }
}

/// Comptime: count `{}` placeholders (honoring `{{`/`}}` escapes).
pub fn countPlaceholders(comptime q: []const u8) usize {
    comptime {
        @setEvalBranchQuota(20000);
        var n: usize = 0;
        var i: usize = 0;
        while (i < q.len) {
            if (q[i] == '{') {
                if (i + 1 < q.len and q[i + 1] == '{') {
                    i += 2;
                } else if (i + 1 < q.len and q[i + 1] == '}') {
                    n += 1;
                    i += 2;
                } else {
                    @compileError("unbalanced '{' in query (use {{ for a literal brace): " ++ q);
                }
            } else if (q[i] == '}') {
                if (i + 1 < q.len and q[i + 1] == '}') {
                    i += 2;
                } else {
                    @compileError("unbalanced '}' in query (use }} for a literal brace): " ++ q);
                }
            } else {
                i += 1;
            }
        }
        return n;
    }
}

/// Comptime: segments with UNESCAPED literal text (`{{` → `{`).
fn buildSegs(comptime q: []const u8) []const Seg {
    comptime {
        @setEvalBranchQuota(50000);
        const n = countPlaceholders(q);
        var segs: [n * 2 + 1]Seg = undefined;
        var si: usize = 0;
        var lit_buf: [q.len]u8 = undefined;
        var lit_len: usize = 0;
        var param: u16 = 0;
        var i: usize = 0;
        while (i < q.len) {
            if (q[i] == '{') {
                if (q[i + 1] == '{') {
                    lit_buf[lit_len] = '{';
                    lit_len += 1;
                    i += 2;
                    continue;
                }
                if (q[i + 1] == '}') {
                    if (lit_len > 0) {
                        var litc: [lit_len]u8 = undefined;
                        for (0..lit_len) |k| litc[k] = lit_buf[k];
                        const lit_const: [lit_len]u8 = litc;
                        segs[si] = .{ .sql = &lit_const };
                        si += 1;
                        lit_len = 0;
                    }
                    segs[si] = .{ .ph = param };
                    si += 1;
                    param += 1;
                    i += 2;
                    continue;
                }
                @compileError("unbalanced '{' in query");
            } else if (q[i] == '}') {
                if (q[i + 1] == '}') {
                    lit_buf[lit_len] = '}';
                    lit_len += 1;
                    i += 2;
                    continue;
                }
                @compileError("unbalanced '}' in query");
            } else {
                lit_buf[lit_len] = q[i];
                lit_len += 1;
                i += 1;
            }
        }
        if (lit_len > 0) {
            var litc: [lit_len]u8 = undefined;
            for (0..lit_len) |k| litc[k] = lit_buf[k];
            const lit_const: [lit_len]u8 = litc;
            segs[si] = .{ .sql = &lit_const };
            si += 1;
        }
        var out: [si]Seg = undefined;
        for (0..si) |k| out[k] = segs[k];
        const res: [si]Seg = out;
        return &res;
    }
}

/// Comptime segments for (query, args) with placeholder/arity validation.
pub fn segsFor(comptime q: []const u8, comptime Args: type) []const Seg {
    comptime {
        const n = countPlaceholders(q);
        if (n > max_params) @compileError("query exceeds 65534 parameters");
        const info = @typeInfo(Args);
        if (info != .@"struct") @compileError("query arguments must be a tuple");
        const fields = info.@"struct".fields;
        if (fields.len != n) {
            @compileError("query has " ++ comptimeIntDigits(n) ++
                " placeholder(s) but " ++ comptimeIntDigits(fields.len) ++
                " argument(s) were given: " ++ q);
        }
        return buildSegs(q);
    }
}

pub const ArgKind = enum { value, ident, raw, frag, value_list, insert, insert_many, update, cols };

fn hasPgDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, name),
        else => false,
    };
}

pub fn kindOf(comptime T: type) ArgKind {
    if (comptime hasPgDecl(T, "pg_ident")) return .ident;
    if (comptime hasPgDecl(T, "pg_raw")) return .raw;
    if (comptime hasPgDecl(T, "pg_frag")) return .frag;
    if (comptime hasPgDecl(T, "pg_value_list")) return .value_list;
    if (comptime hasPgDecl(T, "pg_insert_many")) return .insert_many;
    if (comptime hasPgDecl(T, "pg_insert")) return .insert;
    if (comptime hasPgDecl(T, "pg_update")) return .update;
    if (comptime hasPgDecl(T, "pg_cols")) return .cols;
    return .value;
}

pub fn allValues(comptime Args: type) bool {
    comptime {
        const fields = @typeInfo(Args).@"struct".fields;
        for (fields) |f| {
            if (kindOf(f.type) != .value) return false;
        }
        return true;
    }
}

/// Comptime final SQL with `$n` placeholders (fast path).
pub fn finalSql(comptime q: []const u8, comptime Args: type) []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var buf: [q.len + @typeInfo(Args).@"struct".fields.len * 8]u8 = undefined;
        var o: usize = 0;
        var param: usize = 0;
        var i: usize = 0;
        while (i < q.len) {
            if (q[i] == '{' and i + 1 < q.len and q[i + 1] == '{') {
                buf[o] = '{';
                o += 1;
                i += 2;
            } else if (q[i] == '}' and i + 1 < q.len and q[i + 1] == '}') {
                buf[o] = '}';
                o += 1;
                i += 2;
            } else if (q[i] == '{' and i + 1 < q.len and q[i + 1] == '}') {
                param += 1;
                buf[o] = '$';
                o += 1;
                const digits = comptimeIntDigits(param);
                for (digits) |c| {
                    buf[o] = c;
                    o += 1;
                }
                i += 2;
            } else {
                buf[o] = q[i];
                o += 1;
                i += 1;
            }
        }
        const fin: [o]u8 = buf[0..o].*;
        return &fin;
    }
}

pub fn fnv64Runtime(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= c;
        h = h *% 0x100000001b3;
    }
    return h;
}

pub fn stmtNameRuntime(sql: []const u8, out: *[20]u8) []const u8 {
    const h = fnv64Runtime(sql);
    const hex = "0123456789abcdef";
    out[0..4].* = "pgz_".*;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast(60 - 4 * i);
        out[4 + i] = hex[(h >> shift) & 0xF];
    }
    return out[0..20];
}

pub fn stmtName(comptime sql: []const u8) []const u8 {
    comptime {
        const h = fnv64Runtime(sql);
        const hex = "0123456789abcdef";
        var name: [20]u8 = undefined;
        name[0..4].* = "pgz_".*;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const shift: u6 = @intCast(60 - 4 * i);
            name[4 + i] = hex[(h >> shift) & 0xF];
        }
        const fin: [20]u8 = name;
        return &fin;
    }
}

/// NAMEDATALEN - 1
pub const max_ident_bytes = 63;

pub fn validateIdent(name: []const u8) errors.Error!void {
    if (name.len == 0) return error.InvalidIdent;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidIdent;
    }
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > max_ident_bytes) return error.InvalidIdent;
    }
}

/// Runtime-safe quoting: `"name"` with `"` doubled. Dotted names are split
/// (`schema.table` → `"schema"."table"`); use `pg.raw` for the rare case of
/// a literal dot inside a single identifier.
pub fn quoteIdentInto(out: []u8, name: []const u8) errors.Error![]const u8 {
    try validateIdent(name);
    var o: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    var first = true;
    while (it.next()) |part| {
        if (o + 1 + 2 + part.len * 2 + 1 > out.len) return error.InvalidIdent;
        if (!first) {
            out[o] = '.';
            o += 1;
        }
        first = false;
        out[o] = '"';
        o += 1;
        for (part) |c| {
            if (c == '"') {
                out[o] = '"';
                o += 1;
            }
            out[o] = c;
            o += 1;
        }
        out[o] = '"';
        o += 1;
    }
    return out[0..o];
}

/// Comptime identifier validation + quoting for literal column names
/// (insert/update/cols helpers). Compile error on invalid names — the
/// strict charset [A-Za-z0-9_$] applies because these are comptime-known.
pub fn comptimeQuoteIdent(comptime name: []const u8) []const u8 {
    comptime {
        if (name.len == 0) @compileError("empty identifier");
        if (name.len > max_ident_bytes) @compileError("identifier longer than 63 bytes: " ++ name);
        for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) {
                @compileError("invalid character '" ++ &[_]u8{c} ++ "' in identifier '" ++
                    name ++ "' (use pg.ident() for runtime identifiers)");
            }
        }
        var buf: [name.len * 2 + 3]u8 = undefined;
        var o: usize = 0;
        buf[o] = '"';
        o += 1;
        for (name) |c| {
            if (c == '"') {
                buf[o] = '"';
                o += 1;
            }
            buf[o] = c;
            o += 1;
        }
        buf[o] = '"';
        o += 1;
        const fin: [o]u8 = buf[0..o].*;
        return &fin;
    }
}

/// Quoted identifier (postgres.js `sql('name')`). Storage travels by
/// value inside the args tuple — never returns dangling pointers.
pub const Ident = struct {
    buf: [max_ident_bytes * 2 + 3]u8 = undefined,
    len: u16 = 0,

    pub const pg_ident = true;

    pub fn quoted(self: *const Ident) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn ident(name: []const u8) errors.Error!Ident {
    var out = Ident{};
    const q = try quoteIdentInto(&out.buf, name);
    out.len = @intCast(q.len);
    return out;
}

/// Verbatim SQL — the explicit, auditable escape hatch
/// (postgres.js nested `sql.unsafe`).
pub const Raw = struct {
    sql: []const u8,
    pub const pg_raw = true;
};
pub fn raw(sql: []const u8) Raw {
    return .{ .sql = sql };
}

/// Nested validated SQL fragment (postgres.js `` sql`...` ``).
/// The parsed segments live as a comptime decl (`Parts`) — zero runtime cost.
pub fn TypedFrag(comptime parts: []const Seg, comptime Args: type) type {
    return struct {
        args: Args,
        pub const pg_frag = true;
        pub const Parts = parts;
    };
}

pub fn frag(comptime q: []const u8, args: anytype) TypedFrag(segsFor(q, @TypeOf(args)), @TypeOf(args)) {
    return .{ .args = args };
}

pub const EmptyFrag = TypedFrag(&.{}, struct {});
pub fn fragEmpty() EmptyFrag {
    return .{ .args = .{} };
}

/// Value list for `WHERE x IN (...)` (postgres.js `sql([1,2,3])`).
pub fn TypedValueList(comptime T: type) type {
    return struct {
        elems: T,
        pub const pg_value_list = true;
    };
}
pub fn valueList(elems: anytype) TypedValueList(@TypeOf(elems)) {
    return .{ .elems = elems };
}

/// `insert into t ("a","b") values ($1,$2)` (postgres.js `sql(obj, 'a','b')`).
/// Pass `null` for `cols` to use all struct fields (postgres.js `sql(obj)`).
pub fn TypedInsert(comptime T: type, comptime colspec: anytype) type {
    return struct {
        obj: T,
        pub const pg_insert = true;
        pub const Cols = colspec;
    };
}
pub fn insert(obj: anytype, comptime colspec: anytype) TypedInsert(@TypeOf(obj), colspec) {
    return .{ .obj = obj };
}
pub fn insertAll(obj: anytype) TypedInsert(@TypeOf(obj), .{}) {
    return .{ .obj = obj };
}

/// Multi-row insert (postgres.js `sql(users, 'a','b')`).
pub fn TypedInsertMany(comptime T: type, comptime colspec: anytype) type {
    return struct {
        rows: []const T,
        pub const pg_insert_many = true;
        pub const Cols = colspec;
    };
}
pub fn insertMany(rows: anytype, comptime colspec: anytype) TypedInsertMany(rowElemType(rows), colspec) {
    return .{ .rows = rows };
}
fn rowElemType(rows: anytype) type {
    return @typeInfo(@TypeOf(rows)).pointer.child;
}

/// `update t set "a" = $1, "b" = $2` (postgres.js `sql(obj, cols)` in updates).
pub fn TypedUpdate(comptime T: type, comptime colspec: anytype) type {
    return struct {
        obj: T,
        pub const pg_update = true;
        pub const Cols = colspec;
    };
}
pub fn update(obj: anytype, comptime colspec: anytype) TypedUpdate(@TypeOf(obj), colspec) {
    return .{ .obj = obj };
}
pub fn updateAll(obj: anytype) TypedUpdate(@TypeOf(obj), .{}) {
    return .{ .obj = obj };
}

/// `"a", "b"` select list (postgres.js `sql(['a','b'])`).
pub fn TypedCols(comptime colspec: anytype) type {
    return struct {
        pub const pg_cols = true;
        pub const Cols = colspec;
    };
}
pub fn cols(comptime c: anytype) TypedCols(c) {
    return .{};
}

/// `colspec` is a comptime tuple of column names; an EMPTY tuple means
/// "all fields of the object type".
fn colCount(comptime colspec: anytype, comptime Obj: type) usize {
    if (comptime colspec.len == 0) return @typeInfo(Obj).@"struct".fields.len;
    return @typeInfo(@TypeOf(colspec)).@"struct".fields.len;
}

fn colName(comptime colspec: anytype, comptime Obj: type, comptime i: usize) []const u8 {
    if (comptime colspec.len == 0) return @typeInfo(Obj).@"struct".fields[i].name;
    return colspec[i];
}

pub const RenderCtx = struct {
    gpa: std.mem.Allocator,
    sql: *std.ArrayList(u8),
    encs: *std.ArrayList(types.Enc),
    scratch: *std.ArrayList(u8),
    param_count: u32 = 0,

    fn nextParam(self: *RenderCtx) errors.Error!u32 {
        self.param_count += 1;
        if (self.param_count > max_params) return error.StatementTooLarge;
        return self.param_count;
    }

    fn appendParamRef(self: *RenderCtx) errors.Error!void {
        var tmp: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "${d}", .{self.param_count}) catch return error.Unexpected;
        try self.sql.appendSlice(self.gpa, s);
    }

    fn encodeCtx(self: *RenderCtx) types.EncodeCtx {
        return .{ .encs = self.encs, .scratch = self.scratch, .gpa = self.gpa };
    }
};

/// Render a query + arguments into SQL text + encoded parameters.
pub fn renderQuery(ctx: *RenderCtx, comptime q: []const u8, args: anytype) errors.Error!void {
    comptime _ = segsFor(q, @TypeOf(args));

    if (comptime allValues(@TypeOf(args))) {
        try ctx.sql.appendSlice(ctx.gpa, comptime finalSql(q, @TypeOf(args)));
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        inline for (fields) |f| {
            _ = try ctx.nextParam();
            var ectx = ctx.encodeCtx();
            try types.encodeParam(&ectx, @field(args, f.name));
        }
    } else {
        try renderSegs(ctx, comptime segsFor(q, @TypeOf(args)), args);
    }
}

fn renderSegs(ctx: *RenderCtx, comptime segs: []const Seg, args: anytype) errors.Error!void {
    inline for (segs) |seg| {
        switch (seg) {
            .sql => |s| try ctx.sql.appendSlice(ctx.gpa, s),
            .ph => |idx| try renderArg(ctx, args[idx]),
        }
    }
}

fn renderArg(ctx: *RenderCtx, arg: anytype) errors.Error!void {
    const T = @TypeOf(arg);
    const kind = comptime kindOf(T);
    switch (kind) {
        .value => {
            _ = try ctx.nextParam();
            try ctx.appendParamRef();
            var ectx = ctx.encodeCtx();
            try types.encodeParam(&ectx, arg);
        },
        .ident => try ctx.sql.appendSlice(ctx.gpa, arg.quoted()),
        .raw => try ctx.sql.appendSlice(ctx.gpa, arg.sql),
        .frag => try renderSegs(ctx, T.Parts, arg.args),
        .value_list => {
            try ctx.sql.append(ctx.gpa, '(');
            const E = @TypeOf(arg.elems);
            switch (@typeInfo(E)) {
                .@"struct" => {
                    const fields = @typeInfo(E).@"struct".fields;
                    inline for (fields, 0..) |_, i| {
                        if (i != 0) try ctx.sql.append(ctx.gpa, ',');
                        _ = try ctx.nextParam();
                        try ctx.appendParamRef();
                        var ectx = ctx.encodeCtx();
                        try types.encodeParam(&ectx, arg.elems[i]);
                    }
                },
                .pointer => |p| {
                    if (p.size != .slice) @compileError("valueList expects a tuple or slice");
                    var first = true;
                    for (arg.elems) |e| {
                        if (!first) try ctx.sql.append(ctx.gpa, ',');
                        first = false;
                        _ = try ctx.nextParam();
                        try ctx.appendParamRef();
                        var ectx = ctx.encodeCtx();
                        try types.encodeParam(&ectx, e);
                    }
                },
                else => @compileError("valueList expects a tuple or slice"),
            }
            try ctx.sql.append(ctx.gpa, ')');
        },
        .insert => {
            const Obj = @TypeOf(arg.obj);
            const Cols = T.Cols;
            try ctx.sql.append(ctx.gpa, '(');
            inline for (0..comptime colCount(Cols, Obj)) |i| {
                if (i != 0) try ctx.sql.append(ctx.gpa, ',');
                try ctx.sql.appendSlice(ctx.gpa, comptime comptimeQuoteIdent(colName(Cols, Obj, i)));
            }
            try ctx.sql.appendSlice(ctx.gpa, ") values (");
            inline for (0..comptime colCount(Cols, Obj)) |i| {
                if (i != 0) try ctx.sql.append(ctx.gpa, ',');
                _ = try ctx.nextParam();
                try ctx.appendParamRef();
                const name = comptime colName(Cols, Obj, i);
                var ectx = ctx.encodeCtx();
                try types.encodeParam(&ectx, fieldByComptimeName(arg.obj, name));
            }
            try ctx.sql.append(ctx.gpa, ')');
        },
        .insert_many => {
            const Row = @typeInfo(@TypeOf(arg.rows)).pointer.child;
            const Cols = T.Cols;
            try ctx.sql.append(ctx.gpa, '(');
            inline for (0..comptime colCount(Cols, Row)) |i| {
                if (i != 0) try ctx.sql.append(ctx.gpa, ',');
                try ctx.sql.appendSlice(ctx.gpa, comptime comptimeQuoteIdent(colName(Cols, Row, i)));
            }
            try ctx.sql.appendSlice(ctx.gpa, ") values ");
            for (arg.rows, 0..) |row, ri| {
                if (ri != 0) try ctx.sql.append(ctx.gpa, ',');
                try ctx.sql.append(ctx.gpa, '(');
                inline for (0..comptime colCount(Cols, Row)) |i| {
                    if (i != 0) try ctx.sql.append(ctx.gpa, ',');
                    _ = try ctx.nextParam();
                    try ctx.appendParamRef();
                    const name = comptime colName(Cols, Row, i);
                    var ectx = ctx.encodeCtx();
                    try types.encodeParam(&ectx, fieldByComptimeName(row, name));
                }
                try ctx.sql.append(ctx.gpa, ')');
            }
        },
        .update => {
            const Obj = @TypeOf(arg.obj);
            const Cols = T.Cols;
            inline for (0..comptime colCount(Cols, Obj)) |i| {
                if (i != 0) try ctx.sql.appendSlice(ctx.gpa, ", ");
                try ctx.sql.appendSlice(ctx.gpa, comptime comptimeQuoteIdent(colName(Cols, Obj, i)));
                try ctx.sql.appendSlice(ctx.gpa, " = ");
                _ = try ctx.nextParam();
                try ctx.appendParamRef();
                const name = comptime colName(Cols, Obj, i);
                var ectx = ctx.encodeCtx();
                try types.encodeParam(&ectx, fieldByComptimeName(arg.obj, name));
            }
        },
        .cols => {
            inline for (0..comptime colCount(T.Cols, struct {})) |i| {
                if (i != 0) try ctx.sql.appendSlice(ctx.gpa, ", ");
                try ctx.sql.appendSlice(ctx.gpa, comptime comptimeQuoteIdent(T.Cols[i]));
            }
        },
    }
}

fn fieldByComptimeName(obj: anytype, comptime name: []const u8) @FieldType(@TypeOf(obj), name) {
    return @field(obj, name);
}

const testing = std.testing;

fn renderToBuf(alloc: std.mem.Allocator, comptime q: []const u8, args: anytype) ![]u8 {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    var encs: std.ArrayList(types.Enc) = .empty;
    defer encs.deinit(alloc);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(alloc);
    var ctx = RenderCtx{ .gpa = alloc, .sql = &sql, .encs = &encs, .scratch = &scratch };
    try renderQuery(&ctx, q, args);
    return sql.toOwnedSlice(alloc);
}

test "final sql comptime" {
    const Args = struct { i64, []const u8 };
    const sql = comptime finalSql("select * from t where a = {} and b = {}", Args);
    try testing.expectEqualStrings("select * from t where a = $1 and b = $2", sql);

    const esc = comptime finalSql("select '{{a,b}}'::text[] where a = {}", struct { "y" });
    try testing.expectEqualStrings("select '{a,b}'::text[] where a = $1", esc);
}

test "segments unescape braces" {
    const segs = comptime segsFor("select '{{a}}' {}", struct { i32 });
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(testing.allocator);
    for (segs) |s| switch (s) {
        .sql => |t| try combined.appendSlice(testing.allocator, t),
        .ph => try combined.appendSlice(testing.allocator, "<PH>"),
    };
    try testing.expectEqualStrings("select '{a}' <PH>", combined.items);
}

test "ident quoting adversarial" {
    try testing.expectError(error.InvalidIdent, ident("users; drop table x"));
    try testing.expectError(error.InvalidIdent, ident(""));
    try testing.expectError(error.InvalidIdent, ident("a\x00b"));

    const ok = try ident("users");
    try testing.expectEqualStrings("\"users\"", ok.quoted());

    var buf: [200]u8 = undefined;
    const q = try quoteIdentInto(&buf, "we\"ird");
    try testing.expectEqualStrings("\"we\"\"ird\"", q);

    var long: [64]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(error.InvalidIdent, ident(&long));
}

test "stmtName runtime matches comptime" {
    var buf: [20]u8 = undefined;
    const rt = stmtNameRuntime("select 1", &buf);
    const ct = comptime stmtName("select 1");
    try testing.expectEqualStrings(ct, rt);
    try testing.expectEqualStrings("pgz_", ct[0..4]);
}

test "render fast path" {
    const sql = try renderToBuf(testing.allocator, "select * from users where age > {} and name = {}", .{ 18, "Mur" });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("select * from users where age > $1 and name = $2", sql);
}

test "render dynamic: ident, frag, valueList, cols, insert, update" {
    const table = try ident("users");
    const cond = frag("and age > {}", .{50});
    const inlist = valueList(.{ 68, 75, 23 });
    const c = cols(.{ "name", "age" });

    const sql = try renderToBuf(
        testing.allocator,
        "select {} from {} where 1=1 {} and age in {}",
        .{ c, table, cond, inlist },
    );
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "select \"name\", \"age\" from \"users\" where 1=1 and age > $1 and age in ($2, $3, $4)",
        sql,
    );

    const User = struct { name: []const u8, age: i32 };
    const ins = insert(User{ .name = "Murray", .age = 68 }, .{ "name", "age" });
    const sql2 = try renderToBuf(testing.allocator, "insert into users {}", .{ins});
    defer testing.allocator.free(sql2);
    try testing.expectEqualStrings("insert into users (\"name\", \"age\") values ($1, $2)", sql2);

    const ins_all = insertAll(User{ .name = "Murray", .age = 68 });
    const sql2b = try renderToBuf(testing.allocator, "insert into users {}", .{ins_all});
    defer testing.allocator.free(sql2b);
    try testing.expectEqualStrings("insert into users (\"name\", \"age\") values ($1, $2)", sql2b);

    const rows = [_]User{ .{ .name = "Walter", .age = 80 }, .{ .name = "Bo", .age = 4 } };
    const many = insertMany(&rows, .{ "name", "age" });
    const sql3 = try renderToBuf(testing.allocator, "insert into users {}", .{many});
    defer testing.allocator.free(sql3);
    try testing.expectEqualStrings(
        "insert into users (\"name\", \"age\") values ($1, $2), ($3, $4)",
        sql3,
    );

    const upd = update(User{ .name = "M", .age = 1 }, .{"age"});
    const sql4 = try renderToBuf(testing.allocator, "update users set {} where id = {}", .{ upd, @as(i64, 5) });
    defer testing.allocator.free(sql4);
    try testing.expectEqualStrings("update users set \"age\" = $1 where id = $2", sql4);
}

test "nested frags renumber params" {
    const inner = frag("age = {}", .{30});
    const outer = frag("name = {} or {}", .{ "x", inner });
    const sql = try renderToBuf(testing.allocator, "select 1 where {}", .{outer});
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("select 1 where name = $1 or age = $2", sql);
}
