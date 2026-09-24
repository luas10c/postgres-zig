const std = @import("std");
const errors = @import("error.zig");
const options = @import("options.zig");
const conn_mod = @import("connection.zig");
const pool_mod = @import("pool.zig");
const result_mod = @import("result.zig");
const qb = @import("query.zig");
const types = @import("types.zig");

const Conn = conn_mod.Conn;
const Result = result_mod.Result;
const Row = result_mod.Row;
const Describe = result_mod.Describe;
const Column = types.Column;
const Value = types.Value;

pub const QueryOptions = struct {
    /// Per-query timeout (watchdog → CancelRequest at the deadline).
    timeout_ns: ?u64 = null,
    prepare: ?bool = null,
    raw_results: bool = false,
};

pub const UnsafeOptions = struct {
    /// postgres.js parity: prepared statements off by default in unsafe.
    prepare: bool = false,
};

pub const EndOptions = struct {
    timeout_ns: ?u64 = null,
};

pub fn connect(io: std.Io, gpa: std.mem.Allocator, opts: options.Options) errors.Error!*Postgres {
    const p = gpa.create(Postgres) catch return error.OutOfMemory;
    errdefer gpa.destroy(p);
    p.* = .{
        .gpa = gpa,
        .io = io,
        .resolved = try options.resolve(gpa, opts),
        .diag_arena = std.heap.ArenaAllocator.init(gpa),
    };
    errdefer p.resolved.deinit();
    p.conn_ctx = .{
        .gpa = gpa,
        .io = io,
        .resolved = &p.resolved,
        .tls = &p.tls_ctx,
        .on_notice = opts.on_notice,
        .on_notice_data = opts.on_notice_data,
        .on_parameter = opts.on_parameter,
        .on_parameter_data = opts.on_parameter_data,
        .allow_insecure_auth = opts.allow_insecure_auth,
        .max_message_bytes = opts.max_message_bytes,
        .max_result_bytes = opts.max_result_bytes,
    };
    p.pool = pool_mod.Pool.init(gpa, io, &p.conn_ctx);
    p.transform = opts.transform_column;
    p.deny_unsafe = opts.deny_unsafe;
    p.on_unsafe = opts.on_unsafe;
    p.on_unsafe_data = opts.on_unsafe_data;
    p.prepare_default = opts.prepare;
    p.query_timeout_default = opts.query_timeout;
    p.max_result_bytes = opts.max_result_bytes;
    return p;
}

