const std = @import("std");
const errors = @import("error.zig");
const options = @import("options.zig");
const conn_mod = @import("connection.zig");

const Conn = conn_mod.Conn;

fn nowNs(io: std.Io) i128 {
    return @as(i128, std.Io.Timestamp.now(io, .real).nanoseconds);
}

pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conn_ctx: *const conn_mod.ConnCtx,
    resolved: *const options.Resolved,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    idle: std.ArrayList(*Conn) = .empty,
    total: usize = 0,
    max: usize,
    waiters: usize = 0,
    closing: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, conn_ctx: *const conn_mod.ConnCtx) Pool {
        return .{
            .gpa = gpa,
            .io = io,
            .conn_ctx = conn_ctx,
            .resolved = conn_ctx.resolved,
            .max = conn_ctx.resolved.opts.max,
        };
    }

    pub fn deinit(p: *Pool) void {
        p.idle.deinit(p.gpa);
    }

    /// Acquire a connection. Opens new connections lazily (up to `max`),
    /// then waits (FIFO) until one is released.
    pub fn acquire(p: *Pool) errors.Error!*Conn {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);

        while (true) {
            if (p.closing) return error.ConnectionEnded;

            while (p.idle.items.len > 0) {
                const c = p.idle.pop().?;
                if (c.isExpired()) {
                    p.total -= 1;
                    c.destroy();
                    continue;
                }
                c.idle_deadline_ns = null;
                return c;
            }

            if (p.total < p.max) {
                p.total += 1;
                p.mutex.unlock(p.io);
                const c = p.connectAny() catch |e| {
                    p.mutex.lockUncancelable(p.io);
                    p.total -= 1;
                    if (p.waiters > 0) p.cond.signal(p.io);
                    return e;
                };
                p.mutex.lockUncancelable(p.io);
                return c;
            }

            p.waiters += 1;
            p.cond.waitUncancelable(p.io, &p.mutex);
            p.waiters -= 1;
        }
    }

    /// Return a connection to the pool (or destroy it if it expired /
    /// the pool is closing / idle timeout would kill it immediately).
    pub fn release(p: *Pool, c: *Conn) void {
        p.mutex.lockUncancelable(p.io);
        if (p.closing or c.isExpired()) {
            p.total -= 1;
            p.mutex.unlock(p.io);
            c.destroy();
            return;
        }
        const idle_timeout = p.resolved.opts.idle_timeout;
        if (idle_timeout) |t| {
            c.idle_deadline_ns = nowNs(p.io) + @as(i128, @intCast(t));
        }
        p.idle.append(p.gpa, c) catch {
            p.total -= 1;
            p.mutex.unlock(p.io);
            c.destroy();
            return;
        };
        if (p.waiters > 0) p.cond.signal(p.io);
        p.mutex.unlock(p.io);
    }

    /// Drop a connection without returning it (errors, forced close).
    pub fn discard(p: *Pool, c: *Conn) void {
        p.mutex.lockUncancelable(p.io);
        p.total -= 1;
        if (p.waiters > 0) p.cond.signal(p.io);
        p.mutex.unlock(p.io);
        c.destroy();
    }

    fn connectAny(p: *Pool) errors.Error!*Conn {
        const r = p.resolved;
        const attrs = r.opts.target_session_attrs;

        if (r.unix_path != null) {
            const c = try conn_mod.Conn.open(p.conn_ctx, 0);
            try checkSessionAttrs(c, attrs);
            return c;
        }

        var last_err: errors.Error = error.ConnectFailed;
        for (0..r.hosts.len) |i| {
            const c = conn_mod.Conn.open(p.conn_ctx, i) catch |e| {
                last_err = e;
                continue;
            };
            checkSessionAttrs(c, attrs) catch |e| {
                c.close();
                last_err = e;
                continue;
            };
            return c;
        }
        return last_err;
    }

    fn checkSessionAttrs(c: *Conn, attrs: options.TargetSessionAttrs) errors.Error!void {
        if (attrs == .any) return;
        var sink = conn_mod.RowsSink.init(c.diag_arena.allocator(), c.ctx.max_result_bytes);

        switch (attrs) {
            .any => {},
            .read_write, .read_only => {
                try c.execSimple("show transaction_read_only", .{ .sink = .{ .rows = &sink } });
                const ro = sink.rows.items.len > 0 and
                    sink.rows.items[0].values.len > 0 and
                    sink.rows.items[0].values[0] == .text and
                    std.mem.eql(u8, sink.rows.items[0].values[0].text, "on");
                if (attrs == .read_write and ro) return error.ConnectFailed;
                if (attrs == .read_only and !ro) return error.ConnectFailed;
            },
            .primary, .standby, .prefer_standby => {
                try c.execSimple("select pg_is_in_recovery()", .{ .sink = .{ .rows = &sink } });
                const rec = sink.rows.items.len > 0 and
                    sink.rows.items[0].values.len > 0 and
                    sink.rows.items[0].values[0] == .bool_ and
                    sink.rows.items[0].values[0].bool_;
                if (attrs == .primary and rec) return error.ConnectFailed;
                if (attrs == .standby and !rec) return error.ConnectFailed;
            },
        }
    }

    /// Graceful shutdown: reject new queries, wait `timeout_ns` for
    /// in-flight work, then report `error.ConnectionDestroyed` if still busy.
    pub fn end(p: *Pool, timeout_ns: ?u64) errors.Error!void {
        p.mutex.lockUncancelable(p.io);
        p.closing = true;
        while (p.idle.items.len > 0) {
            const c = p.idle.pop().?;
            p.total -= 1;
            c.destroy();
        }
        const deadline: ?i128 = if (timeout_ns) |t| nowNs(p.io) + @as(i128, @intCast(t)) else null;
        while (p.total > 0) {
            if (deadline) |d| {
                if (nowNs(p.io) >= d) {
                    p.mutex.unlock(p.io);
                    return error.ConnectionDestroyed;
                }
            }
            p.mutex.unlock(p.io);
            p.io.sleep(std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
            p.mutex.lockUncancelable(p.io);
        }
        p.mutex.unlock(p.io);
    }
};