pub const Postgres = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    resolved: options.Resolved,
    tls_ctx: conn_mod.TlsCtx = .{},
    conn_ctx: conn_mod.ConnCtx = undefined,
    pool: pool_mod.Pool = undefined,

    transform: options.ColumnTransform = .none,
    deny_unsafe: bool = false,
    on_unsafe: ?options.UnsafeHook = null,
    on_unsafe_data: ?*anyopaque = null,
    prepare_default: bool = true,
    query_timeout_default: ?u64 = null,
    max_result_bytes: usize = std.math.maxInt(usize),

    diag_arena: std.heap.ArenaAllocator,
    diag_mutex: std.Io.Mutex = .init,
    last_diag: errors.Diagnostics = .{},

    pub fn deinit(self: *Postgres) void {
        self.pool.end(null) catch {};
        self.pool.deinit();
        self.tls_ctx.bundle.deinit(self.gpa);
        self.diag_arena.deinit();
        self.resolved.deinit();
        self.gpa.destroy(self);
    }

    /// `sql.end({timeout})` — reject new queries, wait, then force.
    pub fn end(self: *Postgres, o: EndOptions) errors.Error!void {
        return self.pool.end(o.timeout_ns);
    }

    /// `sql.close()` — immediate teardown.
    pub fn close(self: *Postgres) void {
        self.deinit();
    }

    pub fn lastDiagnostics(self: *Postgres) errors.Diagnostics {
        self.diag_mutex.lockUncancelable(self.io);
        defer self.diag_mutex.unlock(self.io);
        return self.last_diag;
    }

    fn recordDiag(self: *Postgres, c: *Conn) void {
        self.diag_mutex.lockUncancelable(self.io);
        defer self.diag_mutex.unlock(self.io);
        _ = self.diag_arena.reset(.retain_capacity);
        self.last_diag = c.copyDiagnostics(self.diag_arena.allocator());
    }

    fn returnConn(self: *Postgres, c: *Conn, err: ?errors.Error) void {
        if (err) |e| {
            self.recordDiag(c);
            if (e == error.PgError) {
                c.drainToReady() catch {
                    self.pool.discard(c);
                    return;
                };
                self.pool.release(c);
            } else {
                self.pool.discard(c);
            }
        } else {
            self.pool.release(c);
        }
    }

    /// Main API (tagged-template equivalent):
    /// `db.query("select ... where id = {}", .{id})`
    pub fn query(self: *Postgres, comptime q: []const u8, args: anytype) errors.Error!Result {
        return self.queryOpts(q, args, .{});
    }

    pub fn queryOpts(self: *Postgres, comptime q: []const u8, args: anytype, o: QueryOptions) errors.Error!Result {
        const c = try self.pool.acquire();
        var res = Result{
            .arena_state = std.heap.ArenaAllocator.init(self.gpa),
            .transform = self.transform,
        };
        var exec_err: ?errors.Error = null;
        {
            var sink = conn_mod.RowsSink{
                .gpa = self.gpa,
                .arena = res.arena(),
                .max_bytes = self.max_result_bytes,
            };

            const eo = conn_mod.Conn.ExecOptions{
                .sink = .{ .rows = &sink },
                .prepare = if (o.prepare) |p| p else self.prepare_default,
                .raw_results = o.raw_results,
            };
            exec_err = self.execTimed(c, q, args, eo, o.timeout_ns orelse self.query_timeout_default);

            if (exec_err == null) {
                self.fillResult(c, &sink, &res) catch |e| {
                    exec_err = e;
                };
            }
        }
        self.returnConn(c, exec_err);
        if (exec_err) |e| {
            res.deinit();
            return e;
        }
        return res;
    }

    fn execTimed(
        self: *Postgres,
        c: *Conn,
        comptime q: []const u8,
        args: anytype,
        eo: conn_mod.Conn.ExecOptions,
        timeout_ns: ?u64,
    ) ?errors.Error {
        const t = timeout_ns orelse {
            c.execQuery(q, args, eo) catch |e| return e;
            return null;
        };
        var wd = Watchdog{
            .conn_ctx = &self.conn_ctx,
            .io = self.io,
            .host_idx = c.host_idx,
            .pid = c.pid,
            .secret = c.secret,
            .deadline_ns = @as(i128, std.Io.Timestamp.now(self.io, .real).nanoseconds) + @as(i128, @intCast(t)),
        };
        const th = std.Thread.spawn(.{}, Watchdog.run, .{&wd}) catch return error.Unexpected;
        var exec_err: ?errors.Error = null;
        c.execQuery(q, args, eo) catch |e| {
            exec_err = e;
        };
        wd.done.store(true, .seq_cst);
        th.join();
        if (exec_err) |e| return e;
        if (wd.fired and c.diagnostics.isQueryCanceled()) return error.Timeout;
        return null;
    }

    /// Sink lists are arena-backed: ownership moves to the Result, so the
    /// list lengths are zeroed by hand — `clearRetainingCapacity` would memset
    /// the memory the Result now points to.
    fn fillResult(self: *Postgres, c: *Conn, sink: *conn_mod.RowsSink, res: *Result) errors.Error!void {
        _ = self;
        const a = res.arena();
        res.columns = sink.columns.items;
        sink.columns.items.len = 0;
        const values = sink.rows.items;
        const rows = a.alloc(Row, values.len) catch return error.OutOfMemory;
        for (values, 0..) |vals, i| {
            rows[i] = .{ .values = vals, .columns = res.columns };
        }
        sink.rows.items.len = 0;
        res.rows = rows;
        res.count = sink.count;
        res.command_tag = a.dupe(u8, sink.command_tag) catch return error.OutOfMemory;
        res.state = .{ .pid = c.pid, .secret = c.secret };
    }

    /// Simple protocol — multiple statements, no parameters (`` sql``.simple() ``).
    pub fn simple(self: *Postgres, sql: []const u8) errors.Error!Result {
        const c = try self.pool.acquire();
        var res = Result{ .arena_state = std.heap.ArenaAllocator.init(self.gpa), .transform = self.transform };
        var exec_err: ?errors.Error = null;
        {
            var sink = conn_mod.RowsSink{ .gpa = self.gpa, .arena = res.arena(), .max_bytes = self.max_result_bytes };
            c.execSimple(sql, .{ .sink = .{ .rows = &sink } }) catch |e| {
                exec_err = e;
            };
            if (exec_err == null) {
                self.fillResult(c, &sink, &res) catch |e| {
                    exec_err = e;
                };
            }
        }
        self.returnConn(c, exec_err);
        if (exec_err) |e| {
            res.deinit();
            return e;
        }
        return res;
    }

    /// `sql.unsafe(query, args)` — raw SQL with positional `$1...` params.
    /// Without parameters it uses the simple protocol (multiple statements
    /// allowed — same as postgres.js). Explicitly dangerous by design;
    /// gated by `deny_unsafe` / audited via `on_unsafe`.
    pub fn unsafe(self: *Postgres, sql: []const u8, args: anytype, o: UnsafeOptions) errors.Error!Result {
        if (self.deny_unsafe) return error.UnsafeDenied;
        if (self.on_unsafe) |hook| {
            hook(self.on_unsafe_data, sql) catch return error.UnsafeDenied;
        }

        const c = try self.pool.acquire();
        var res = Result{ .arena_state = std.heap.ArenaAllocator.init(self.gpa), .transform = self.transform };
        var exec_err: ?errors.Error = null;
        {
            var sink = conn_mod.RowsSink{ .gpa = self.gpa, .arena = res.arena(), .max_bytes = self.max_result_bytes };

            const has_args = blk: {
                const info = @typeInfo(@TypeOf(args));
                if (info != .@"struct") break :blk false;
                break :blk info.@"struct".fields.len > 0;
            };

            if (has_args) {
                c.encodePositional(args) catch |e| {
                    exec_err = e;
                };
                if (exec_err == null) {
                    const name: []const u8 = if (o.prepare) qb.stmtNameRuntime(sql, &c.name_buf) else "";
                    c.execExtended(sql, name, .{ .sink = .{ .rows = &sink }, .prepare = o.prepare }) catch |e| {
                        exec_err = e;
                    };
                }
            } else {
                c.execSimple(sql, .{ .sink = .{ .rows = &sink } }) catch |e| {
                    exec_err = e;
                };
            }
            if (exec_err == null) {
                self.fillResult(c, &sink, &res) catch |e| {
                    exec_err = e;
                };
            }
        }
        self.returnConn(c, exec_err);
        if (exec_err) |e| {
            res.deinit();
            return e;
        }
        return res;
    }

    /// `sql.file(path, args)` — run a (trusted) SQL file with `$1...` params.
    pub fn file(self: *Postgres, path: []const u8, args: anytype, o: UnsafeOptions) errors.Error!Result {
        const sql_text = std.fs.cwd().readFileAlloc(self.gpa, path, 16 * 1024 * 1024) catch return error.InvalidQuery;
        defer self.gpa.free(sql_text);
        return self.unsafe(sql_text, args, o);
    }

    /// `` sql``.describe() `` — final SQL, parameter OIDs and columns.
    pub fn describe(self: *Postgres, comptime q: []const u8, args: anytype) errors.Error!Describe {
        const c = try self.pool.acquire();
        var desc = Describe{ .arena_state = std.heap.ArenaAllocator.init(self.gpa) };
        var exec_err: ?errors.Error = null;
        {
            var sink = conn_mod.RowsSink{ .gpa = self.gpa, .arena = desc.arena_state.allocator(), .max_bytes = self.max_result_bytes };

            var param_oids: std.ArrayList(u32) = .empty;
            defer param_oids.deinit(self.gpa);

            const sql = try c.renderQueryArgs(q, args);
            const Args = @TypeOf(args);
            const name: []const u8 = if (comptime qb.allValues(Args))
                comptime qb.stmtName(qb.finalSql(q, Args))
            else
                qb.stmtNameRuntime(sql, &c.name_buf);

            c.execExtended(sql, name, .{
                .no_execute = true,
                .sink = .{ .rows = &sink },
                .param_oids_out = &param_oids,
            }) catch |e| {
                exec_err = e;
            };
            if (exec_err == null) {
                const a = desc.arena_state.allocator();
                desc.sql = a.dupe(u8, sql) catch return error.OutOfMemory;
                desc.columns = sink.columns.items;
                sink.columns.items.len = 0;
                desc.param_oids = a.dupe(u32, param_oids.items) catch return error.OutOfMemory;
                desc.statement_name = a.dupe(u8, name) catch return error.OutOfMemory;
            }
        }
        self.returnConn(c, exec_err);
        if (exec_err) |e| {
            desc.deinit();
            return e;
        }
        return desc;
    }

    /// Stream rows through a callback without materializing a Result
    /// (`` sql``.forEach(fn) `` parity — rows decoded straight from the socket).
    pub fn forEach(self: *Postgres, ctx: anytype, comptime cb: anytype, comptime q: []const u8, args: anytype) errors.Error!void {
        const conn = try self.pool.acquire();
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();

        // Column metadata must outlive the per-row arena resets below.
        var columns_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer columns_arena_state.deinit();

        const Ctx = @TypeOf(ctx);
        var ctx_var = ctx;
        const Wrap = struct {
            fn call(wctx: ?*anyopaque, cols: []const Column, vals: []const Value) errors.Error!void {
                const user_ctx: *Ctx = @ptrCast(@alignCast(wctx.?));
                return cb(user_ctx.*, .{ .values = vals, .columns = cols });
            }
        };

        var sink = conn_mod.StreamSink{
            .gpa = self.gpa,
            .ctx = @ptrCast(&ctx_var),
            .cb = Wrap.call,
            .row_arena = &row_arena,
            .columns_arena = columns_arena_state.allocator(),
        };

        const eo = conn_mod.Conn.ExecOptions{ .sink = .{ .stream = &sink } };
        var exec_err: ?errors.Error = null;
        if (self.query_timeout_default) |t| {
            exec_err = self.execTimed(conn, q, args, eo, t);
        } else {
            conn.execQuery(q, args, eo) catch |e| {
                exec_err = e;
            };
        }
        self.returnConn(conn, exec_err);
        if (exec_err) |e| return e;
    }

    /// Execute several queries in ONE round-trip (improvement over the
    /// postgres.js array-return trick, which only works inside transactions).
    /// `db.pipeline(.{ .{ "insert into a values ({})", .{1} }, .{ "select 1", .{} } })`
    pub fn pipeline(self: *Postgres, queries: anytype) errors.Error![]Result {
        const c = try self.pool.acquire();
        var exec_err: ?errors.Error = null;
        var results: []Result = &.{};
        if (self.pipelineOn(c, queries)) |r| {
            results = r;
        } else |e| {
            exec_err = e;
        }
        self.returnConn(c, exec_err);
        if (exec_err) |e| {
            for (results) |*r| r.deinit();
            if (results.len > 0) self.gpa.free(results);
            return e;
        }
        return results;
    }

    fn pipelineOn(self: *Postgres, c: *Conn, queries: anytype) errors.Error![]Result {
        var stage = std.heap.ArenaAllocator.init(self.gpa);
        defer stage.deinit();
        const sa = stage.allocator();

        const n = queries.len;
        const StageItem = struct { sql: []const u8, name: []const u8, encs: []const types.Enc, oids: []const u32 };
        const staged = sa.alloc(StageItem, n) catch return error.OutOfMemory;

        inline for (queries, 0..) |item, i| {
            const qsql = item[0];
            const qargs = item[1];
            const Args = @TypeOf(qargs);
            const sql = try c.renderQueryArgs(qsql, qargs);

            const sql_copy = sa.dupe(u8, sql) catch return error.OutOfMemory;
            const encs_src = c.encs_buf.items;
            const encs_copy = sa.alloc(types.Enc, encs_src.len) catch return error.OutOfMemory;
            const oids_copy = sa.alloc(u32, encs_src.len) catch return error.OutOfMemory;
            const scratch_start = c.scratch.items.ptr;
            for (encs_src, 0..) |e, k| {
                encs_copy[k] = e;
                oids_copy[k] = e.oid;
                const p_int = @intFromPtr(e.bytes.ptr);
                if (e.bytes.len > 0 and p_int >= @intFromPtr(scratch_start) and
                    p_int + e.bytes.len <= @intFromPtr(scratch_start) + c.scratch.items.len)
                {
                    encs_copy[k].bytes = sa.dupe(u8, e.bytes) catch return error.OutOfMemory;
                }
            }
            const name: []const u8 = if (comptime qb.allValues(Args))
                comptime qb.stmtName(qb.finalSql(qsql, Args))
            else
                qb.stmtNameRuntime(sql_copy, &c.name_buf);
            staged[i] = .{ .sql = sql_copy, .name = name, .encs = encs_copy, .oids = oids_copy };
        }

        const cached_flags = sa.alloc(bool, n) catch return error.OutOfMemory;
        for (staged, 0..) |it, i| {
            cached_flags[i] = c.cacheHas(it.name, it.oids);
            if (!cached_flags[i]) {
                try c.writeParse(it.name, it.sql, it.oids);
            }
            try c.writeDescribeStatement(it.name);
            const result_oids: ?[]const u32 = if (cached_flags[i]) c.cachedResultOids(it.name, it.oids) else null;
            try c.writeBind(it.name, it.encs, result_oids);
            try c.writeExecute(0);
        }
        try c.writeSyncMessage();
        try c.flushOut();

        const results = self.gpa.alloc(Result, n) catch return error.OutOfMemory;
        var got: usize = 0;
        errdefer {
            for (results[0..got]) |*r| r.deinit();
            self.gpa.free(results);
        }
        for (staged, 0..) |it, i| {
            results[i] = .{ .arena_state = std.heap.ArenaAllocator.init(self.gpa), .transform = self.transform };
            var sink = conn_mod.RowsSink{
                .gpa = self.gpa,
                .arena = results[i].arena(),
                .max_bytes = self.max_result_bytes,
                .columns = .empty,
                .rows = .empty,
            };
            var eo = conn_mod.Conn.ExecOptions{ .sink = .{ .rows = &sink } };
            if (cached_flags[i]) {
                if (c.cachedResultOids(it.name, it.oids)) |roids| eo.result_formats = c.resultFormatsFor(roids);
            }
            try c.readStatement(eo);
            try self.fillResult(c, &sink, &results[i]);
            if (!cached_flags[i]) c.cacheRecord(it.name, it.oids);
            results[i].statement_name = results[i].arena().dupe(u8, it.name) catch return error.OutOfMemory;
            got = i + 1;
        }
        const ready = try c.readMessage();
        if (ready.tag != conn_mod.back.ready_for_query) return error.ProtocolError;
        c.tx_status = ready.data[0];
        return results;
    }

    /// `sql.begin(options)` — reserves a connection for the transaction.
    /// RAII idiom: `errdefer tx.rollback() catch {};`
    pub fn begin(self: *Postgres, opts: []const u8) errors.Error!Tx {
        const c = try self.pool.acquire();
        var buf: [128]u8 = undefined;
        const sql = if (opts.len == 0)
            "BEGIN"
        else
            std.fmt.bufPrint(&buf, "BEGIN {s}", .{opts}) catch return error.InvalidQuery;
        c.execSimple(sql, .{}) catch |e| {
            self.recordDiag(c);
            c.drainToReady() catch {
                self.pool.discard(c);
                return e;
            };
            self.pool.discard(c);
            return e;
        };
        return .{ .pg = self, .conn = c };
    }

    /// Callback-style: `db.beginFn(ctx, fn(ctx, tx) !T) !T` — commits on
    /// success, rolls back on error (postgres.js `sql.begin(fn)`).
    pub fn beginFn(self: *Postgres, ctx: anytype, comptime func: anytype) anyerror!BeginRet(func) {
        var tx = try self.begin("");
        errdefer if (!tx.finished) tx.rollback() catch {};
        const value = try func(ctx, &tx);
        try tx.commit();
        return value;
    }

    fn BeginRet(comptime func: anytype) type {
        const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        return @typeInfo(Ret).error_union.payload;
    }

    /// `sql.reserve()` — dedicated connection (postgres.js parity).
    pub fn reserve(self: *Postgres) errors.Error!Reserved {
        const c = try self.pool.acquire();
        return .{ .pg = self, .conn = c };
    }

    /// `` sql``.cursor(batch) `` — portal-based, throttled row batches.
    /// The first batch is fetched eagerly; `next()` returns it, then
    /// subsequent batches. Rows are borrowed (valid until the next call).
    pub fn cursor(self: *Postgres, batch: u32, comptime q: []const u8, args: anytype) errors.Error!Cursor {
        const c = try self.pool.acquire();
        var cur = Cursor{
            .pg = self,
            .conn = c,
            .batch = if (batch == 0) 1 else batch,
            .batch_arena = std.heap.ArenaAllocator.init(self.gpa),
        };
        cur.pending = .{
            .gpa = self.gpa,
            .arena = cur.batch_arena.allocator(),
            .columns = .empty,
            .rows = .empty,
        };
        var suspended = false;
        c.execQuery(q, args, .{
            .use_sync = false,
            .rows_limit = cur.batch,
            .sink = .{ .rows = &cur.pending },
            .suspended = &suspended,
            .no_sync_terminator = true,
        }) catch |e| {
            self.recordDiag(c);
            cur.batch_arena.deinit();
            if (e == error.PgError) {
                c.drainToReady() catch {
                    self.pool.discard(c);
                    return e;
                };
                self.pool.release(c);
            } else {
                self.pool.discard(c);
            }
            return e;
        };
        cur.done = !suspended;
        cur.have_pending = true;
        return cur;
    }

    /// `` sql`copy ... from stdin`.writable() `` — COPY IN.
    pub fn writable(self: *Postgres, comptime q: []const u8, args: anytype) errors.Error!CopyWriter {
        const c = try self.pool.acquire();
        c.execQuery(q, args, .{ .use_sync = false, .sink = .none }) catch |e| {
            return self.copyStartFailed(c, e);
        };
        if (c.in_copy != .in) {
            self.pool.release(c);
            return error.InvalidQuery;
        }
        return .{ .pg = self, .conn = c };
    }

    /// `` sql`copy ... to stdout`.readable() `` — COPY OUT.
    pub fn readable(self: *Postgres, comptime q: []const u8, args: anytype) errors.Error!CopyReader {
        const c = try self.pool.acquire();
        c.execQuery(q, args, .{ .use_sync = false, .sink = .none }) catch |e| {
            return self.copyStartFailed(c, e);
        };
        if (c.in_copy != .out) {
            self.pool.release(c);
            return error.InvalidQuery;
        }
        return .{ .pg = self, .conn = c };
    }

    fn copyStartFailed(self: *Postgres, c: *Conn, e: errors.Error) errors.Error {
        self.recordDiag(c);
        if (e == error.PgError) {
            c.drainToReady() catch {
                self.pool.discard(c);
                return e;
            };
            self.pool.release(c);
        } else {
            self.pool.discard(c);
        }
        return e;
    }

    /// `sql.notify(channel, payload)` — safe parameterized pg_notify.
    pub fn notify(self: *Postgres, channel: []const u8, payload: []const u8) errors.Error!Result {
        return self.query("select pg_notify({}, {})", .{ channel, payload });
    }

    /// `sql.listen(channel)` — reserves a dedicated connection for LISTEN.
    /// `listener.poll()` blocks until the next notification.
    pub fn listen(self: *Postgres, channel: []const u8) errors.Error!Listener {
        const c = try self.pool.acquire();

        var ident_buf: [160]u8 = undefined;
        const quoted = qb.quoteIdentInto(&ident_buf, channel) catch {
            self.pool.release(c);
            return error.InvalidIdent;
        };
        var qbuf: [200]u8 = undefined;
        const sql = std.fmt.bufPrint(&qbuf, "LISTEN {s}", .{quoted}) catch {
            self.pool.release(c);
            return error.InvalidIdent;
        };
        c.execSimple(sql, .{}) catch |e| {
            self.recordDiag(c);
            self.pool.discard(c);
            return e;
        };
        const chan_copy = self.gpa.dupe(u8, channel) catch {
            self.pool.release(c);
            return error.OutOfMemory;
        };
        return .{ .pg = self, .conn = c, .channel = chan_copy };
    }
};

const Watchdog = struct {
    conn_ctx: *const conn_mod.ConnCtx,
    io: std.Io = undefined,
    host_idx: usize,
    pid: u32,
    secret: u32,
    deadline_ns: i128,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: bool = false,

    fn run(wd: *Watchdog) void {
        while (true) {
            if (wd.done.load(.acquire)) return;
            const now: i128 = @as(i128, std.Io.Timestamp.now(wd.conn_ctx.io, .real).nanoseconds);
            if (!wd.fired and now >= wd.deadline_ns) {
                wd.fired = true;
                conn_mod.sendCancelRequest(wd.conn_ctx, wd.host_idx, wd.pid, wd.secret) catch {};
            }
            if (now >= wd.deadline_ns + 30 * std.time.ns_per_s) return;
            wd.io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
        }
    }
};

pub const Tx = struct {
    pg: *Postgres,
    conn: *Conn,
    finished: bool = false,

    pub fn query(self: *Tx, comptime q: []const u8, args: anytype) errors.Error!Result {
        return self.queryOpts(q, args, .{});
    }

    pub fn queryOpts(self: *Tx, comptime q: []const u8, args: anytype, o: QueryOptions) errors.Error!Result {
        const c = self.conn;
        var res = Result{
            .arena_state = std.heap.ArenaAllocator.init(self.pg.gpa),
            .transform = self.pg.transform,
        };
        var sink = conn_mod.RowsSink{ .gpa = self.pg.gpa, .arena = res.arena(), .max_bytes = self.pg.max_result_bytes };

        const eo = conn_mod.Conn.ExecOptions{
            .sink = .{ .rows = &sink },
            .prepare = if (o.prepare) |p| p else self.pg.prepare_default,
            .raw_results = o.raw_results,
        };
        c.execQuery(q, args, eo) catch |e| {
            self.pg.recordDiag(c);
            c.drainToReady() catch {};
            res.deinit();
            return e;
        };
        self.pg.fillResult(c, &sink, &res) catch |e| {
            res.deinit();
            return e;
        };
        return res;
    }

    pub fn simple(self: *Tx, sql: []const u8) errors.Error!Result {
        const c = self.conn;
        var res = Result{
            .arena_state = std.heap.ArenaAllocator.init(self.pg.gpa),
            .transform = self.pg.transform,
        };
        var sink = conn_mod.RowsSink{ .gpa = self.pg.gpa, .arena = res.arena(), .max_bytes = self.pg.max_result_bytes };
        c.execSimple(sql, .{ .sink = .{ .rows = &sink } }) catch |e| {
            self.pg.recordDiag(c);
            c.drainToReady() catch {};
            res.deinit();
            return e;
        };
        self.pg.fillResult(c, &sink, &res) catch |e| {
            res.deinit();
            return e;
        };
        return res;
    }

    /// Pipelined statements inside the transaction — ONE round-trip.
    pub fn pipeline(self: *Tx, queries: anytype) errors.Error![]Result {
        return self.pg.pipelineOn(self.conn, queries) catch |e| {
            self.pg.recordDiag(self.conn);
            self.conn.drainToReady() catch {};
            return e;
        };
    }

    pub fn commit(self: *Tx) errors.Error!void {
        if (self.finished) return error.UnsafeTransaction;
        self.finished = true;
        defer self.pg.pool.release(self.conn);
        try self.conn.execSimple("COMMIT", .{});
    }

    pub fn rollback(self: *Tx) errors.Error!void {
        if (self.finished) return error.UnsafeTransaction;
        self.finished = true;
        defer self.pg.pool.release(self.conn);
        self.conn.execSimple("ROLLBACK", .{}) catch |e| {
            self.pg.recordDiag(self.conn);
            self.conn.drainToReady() catch {};
            return e;
        };
    }

    fn finishForce(self: *Tx) void {
        if (!self.finished) {
            self.finished = true;
            self.pg.pool.release(self.conn);
        }
    }

    /// `sql.savepoint(name)` — nested transaction savepoint.
    pub fn savepoint(self: *Tx, name: []const u8) errors.Error!Savepoint {
        try qb.validateIdent(name);
        var buf: [96]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "SAVEPOINT {s}", .{name}) catch return error.InvalidIdent;
        try self.conn.execSimple(sql, .{});
        return .{ .tx = self, .name = self.pg.gpa.dupe(u8, name) catch return error.OutOfMemory };
    }

    /// `sql.prepare(gid)` — PREPARE TRANSACTION (two-phase commit).
    /// Releases the connection; the transaction waits for COMMIT/ROLLBACK
    /// PREPARED from another session.
    pub fn prepareTransaction(self: *Tx, gid: []const u8) errors.Error!void {
        if (self.finished) return error.UnsafeTransaction;
        if (gid.len > 100) return error.InvalidQuery;
        var esc_buf: [200]u8 = undefined;
        var o: usize = 0;
        for (gid) |ch| {
            if (ch == '\'') {
                if (o + 2 >= esc_buf.len) return error.InvalidQuery;
                esc_buf[o] = '\'';
                o += 1;
            }
            if (ch < 0x20) return error.InvalidQuery;
            if (o >= esc_buf.len) return error.InvalidQuery;
            esc_buf[o] = ch;
            o += 1;
        }
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "PREPARE TRANSACTION '{s}'", .{esc_buf[0..o]}) catch return error.InvalidQuery;
        self.conn.execSimple(sql, .{}) catch |e| {
            self.pg.recordDiag(self.conn);
            self.conn.drainToReady() catch {};
            return e;
        };
        self.finishForce();
    }
};

pub const Savepoint = struct {
    tx: *Tx,
    name: []const u8,

    pub fn rollback(self: *Savepoint) errors.Error!void {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "ROLLBACK TO SAVEPOINT {s}", .{self.name}) catch return error.InvalidIdent;
        try self.tx.conn.execSimple(sql, .{});
    }

    pub fn release(self: *Savepoint) errors.Error!void {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "RELEASE SAVEPOINT {s}", .{self.name}) catch return error.InvalidIdent;
        try self.tx.conn.execSimple(sql, .{});
        if (self.name.len > 0) self.tx.pg.gpa.free(self.name);
        self.name = "";
    }
};

pub const Reserved = struct {
    pg: *Postgres,
    conn: *Conn,

    pub fn query(self: *Reserved, comptime q: []const u8, args: anytype) errors.Error!Result {
        var tx = Tx{ .pg = self.pg, .conn = self.conn, .finished = true };
        return tx.queryOpts(q, args, .{});
    }

    pub fn simple(self: *Reserved, sql: []const u8) errors.Error!Result {
        var tx = Tx{ .pg = self.pg, .conn = self.conn, .finished = true };
        return tx.simple(sql);
    }

    pub fn release(self: *Reserved) void {
        self.pg.pool.release(self.conn);
    }
};

pub const Cursor = struct {
    pg: *Postgres,
    conn: *Conn,
    batch: u32,
    done: bool = false,
    have_pending: bool = false,
    batch_arena: std.heap.ArenaAllocator,
    pending: conn_mod.RowsSink = undefined,

    /// Next batch of rows (borrowed from the cursor arena — valid until
    /// the following `next()`/`close()`), or null at the end.
    pub fn next(self: *Cursor) errors.Error!?[]Row {
        if (self.have_pending) {
            self.have_pending = false;
            return self.buildRows();
        }
        if (self.done) return null;

        _ = self.batch_arena.reset(.retain_capacity);
        self.pending = .{
            .gpa = self.pg.gpa,
            .arena = self.batch_arena.allocator(),
            .max_bytes = self.pg.max_result_bytes,
            .columns = .empty,
            .rows = .empty,
        };

        var suspended = false;
        self.conn.writeExecute(self.batch) catch |e| return self.fail(e);
        self.conn.writeFlushMessage() catch |e| return self.fail(e);
        self.conn.flushOut() catch |e| return self.fail(e);
        self.conn.readQueryResults(.{
            .sink = .{ .rows = &self.pending },
            .suspended = &suspended,
            .no_sync_terminator = true,
        }) catch |e| return self.fail(e);

        self.done = !suspended;
        return self.buildRows();
    }

    fn buildRows(self: *Cursor) errors.Error!?[]Row {
        const a = self.batch_arena.allocator();
        const rows = a.alloc(Row, self.pending.rows.items.len) catch return error.OutOfMemory;
        const columns = self.pending.columns.items;
        self.pending.columns.items.len = 0;
        for (self.pending.rows.items, 0..) |vals, i| {
            rows[i] = .{ .values = vals, .columns = columns };
        }
        self.pending.rows.items.len = 0;
        if (rows.len == 0 and self.done) return null;
        return rows;
    }

    fn fail(self: *Cursor, e: errors.Error) errors.Error {
        self.pg.recordDiag(self.conn);
        self.conn.drainToReady() catch {
            self.pg.pool.discard(self.conn);
            self.batch_arena.deinit();
            return e;
        };
        self.pg.pool.discard(self.conn);
        self.batch_arena.deinit();
        return e;
    }

    /// `sql.CLOSE` — close the cursor and return the connection.
    pub fn close(self: *Cursor) errors.Error!void {
        if (!self.done) {
            self.conn.writeSyncMessage() catch {};
            self.conn.flushOut() catch {};
            self.conn.drainToReady() catch {
                self.pg.pool.discard(self.conn);
                self.batch_arena.deinit();
                return error.ConnectionClosed;
            };
        }
        self.pg.pool.release(self.conn);
        self.batch_arena.deinit();
    }
};

pub const CopyWriter = struct {
    pg: *Postgres,
    conn: *Conn,

    pub fn writeAll(self: *CopyWriter, data: []const u8) errors.Error!void {
        if (self.conn.in_copy != .in) return error.CopyInProgress;
        try self.conn.writeCopyData(data);
    }

    /// Finish the COPY (CopyDone + Sync) and return the number of rows the
    /// server copied.
    pub fn end(self: *CopyWriter) errors.Error!i64 {
        const n = self.conn.finishCopyIn() catch |e| {
            self.pg.recordDiag(self.conn);
            self.pg.pool.discard(self.conn);
            return e;
        };
        self.pg.pool.release(self.conn);
        return n;
    }

    /// Abort the COPY (CopyFail) with an error message; returns the
    /// server's error.
    pub fn fail(self: *CopyWriter, err_msg: []const u8) errors.Error!void {
        self.conn.abortCopyIn(err_msg) catch |e| {
            self.pg.recordDiag(self.conn);
            self.pg.pool.discard(self.conn);
            return e;
        };
        self.pg.recordDiag(self.conn);
        self.pg.pool.release(self.conn);
        return error.PgError;
    }
};

pub const CopyReader = struct {
    pg: *Postgres,
    conn: *Conn,

    /// Next COPY data chunk (borrowed — valid until the next call), or
    /// null when the copy finished.
    pub fn next(self: *CopyReader) errors.Error!?[]const u8 {
        while (true) {
            const msg = self.conn.readMessage() catch |e| {
                self.pg.pool.discard(self.conn);
                return e;
            };
            switch (msg.tag) {
                conn_mod.back.copy_data => return msg.data,
                conn_mod.back.copy_done => {
                    self.conn.finishCopyOut() catch |e| {
                        self.pg.recordDiag(self.conn);
                        self.pg.pool.discard(self.conn);
                        return e;
                    };
                    self.pg.pool.release(self.conn);
                    return null;
                },
                conn_mod.back.error_response => {
                    const e = self.conn.raiseError(msg.data);
                    self.conn.drainToReady() catch {};
                    self.pg.pool.discard(self.conn);
                    return e;
                },
                conn_mod.back.notice_response => self.conn.dispatchNotice(msg.data),
                else => {
                    self.pg.pool.discard(self.conn);
                    return error.ProtocolError;
                },
            }
        }
    }

    /// Abandon a COPY TO STDOUT: drain remaining data to completion.
    pub fn finish(self: *CopyReader) errors.Error!void {
        while (true) {
            const msg = self.conn.readMessage() catch |e| {
                self.pg.pool.discard(self.conn);
                return e;
            };
            switch (msg.tag) {
                conn_mod.back.copy_done => {
                    self.conn.finishCopyOut() catch |e| {
                        self.pg.recordDiag(self.conn);
                        self.pg.pool.discard(self.conn);
                        return e;
                    };
                    self.pg.pool.release(self.conn);
                    return;
                },
                conn_mod.back.copy_data => {},
                conn_mod.back.error_response => {
                    const e = self.conn.raiseError(msg.data);
                    self.conn.drainToReady() catch {};
                    self.pg.pool.discard(self.conn);
                    return e;
                },
                conn_mod.back.notice_response => self.conn.dispatchNotice(msg.data),
                else => {
                    self.pg.pool.discard(self.conn);
                    return error.ProtocolError;
                },
            }
        }
    }
};

pub const Listener = struct {
    pg: *Postgres,
    conn: *Conn,
    channel: []const u8,

    /// Blocking wait for the next notification. Returned slices are
    /// borrowed from the read buffer — valid until the next `poll()`.
    pub fn poll(self: *Listener) errors.Error!conn_mod.Conn.Notification {
        while (true) {
            const msg = self.conn.readMessage() catch |e| {
                self.pg.pool.discard(self.conn);
                return e;
            };
            switch (msg.tag) {
                conn_mod.back.notification_response => return Conn.parseNotification(msg.data),
                conn_mod.back.parameter_status => try self.conn.handleParameterStatus(msg.data),
                conn_mod.back.notice_response => self.conn.dispatchNotice(msg.data),
                conn_mod.back.error_response => return self.conn.raiseError(msg.data),
                else => return error.MessageNotSupported,
            }
        }
    }

    pub fn close(self: *Listener) void {
        self.pg.pool.release(self.conn);
        self.pg.gpa.free(self.channel);
    }
};
