const std = @import("std");
const errors = @import("error.zig");
const options = @import("options.zig");
const scram = @import("scram.zig");
const types = @import("types.zig");
const query = @import("query.zig");
const result_mod = @import("result.zig");

/// >= std.crypto.tls min_buffer_len
const io_min_buffer = 32 * 1024;

fn nowNs(io: std.Io) i128 {
    return @as(i128, std.Io.Timestamp.now(io, .real).nanoseconds);
}

pub const Column = types.Column;
pub const Value = types.Value;
pub const Row = result_mod.Row;

/// Shared per-Postgres TLS context (CA bundle, lazily loaded once).
pub const TlsCtx = struct {
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: std.Io.RwLock = .init,
    loaded: bool = false,
    failed: bool = false,
};

pub const ConnCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    resolved: *const options.Resolved,
    tls: ?*TlsCtx,
    on_notice: ?options.NoticeHook,
    on_notice_data: ?*anyopaque,
    on_parameter: ?options.ParameterHook,
    on_parameter_data: ?*anyopaque,
    allow_insecure_auth: bool,
    max_message_bytes: usize,
    max_result_bytes: usize,
    binary_first_exec: bool,
};

/// Messages sent by the backend.
pub const back = struct {
    pub const authentication = 'R';
    pub const backend_key_data = 'K';
    pub const parameter_status = 'S';
    pub const ready_for_query = 'Z';
    pub const row_description = 'T';
    pub const data_row = 'D';
    pub const command_complete = 'C';
    pub const empty_query_response = 'I';
    pub const notice_response = 'N';
    pub const error_response = 'E';
    pub const negotiate_protocol_version = 'v';
    pub const parameter_description = 't';
    pub const parse_complete = '1';
    pub const bind_complete = '2';
    pub const close_complete = '3';
    pub const no_data = 'n';
    pub const portal_suspended = 's';
    pub const copy_in_response = 'G';
    pub const copy_out_response = 'H';
    pub const copy_data = 'd';
    pub const copy_done = 'c';
    pub const notification_response = 'A';
};

/// Messages sent by the frontend.
pub const front = struct {
    pub const bind = 'B';
    pub const copy_data = 'd';
    pub const copy_done = 'c';
    pub const copy_fail = 'f';
    pub const describe = 'D';
    pub const execute = 'E';
    pub const flush = 'H';
    pub const parse = 'P';
    pub const password_message = 'p';
    pub const sync = 'S';
    pub const terminate = 'X';
    pub const query = 'Q';
};

/// Authentication request sub-codes (inside 'R' messages).
pub const auth = struct {
    pub const ok: u32 = 0;
    pub const cleartext_password: u32 = 3;
    pub const md5_password: u32 = 5;
    pub const sasl: u32 = 10;
    pub const sasl_continue: u32 = 11;
    pub const sasl_final: u32 = 12;
};

/// protocol 3.0
pub const protocol_version: u32 = 196608;
pub const ssl_request_code: u32 = 80877103;
pub const cancel_request_code: u32 = 80877102;

/// Statement/portal limits from PostgreSQL.
pub const max_statement_cache: usize = 256;

/// Extracts result-column type OIDs from a RowDescription payload
/// (count, then per column: name\0, table oid, attnum, type oid, typlen,
/// typmod, format). Returns how many OIDs were written, or 0 when the message
/// is malformed or wider than `out`.
pub fn parseResultOids(data: []const u8, out: []u32) usize {
    if (data.len < 2) return 0;
    const n = std.mem.readInt(u16, data[0..2], .big);
    if (n == 0 or n > out.len) return 0;
    var i: usize = 2;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const z = std.mem.indexOfScalarPos(u8, data, i, 0) orelse return 0;
        i = z + 1;
        if (i + 18 > data.len) return 0;
        i += 4 + 2; // table oid + attnum
        out[k] = std.mem.readInt(u32, data[i..][0..4], .big);
        i += 4 + 2 + 4 + 2; // type oid + typlen + typmod + format
    }
    return n;
}

pub const max_cached_params = 16;
pub const max_cached_columns = 64;
pub const unknown_result_cols: u8 = 255;

const CacheEntry = struct {
    name: [20]u8,
    n_oids: u8,
    oids: [max_cached_params]u32,
    lru: u32,
    n_result: u8 = unknown_result_cols,
    result_oids: [max_cached_columns]u32 = undefined,
};

/// Bump allocator over arena-backed chunks. One arena allocation serves many
/// rows, so per-row work is a pointer bump instead of an arena alloc (which
/// costs an atomic RMW per call). Chunks double up to `max_chunk`.
pub const Bump = struct {
    arena: std.mem.Allocator,
    chunk: []u8 = &.{},
    pos: usize = 0,

    pub const first_chunk = 8 * 1024;
    pub const max_chunk = 128 * 1024;

    pub fn alloc(b: *Bump, n: usize, alignment: std.mem.Alignment) errors.Error![]u8 {
        const a = alignment.toByteUnits();
        const off = std.mem.alignForward(usize, b.pos, a);
        if (off + n > b.chunk.len) {
            const want = if (n + a > max_chunk) n + a else @min(@max(n + a, @max(b.chunk.len * 2, first_chunk)), max_chunk);
            b.chunk = b.arena.alloc(u8, want) catch return error.OutOfMemory;
            b.pos = n;
            return b.chunk[0..n];
        }
        b.pos = off + n;
        return b.chunk[off..][0..n];
    }

    /// Reuse the current chunk from the start. Only valid when everything
    /// handed out so far has been discarded (multi-statement simple queries).
    pub fn reset(b: *Bump) void {
        b.pos = 0;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn allocator(b: *Bump) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &vtable };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        if (len == 0) return @constCast(&[_]u8{});
        const b: *Bump = @ptrCast(@alignCast(ctx));
        const out = b.alloc(len, alignment) catch return null;
        return out.ptr;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }
};

/// Materializes rows into an arena (regular queries).
pub const RowsSink = struct {
    arena: std.mem.Allocator,
    max_bytes: usize = std.math.maxInt(usize),
    bytes: usize = 0,
    columns: std.ArrayList(Column) = .empty,
    rows: std.ArrayList(Row) = .empty,
    values: Bump,
    count: i64 = 0,
    command_tag: []const u8 = "",
    statement_started: bool = false,

    pub fn init(arena: std.mem.Allocator, max_bytes: usize) RowsSink {
        return .{
            .arena = arena,
            .max_bytes = max_bytes,
            .values = .{ .arena = arena },
        };
    }
};

/// Streams rows one at a time through a callback (forEach / iter).
pub const StreamRowFn = *const fn (ctx: ?*anyopaque, columns: []const Column, values: []const Value) errors.Error!void;
pub const StreamSink = struct {
    gpa: std.mem.Allocator,
    ctx: ?*anyopaque,
    cb: StreamRowFn,
    row_arena: *std.heap.ArenaAllocator,
    columns_arena: std.mem.Allocator,
    columns: std.ArrayList(Column) = .empty,
};

pub const RowSink = union(enum) {
    none,
    rows: *RowsSink,
    stream: *StreamSink,
};

pub const Conn = struct {
    ctx: *const ConnCtx,
    io: std.Io,
    gpa: std.mem.Allocator,

    host_idx: usize = 0,
    stream: ?std.Io.net.Stream = null,
    sock_reader: std.Io.net.Stream.Reader = undefined,
    sock_writer: std.Io.net.Stream.Writer = undefined,
    sock_rbuf: [io_min_buffer]u8 = undefined,
    sock_wbuf: [io_min_buffer]u8 = undefined,
    tls_client: ?*std.crypto.tls.Client = null,
    tls_rbuf: [std.crypto.tls.Client.min_buffer_len + 512]u8 = undefined,
    tls_wbuf: [std.crypto.tls.Client.min_buffer_len + 512]u8 = undefined,
    entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined,
    reader: *std.Io.Reader = undefined,
    writer: *std.Io.Writer = undefined,
    is_tls: bool = false,
    host_name: [256]u8 = undefined,
    host_name_len: usize = 0,

    out: std.ArrayList(u8) = .empty,
    out_msg_start: usize = 0,
    big: std.ArrayList(u8) = .empty,

    sql_buf: std.ArrayList(u8) = .empty,
    encs_buf: std.ArrayList(types.Enc) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    pid: u32 = 0,
    secret: u32 = 0,
    tx_status: u8 = 'I',
    server_version: u32 = 0,
    standard_conforming_strings: bool = true,
    integer_datetimes: bool = true,
    in_copy: enum { none, in, out } = .none,

    diagnostics: errors.Diagnostics = .{},
    diag_arena: std.heap.ArenaAllocator,

    scram: scram.Buffers = .{},
    name_buf: [20]u8 = undefined,

    cache: [max_statement_cache]?CacheEntry = [_]?CacheEntry{null} ** max_statement_cache,
    last_result_oids: [max_cached_columns]u32 = undefined,
    last_n_result: usize = 0,
    last_result_overflow: bool = true,
    last_result_formats: [max_cached_columns]u8 = undefined,
    /// How many formats the last Bind requested (0 = all text).
    last_exec_format_len: usize = 0,
    cache_clock: u32 = 0,
    cache_len: usize = 0,

    created_at_ns: i128 = 0,
    lifetime_limit_ns: ?u64 = null,
    idle_deadline_ns: ?i128 = null,

    pub fn open(ctx: *const ConnCtx, host_idx: usize) errors.Error!*Conn {
        const gpa = ctx.gpa;
        const c = gpa.create(Conn) catch return error.OutOfMemory;
        errdefer gpa.destroy(c);
        c.* = .{
            .ctx = ctx,
            .io = ctx.io,
            .gpa = gpa,
            .diag_arena = std.heap.ArenaAllocator.init(gpa),
            .host_idx = host_idx,
            .created_at_ns = nowNs(ctx.io),
        };
        if (ctx.resolved.opts.max_lifetime) |base| {
            var rnd: [8]u8 = undefined;
            ctx.io.random(&rnd);
            const frac: f64 = @as(f64, @floatFromInt(std.mem.readInt(u64, &rnd, .little))) /
                @as(f64, @floatFromInt(std.math.maxInt(u64)));
            c.lifetime_limit_ns = base + @as(u64, @intFromFloat(@as(f64, @floatFromInt(base)) * 0.5 * frac));
        }
        try c.connectTransport(host_idx);
        try c.startup();
        return c;
    }

    pub fn destroy(c: *Conn) void {
        if (c.stream) |s| s.close(c.io);
        if (c.tls_client) |t| c.gpa.destroy(t);
        c.out.deinit(c.gpa);
        c.big.deinit(c.gpa);
        c.sql_buf.deinit(c.gpa);
        c.encs_buf.deinit(c.gpa);
        c.scratch.deinit(c.gpa);
        c.diag_arena.deinit();
        c.gpa.destroy(c);
    }

    pub fn close(c: *Conn) void {
        c.beginMessage(front.terminate) catch {};
        c.flushOut() catch {};
        c.destroy();
    }

    pub fn isExpired(c: *const Conn) bool {
        const now = nowNs(c.io);
        if (c.lifetime_limit_ns) |lim| {
            const age: u128 = @intCast(now - c.created_at_ns);
            if (age >= @as(u128, lim)) return true;
        }
        if (c.idle_deadline_ns) |d| {
            if (now >= d) return true;
        }
        return false;
    }

    fn connectTransport(c: *Conn, host_idx: usize) errors.Error!void {
        const r = c.ctx.resolved;

        if (r.unix_path) |path| {
            const ua = std.Io.net.UnixAddress.init(path) catch return error.ConnectFailed;
            const stream = std.Io.net.UnixAddress.connect(&ua, c.io) catch return error.ConnectFailed;
            c.stream = stream;
            c.rememberHost(path);
            c.setupPlain();
            return;
        }

        const host = r.hosts[host_idx];
        const port = if (r.ports.len > host_idx) r.ports[host_idx] else 5432;
        c.rememberHost(host);

        const stream = blk: {
            if (std.Io.net.IpAddress.parse(host, port)) |addr| {
                break :blk std.Io.net.IpAddress.connect(&addr, c.io, .{ .mode = .stream }) catch return error.ConnectFailed;
            } else |_| {}
            const hn = std.Io.net.HostName.init(host) catch return error.InvalidUrl;
            break :blk std.Io.net.HostName.connect(hn, c.io, port, .{ .mode = .stream }) catch |e| switch (e) {
                error.UnknownHostName => return error.UnknownHostName,
                else => return error.ConnectFailed,
            };
        };
        c.stream = stream;

        const ssl_mode = r.opts.ssl;
        if (ssl_mode == .disable) {
            c.setupPlain();
            return;
        }

        if (r.opts.ssl_negotiation == .postgres) {
            var req: [8]u8 = undefined;
            std.mem.writeInt(u32, req[0..4], 8, .big);
            std.mem.writeInt(u32, req[4..8], ssl_request_code, .big);
            c.setupPlain();
            c.writer.writeAll(&req) catch return error.WriteFailed;
            c.writer.flush() catch return error.WriteFailed;
            const answer = c.reader.peekArray(1) catch return error.ReadFailed;
            const wants_tls = answer[0] == 'S';
            c.reader.toss(1);
            if (wants_tls) {
                try c.startTls(host, ssl_mode);
            } else switch (ssl_mode) {
                .require, .verify_ca, .verify_full => return error.TlsRequired,
                else => {},
            }
            return;
        }

        try c.startTls(host, ssl_mode);
    }

    fn rememberHost(c: *Conn, host: []const u8) void {
        const n = @min(host.len, c.host_name.len);
        @memcpy(c.host_name[0..n], host[0..n]);
        c.host_name_len = n;
    }

    pub fn hostString(c: *const Conn) []const u8 {
        return c.host_name[0..c.host_name_len];
    }

    fn setupPlain(c: *Conn) void {
        c.sock_reader = std.Io.net.Stream.Reader.init(c.stream.?, c.io, &c.sock_rbuf);
        c.sock_writer = std.Io.net.Stream.Writer.init(c.stream.?, c.io, &c.sock_wbuf);
        c.reader = &c.sock_reader.interface;
        c.writer = &c.sock_writer.interface;
        c.is_tls = false;
    }

    fn startTls(c: *Conn, host: []const u8, ssl_mode: options.SslMode) errors.Error!void {
        const ctx = c.ctx;
        c.sock_reader = std.Io.net.Stream.Reader.init(c.stream.?, c.io, &c.sock_rbuf);
        c.sock_writer = std.Io.net.Stream.Writer.init(c.stream.?, c.io, &c.sock_wbuf);

        var have_ca = false;
        if (ctx.tls) |t| {
            if (!t.loaded and !t.failed) {
                t.lock.lockUncancelable(c.io);
                defer t.lock.unlock(c.io);
                if (!t.loaded and !t.failed) {
                    const now = std.Io.Clock.Timestamp.now(c.io, .real);
                    t.bundle.rescan(c.gpa, c.io, now.raw) catch {
                        t.failed = true;
                    };
                    t.loaded = true;
                }
            }
            have_ca = t.loaded and !t.failed;
        }

        if ((ssl_mode == .require or ssl_mode == .verify_ca or ssl_mode == .verify_full) and !have_ca) {
            return error.TlsFailed;
        }

        c.io.randomSecure(c.entropy[0..]) catch return error.Unexpected;

        const verify_host = ssl_mode == .require or ssl_mode == .verify_full;
        const use_ca = have_ca;

        const client_ptr = c.gpa.create(std.crypto.tls.Client) catch return error.OutOfMemory;
        errdefer c.gpa.destroy(client_ptr);

        const now = std.Io.Clock.Timestamp.now(c.io, .real);
        client_ptr.* = std.crypto.tls.Client.init(
            &c.sock_reader.interface,
            &c.sock_writer.interface,
            .{
                .host = if (verify_host) .{ .explicit = host } else .no_verification,
                .ca = if (use_ca) .{ .bundle = .{
                    .gpa = c.gpa,
                    .io = c.io,
                    .lock = &ctx.tls.?.lock,
                    .bundle = &ctx.tls.?.bundle,
                } } else .no_verification,
                .write_buffer = &c.tls_wbuf,
                .read_buffer = &c.tls_rbuf,
                .entropy = &c.entropy,
                .realtime_now = now.raw,
            },
        ) catch {
            return error.TlsFailed;
        };
        c.tls_client = client_ptr;
        c.reader = &client_ptr.reader;
        c.writer = &client_ptr.writer;
        c.is_tls = true;
    }

    fn startup(c: *Conn) errors.Error!void {
        const alloc = c.gpa;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);

        const r = c.ctx.resolved;
        const pairs = [_][]const u8{
            "user",             r.username,
            "database",         r.database,
            "application_name", r.application_name,
        };
        for (pairs) |p| {
            try body.appendSlice(alloc, p);
            try body.append(alloc, 0);
        }
        for (r.parameters) |kv| {
            if (kv[0].len == 0 or kv[0].len > 64 or kv[1].len > 1024) return error.InvalidQuery;
            for (kv[0]) |ch| if (ch < 0x20) return error.InvalidQuery;
            for (kv[1]) |ch| if (ch < 0x20) return error.InvalidQuery;
            try body.appendSlice(alloc, kv[0]);
            try body.append(alloc, 0);
            try body.appendSlice(alloc, kv[1]);
            try body.append(alloc, 0);
        }
        try body.append(alloc, 0);

        const total = 8 + body.items.len;
        var head: [4]u8 = undefined;
        std.mem.writeInt(u32, &head, @intCast(total), .big);
        try c.out.appendSlice(alloc, &head);
        var ver: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver, protocol_version, .big);
        try c.out.appendSlice(alloc, &ver);
        try c.out.appendSlice(alloc, body.items);
        try c.flushOut();

        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.error_response => return c.raiseError(msg.data),
                back.authentication => try c.handleAuth(msg.data),
                back.parameter_status => try c.handleParameterStatus(msg.data),
                back.backend_key_data => {
                    if (msg.data.len < 8) return error.ProtocolError;
                    c.pid = std.mem.readInt(u32, msg.data[0..4], .big);
                    c.secret = std.mem.readInt(u32, msg.data[4..8], .big);
                },
                back.notice_response => c.dispatchNotice(msg.data),
                back.negotiate_protocol_version => {},
                back.ready_for_query => {
                    c.tx_status = msg.data[0];
                    return;
                },
                else => return error.MessageNotSupported,
            }
        }
    }

    fn handleAuth(c: *Conn, data: []const u8) errors.Error!void {
        if (data.len < 4) return error.ProtocolError;
        const code = std.mem.readInt(u32, data[0..4], .big);
        switch (code) {
            auth.ok => {},
            auth.cleartext_password => {
                if (!c.is_tls and !c.ctx.allow_insecure_auth) return error.AuthFailed;
                c.beginMessage(front.password_message) catch return error.WriteFailed;
                try c.out.appendSlice(c.gpa, c.ctx.resolved.password);
                try c.out.append(c.gpa, 0);
                c.endMessage();
                try c.flushOut();
            },
            auth.md5_password => {
                if (!c.ctx.allow_insecure_auth) return error.AuthTypeNotImplemented;
                if (data.len < 8) return error.ProtocolError;
                const salt = data[4..8];
                const pw = c.ctx.resolved.password;
                const user = c.ctx.resolved.username;
                const Md5 = std.crypto.hash.Md5;

                var inner: [16]u8 = undefined;
                var h = Md5.init(.{});
                h.update(pw);
                h.update(user);
                h.final(&inner);
                var inner_hex: [32]u8 = undefined;
                _ = std.fmt.bufPrint(&inner_hex, "{x}", .{&inner}) catch return error.Unexpected;

                var outer: [16]u8 = undefined;
                var h2 = Md5.init(.{});
                h2.update(&inner_hex);
                h2.update(salt);
                h2.final(&outer);

                var response: ["md5".len + 32]u8 = "md5".* ++ [_]u8{0} ** 32;
                _ = std.fmt.bufPrint(response["md5".len..], "{x}", .{&outer}) catch return error.Unexpected;

                c.beginMessage(front.password_message) catch return error.WriteFailed;
                try c.out.appendSlice(c.gpa, &response);
                try c.out.append(c.gpa, 0);
                c.endMessage();
                try c.flushOut();
            },
            auth.sasl => {
                if (data.len < 4) return error.ProtocolError;
                try c.scramAuth(data[4..]);
            },
            else => return error.AuthTypeNotImplemented,
        }
    }

    fn scramAuth(c: *Conn, mechanisms: []const u8) errors.Error!void {
        var found = false;
        var it = std.mem.splitScalar(u8, mechanisms, 0);
        while (it.next()) |m| {
            if (std.mem.eql(u8, m, scram.mechanism)) found = true;
        }
        if (!found) return error.AuthTypeNotImplemented;

        const first = try scram.clientFirst(&c.scram, c.io, c.ctx.resolved.username);
        c.beginMessage(front.password_message) catch return error.WriteFailed;
        try c.out.appendSlice(c.gpa, scram.mechanism);
        try c.out.append(c.gpa, 0);
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(i32, &lenb, @intCast(first.len), .big);
        try c.out.appendSlice(c.gpa, &lenb);
        try c.out.appendSlice(c.gpa, first);
        c.endMessage();
        try c.flushOut();

        while (true) {
            const msg = try c.readMessage();
            if (msg.tag == back.error_response) return c.raiseError(msg.data);
            if (msg.tag != back.authentication) return error.ProtocolError;
            if (msg.data.len < 4) return error.ProtocolError;
            const code = std.mem.readInt(u32, msg.data[0..4], .big);
            switch (code) {
                auth.sasl_continue => {
                    if (msg.data.len < 8) return error.ProtocolError;
                    const final = try scram.clientFinal(&c.scram, c.ctx.resolved.password, msg.data[4..]);
                    c.beginMessage(front.password_message) catch return error.WriteFailed;
                    try c.out.appendSlice(c.gpa, final);
                    c.endMessage();
                    try c.flushOut();
                },
                auth.sasl_final => {
                    if (msg.data.len < 8) return error.ProtocolError;
                    try scram.verifyServerFinal(&c.scram, msg.data[4..]);
                },
                auth.ok => return,
                else => return error.ProtocolError,
            }
        }
    }

    pub fn handleParameterStatus(c: *Conn, data: []const u8) errors.Error!void {
        const z1 = std.mem.indexOfScalar(u8, data, 0) orelse return error.ProtocolError;
        const name = data[0..z1];
        const value = data[z1 + 1 ..];
        if (std.mem.eql(u8, name, "server_version")) {
            c.server_version = std.fmt.parseInt(u32, value[0..@min(value.len, 2)], 10) catch 0;
        } else if (std.mem.eql(u8, name, "standard_conforming_strings")) {
            c.standard_conforming_strings = std.mem.eql(u8, value, "on");
        } else if (std.mem.eql(u8, name, "integer_datetimes")) {
            c.integer_datetimes = std.mem.eql(u8, value, "on");
        }
        if (c.ctx.on_parameter) |hook| {
            hook(c.ctx.on_parameter_data, name, value);
        }
    }

    pub fn beginMessage(c: *Conn, tag: u8) errors.Error!void {
        c.out_msg_start = c.out.items.len;
        try c.out.append(c.gpa, tag);
        try c.out.appendNTimes(c.gpa, 0, 4);
    }

    pub fn endMessage(c: *Conn) void {
        const len = c.out.items.len - c.out_msg_start - 1;
        std.mem.writeInt(u32, c.out.items[c.out_msg_start + 1 ..][0..4], @intCast(len), .big);
    }

    pub fn flushOut(c: *Conn) errors.Error!void {
        if (c.out.items.len == 0) return;
        c.writer.writeAll(c.out.items) catch return error.WriteFailed;
        c.writer.flush() catch return error.WriteFailed;
        c.out.clearRetainingCapacity();
    }

    pub const Message = struct {
        tag: u8,
        /// Borrowed zero-copy slice — valid until the next `readMessage`.
        data: []const u8,
    };

    pub fn readMessage(c: *Conn) errors.Error!Message {
        const head = c.reader.peekArray(5) catch |e| {
            return if (e == error.EndOfStream) error.ConnectionClosed else error.ReadFailed;
        };
        const tag = head[0];
        const len = std.mem.readInt(u32, head[1..5], .big);
        if (len < 4) return error.ProtocolError;
        const body = len - 4;
        if (body > c.ctx.max_message_bytes) return error.MessageTooLarge;

        if (5 + body <= c.reader.buffer.len) {
            const all = c.reader.peek(5 + body) catch |e| {
                return if (e == error.EndOfStream) error.ConnectionClosed else error.ReadFailed;
            };
            c.reader.toss(5 + body);
            return .{ .tag = tag, .data = all[5..] };
        }

        c.reader.toss(5);
        c.big.clearRetainingCapacity();
        c.big.resize(c.gpa, body) catch return error.OutOfMemory;
        c.reader.readSliceAll(c.big.items) catch |e| {
            return if (e == error.EndOfStream) error.ConnectionClosed else error.ReadFailed;
        };
        return .{ .tag = tag, .data = c.big.items };
    }

    pub fn drainToReady(c: *Conn) errors.Error!void {
        var guard: usize = 0;
        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.ready_for_query => {
                    c.tx_status = msg.data[0];
                    return;
                },
                back.error_response => {
                    _ = c.raiseError(msg.data) catch {};
                },
                else => {},
            }
            guard += 1;
            if (guard > 10_000_000) return error.ProtocolError;
        }
    }

    /// Finish COPY IN: CopyDone + Sync in one flush, then read the server's
    /// CommandComplete / ErrorResponse through ReadyForQuery. The Sync must
    /// travel with CopyDone — the backend holds its output until it sees one,
    /// so waiting for CommandComplete before syncing would deadlock.
    pub fn finishCopyIn(c: *Conn) errors.Error!i64 {
        try c.writeCopyDone();
        try c.writeSyncMessage();
        try c.flushOut();
        c.in_copy = .none;
        var result: ?errors.Error = null;
        var count: i64 = 0;
        var guard: usize = 0;
        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.command_complete => {
                    const tag = msg.data[0 .. std.mem.indexOfScalar(u8, msg.data, 0) orelse msg.data.len];
                    var it = std.mem.splitBackwardsScalar(u8, tag, ' ');
                    if (it.next()) |last| {
                        count = std.fmt.parseInt(i64, last, 10) catch 0;
                    }
                },
                back.error_response => result = c.raiseError(msg.data),
                back.notice_response => c.dispatchNotice(msg.data),
                back.ready_for_query => {
                    c.tx_status = msg.data[0];
                    if (result) |e| return e;
                    return count;
                },
                else => {},
            }
            guard += 1;
            if (guard > 1_000_000) return error.ProtocolError;
        }
    }

    /// Finish COPY OUT: the server already sent CopyDone; Sync + Flush first
    /// (so its CommandComplete is not withheld), then read to ReadyForQuery.
    pub fn finishCopyOut(c: *Conn) errors.Error!void {
        try c.writeSyncMessage();
        try c.flushOut();
        c.in_copy = .none;
        var result: ?errors.Error = null;
        var guard: usize = 0;
        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.command_complete => {},
                back.error_response => result = c.raiseError(msg.data),
                back.notice_response => c.dispatchNotice(msg.data),
                back.ready_for_query => {
                    c.tx_status = msg.data[0];
                    if (result) |e| return e;
                    return;
                },
                else => {},
            }
            guard += 1;
            if (guard > 1_000_000) return error.ProtocolError;
        }
    }

    /// Abort COPY IN: CopyFail + Sync, then surface the server's error.
    pub fn abortCopyIn(c: *Conn, err_msg: []const u8) errors.Error!void {
        try c.writeCopyFail(err_msg);
        try c.writeSyncMessage();
        try c.flushOut();
        c.in_copy = .none;
        var result: ?errors.Error = error.PgError;
        var guard: usize = 0;
        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.error_response => result = c.raiseError(msg.data),
                back.notice_response => c.dispatchNotice(msg.data),
                back.ready_for_query => {
                    c.tx_status = msg.data[0];
                    return result.?;
                },
                else => {},
            }
            guard += 1;
            if (guard > 1_000_000) return error.ProtocolError;
        }
    }

    pub fn raiseError(c: *Conn, payload: []const u8) errors.Error {
        const prev_query = c.diagnostics.query;
        c.diagnostics = .{};
        c.diagnostics.query = prev_query;
        errors.parseErrorFields(payload, c.diag_arena.allocator(), &c.diagnostics) catch {};
        return error.PgError;
    }

    pub fn setQueryContext(c: *Conn, sql: []const u8) void {
        const a = c.diag_arena.allocator();
        c.diagnostics.query = a.dupe(u8, sql) catch "";
    }

    pub fn copyDiagnostics(c: *Conn, arena: std.mem.Allocator) errors.Diagnostics {
        var d = c.diagnostics;
        inline for (@typeInfo(errors.Diagnostics).@"struct".fields) |f| {
            if (f.type == []const u8) {
                @field(d, f.name) = arena.dupe(u8, @field(d, f.name)) catch "";
            }
        }
        return d;
    }

    pub fn dispatchNotice(c: *Conn, payload: []const u8) void {
        var notice = errors.Diagnostics{};
        errors.parseErrorFields(payload, c.diag_arena.allocator(), &notice) catch return;
        if (c.ctx.on_notice) |hook| hook(c.ctx.on_notice_data, &notice);
    }

    pub const Notification = struct {
        pid: u32,
        channel: []const u8,
        payload: []const u8,
    };

    pub fn parseNotification(data: []const u8) errors.Error!Notification {
        if (data.len < 4) return error.ProtocolError;
        const pid = std.mem.readInt(u32, data[0..4], .big);
        const z1 = std.mem.indexOfScalarPos(u8, data, 4, 0) orelse return error.ProtocolError;
        const channel = data[4..z1];
        const z2 = std.mem.indexOfScalarPos(u8, data, z1 + 1, 0) orelse return error.ProtocolError;
        const payload = data[z1 + 1 .. z2];
        return .{ .pid = pid, .channel = channel, .payload = payload };
    }

    pub fn cacheHas(c: *Conn, name: []const u8, oids: []const u32) bool {
        return c.cacheFind(name, oids) != null;
    }

    /// Result-column OIDs recorded for an already-prepared statement, or
    /// null when the statement is not cached or its column OIDs are unknown.
    pub fn cachedResultOids(c: *Conn, name: []const u8, oids: []const u32) ?[]const u32 {
        const entry = c.cacheFind(name, oids) orelse return null;
        if (entry.n_result == unknown_result_cols) return null;
        return entry.result_oids[0..entry.n_result];
    }

    /// Per-column result format codes (1 = binary) for the given result OIDs.
    /// The returned slice borrows per-connection scratch and stays valid
    /// until the next query.
    pub fn resultFormatsFor(c: *Conn, result_oids: []const u32) []const u8 {
        const nf = @min(result_oids.len, max_cached_columns);
        for (result_oids[0..nf], 0..) |o, i| c.last_result_formats[i] = if (types.binResultOid(o)) 1 else 0;
        return c.last_result_formats[0..nf];
    }

    fn cacheFind(c: *Conn, name: []const u8, oids: []const u32) ?*CacheEntry {
        if (name.len != 20 or oids.len > max_cached_params) return null;
        for (c.cache[0..c.cache_len]) |*slot| {
            const entry = if (slot.*) |*e| e else continue;
            if (std.mem.eql(u8, &entry.name, name) and entry.n_oids == oids.len) {
                var match = true;
                for (oids, 0..) |o, i| {
                    if (entry.oids[i] != o) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    c.cache_clock += 1;
                    entry.lru = c.cache_clock;
                    return entry;
                }
            }
        }
        return null;
    }

    pub fn cacheRecord(c: *Conn, name: []const u8, oids: []const u32) void {
        c.cacheInsert(name, oids);
    }

    fn cacheInsert(c: *Conn, name: []const u8, oids: []const u32) void {
        if (name.len != 20 or oids.len > max_cached_params) return;
        c.cache_clock += 1;
        if (c.cacheFind(name, oids)) |existing| {
            existing.lru = c.cache_clock;
            if (c.last_result_overflow) {
                existing.n_result = unknown_result_cols;
            } else {
                existing.n_result = @intCast(c.last_n_result);
                for (c.last_result_oids[0..c.last_n_result], 0..) |o, i| existing.result_oids[i] = o;
            }
            return;
        }
        var slot: *CacheEntry = undefined;
        if (c.cache_len < max_statement_cache) {
            c.cache[c.cache_len] = .{ .name = undefined, .n_oids = 0, .oids = undefined, .lru = 0 };
            slot = &c.cache[c.cache_len].?;
            c.cache_len += 1;
        } else {
            var oldest: u32 = std.math.maxInt(u32);
            var found = false;
            for (c.cache[0..c.cache_len]) |*sl| {
                const entry = if (sl.*) |*e| e else continue;
                if (!found or entry.lru < oldest) {
                    oldest = entry.lru;
                    slot = entry;
                    found = true;
                }
            }
            if (!found) return;
        }
        const entry = slot;
        @memcpy(&entry.name, name[0..20]);
        entry.n_oids = @intCast(oids.len);
        for (oids, 0..) |o, i| entry.oids[i] = o;
        if (c.last_result_overflow) {
            entry.n_result = unknown_result_cols;
        } else {
            entry.n_result = @intCast(c.last_n_result);
            for (c.last_result_oids[0..c.last_n_result], 0..) |o, i| entry.result_oids[i] = o;
        }
        entry.lru = c.cache_clock;
    }

    pub fn writeParse(c: *Conn, name: []const u8, sql: []const u8, oids: []const u32) errors.Error!void {
        try c.beginMessage(front.parse);
        try c.out.appendSlice(c.gpa, name);
        try c.out.append(c.gpa, 0);
        try c.out.appendSlice(c.gpa, sql);
        try c.out.append(c.gpa, 0);
        var nb: [2]u8 = undefined;
        std.mem.writeInt(u16, &nb, @intCast(oids.len), .big);
        try c.out.appendSlice(c.gpa, &nb);
        for (oids) |o| {
            var ob: [4]u8 = undefined;
            std.mem.writeInt(u32, &ob, o, .big);
            try c.out.appendSlice(c.gpa, &ob);
        }
        c.endMessage();
    }

    pub fn writeDescribeStatement(c: *Conn, name: []const u8) errors.Error!void {
        try c.beginMessage(front.describe);
        try c.out.append(c.gpa, 'S');
        try c.out.appendSlice(c.gpa, name);
        try c.out.append(c.gpa, 0);
        c.endMessage();
    }

    pub fn writeBind(c: *Conn, stmt_name: []const u8, encs: []const types.Enc, result_oids: ?[]const u32) errors.Error!void {
        try c.beginMessage(front.bind);
        try c.out.append(c.gpa, 0);
        try c.out.appendSlice(c.gpa, stmt_name);
        try c.out.append(c.gpa, 0);

        var b2: [2]u8 = undefined;
        if (encs.len == 0) {
            std.mem.writeInt(u16, &b2, 0, .big);
            try c.out.appendSlice(c.gpa, &b2);
        } else {
            var all_text = true;
            var all_bin = true;
            for (encs) |e| {
                if (e.format != 0) all_text = false;
                if (e.format != 1) all_bin = false;
            }
            if (all_text or all_bin) {
                std.mem.writeInt(u16, &b2, 1, .big);
                try c.out.appendSlice(c.gpa, &b2);
                std.mem.writeInt(u16, &b2, if (all_bin) 1 else 0, .big);
                try c.out.appendSlice(c.gpa, &b2);
            } else {
                std.mem.writeInt(u16, &b2, @intCast(encs.len), .big);
                try c.out.appendSlice(c.gpa, &b2);
                for (encs) |e| {
                    std.mem.writeInt(u16, &b2, e.format, .big);
                    try c.out.appendSlice(c.gpa, &b2);
                }
            }
        }

        std.mem.writeInt(u16, &b2, @intCast(encs.len), .big);
        try c.out.appendSlice(c.gpa, &b2);
        for (encs) |e| {
            var lb: [4]u8 = undefined;
            if (e.is_null) {
                std.mem.writeInt(i32, &lb, -1, .big);
                try c.out.appendSlice(c.gpa, &lb);
            } else {
                std.mem.writeInt(i32, &lb, @intCast(e.bytes.len), .big);
                try c.out.appendSlice(c.gpa, &lb);
                try c.out.appendSlice(c.gpa, e.bytes);
            }
        }

        if (result_oids) |roids| {
            var all_bin = true;
            var all_text = true;
            for (roids) |o| {
                const b = types.binResultOid(o);
                all_bin = all_bin and b;
                all_text = all_text and !b;
            }
            if (all_bin and roids.len > 0) {
                std.mem.writeInt(u16, &b2, 1, .big);
                try c.out.appendSlice(c.gpa, &b2);
                std.mem.writeInt(u16, &b2, 1, .big);
                try c.out.appendSlice(c.gpa, &b2);
            } else if (all_text or roids.len == 0) {
                std.mem.writeInt(u16, &b2, 1, .big);
                try c.out.appendSlice(c.gpa, &b2);
                std.mem.writeInt(u16, &b2, 0, .big);
                try c.out.appendSlice(c.gpa, &b2);
            } else {
                std.mem.writeInt(u16, &b2, @intCast(roids.len), .big);
                try c.out.appendSlice(c.gpa, &b2);
                for (roids) |o| {
                    std.mem.writeInt(u16, &b2, if (types.binResultOid(o)) 1 else 0, .big);
                    try c.out.appendSlice(c.gpa, &b2);
                }
            }
        } else {
            std.mem.writeInt(u16, &b2, 1, .big);
            try c.out.appendSlice(c.gpa, &b2);
            std.mem.writeInt(u16, &b2, 0, .big);
            try c.out.appendSlice(c.gpa, &b2);
        }

        c.endMessage();
    }

    pub fn writeExecute(c: *Conn, rows: u32) errors.Error!void {
        try c.beginMessage(front.execute);
        try c.out.append(c.gpa, 0);
        var rb: [4]u8 = undefined;
        std.mem.writeInt(u32, &rb, rows, .big);
        try c.out.appendSlice(c.gpa, &rb);
        c.endMessage();
    }

    pub fn writeSyncMessage(c: *Conn) errors.Error!void {
        try c.beginMessage(front.sync);
        c.endMessage();
    }

    pub fn writeFlushMessage(c: *Conn) errors.Error!void {
        try c.beginMessage(front.flush);
        c.endMessage();
    }

    pub fn writeSimpleQuery(c: *Conn, sql: []const u8) errors.Error!void {
        try c.beginMessage(front.query);
        try c.out.appendSlice(c.gpa, sql);
        try c.out.append(c.gpa, 0);
        c.endMessage();
    }

    pub fn writeCopyData(c: *Conn, data: []const u8) errors.Error!void {
        try c.beginMessage(front.copy_data);
        try c.out.appendSlice(c.gpa, data);
        c.endMessage();
        try c.flushOut();
    }

    pub fn writeCopyDone(c: *Conn) errors.Error!void {
        try c.beginMessage(front.copy_done);
        c.endMessage();
        try c.flushOut();
    }

    pub fn writeCopyFail(c: *Conn, err_msg: []const u8) errors.Error!void {
        try c.beginMessage(front.copy_fail);
        try c.out.appendSlice(c.gpa, err_msg);
        try c.out.append(c.gpa, 0);
        c.endMessage();
        try c.flushOut();
    }

    /// Render a comptime query into the connection's reusable buffers.
    pub fn renderQueryArgs(c: *Conn, comptime q: []const u8, args: anytype) errors.Error![]const u8 {
        c.sql_buf.clearRetainingCapacity();
        c.encs_buf.clearRetainingCapacity();
        c.scratch.clearRetainingCapacity();
        var rctx = query.RenderCtx{
            .gpa = c.gpa,
            .sql = &c.sql_buf,
            .encs = &c.encs_buf,
            .scratch = &c.scratch,
        };
        try query.renderQuery(&rctx, q, args);
        return c.sql_buf.items;
    }

    /// Encode positional args for raw SQL (`$1`, `$2`, ... already in the text).
    pub fn encodePositional(c: *Conn, args: anytype) errors.Error!void {
        c.encs_buf.clearRetainingCapacity();
        c.scratch.clearRetainingCapacity();
        var ectx = types.EncodeCtx{
            .gpa = c.gpa,
            .encs = &c.encs_buf,
            .scratch = &c.scratch,
        };
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        inline for (fields) |f| {
            try types.encodeParam(&ectx, @field(args, f.name));
        }
    }

    pub const ExecOptions = struct {
        /// Execute row cap (cursors).
        rows_limit: u32 = 0,
        /// false sends Flush instead of Sync (cursor batches, COPY start).
        use_sync: bool = true,
        prepare: bool = true,
        /// Describe-only: parse/describe, never execute.
        no_execute: bool = false,
        /// Skip decoding; return raw text bytes.
        raw_results: bool = false,
        sink: RowSink = .none,
        suspended: ?*bool = null,
        param_oids_out: ?*std.ArrayList(u32) = null,
        no_sync_terminator: bool = false,
        result_formats: ?[]const u8 = null,
    };

    /// Execute a comptime query on this connection (extended protocol).
    pub fn execQuery(c: *Conn, comptime q: []const u8, args: anytype, eo: ExecOptions) errors.Error!void {
        const Args = @TypeOf(args);
        const sql = try c.renderQueryArgs(q, args);
        if (comptime query.allValues(Args)) {
            const name = comptime query.stmtName(query.finalSql(q, Args));
            try c.execExtended(sql, name, eo);
        } else {
            const name = query.stmtNameRuntime(sql, &c.name_buf);
            try c.execExtended(sql, name, eo);
        }
    }

    /// Execute already-rendered SQL with a pre-decided statement name.
    pub fn execExtended(c: *Conn, sql: []const u8, name: []const u8, eo: ExecOptions) errors.Error!void {
        _ = c.diag_arena.reset(.retain_capacity);
        c.setQueryContext(sql);
        const encs = c.encs_buf.items;

        var oids_stack: [max_cached_params]u32 = undefined;
        var oids: []const u32 = &.{};
        if (encs.len <= max_cached_params) {
            for (encs, 0..) |e, i| oids_stack[i] = e.oid;
            oids = oids_stack[0..encs.len];
        }

        const want_prepare = eo.prepare and name.len > 0;
        var cached_entry: ?*CacheEntry = null;
        if (want_prepare) cached_entry = c.cacheFind(name, oids);
        const cached = cached_entry != null;

        var result_oids: ?[]const u32 = null;
        if (cached_entry) |e| {
            if (e.n_result != unknown_result_cols) {
                result_oids = e.result_oids[0..e.n_result];
            }
        }
        c.last_n_result = 0;
        c.last_result_overflow = true;
        var eo_mut = eo;
        // Describe runs before Bind, so RowDescription always echoes the
        // statement default (text): the decoder must use the formats actually
        // requested in Bind, not the ones reported back.
        if (result_oids) |roids| {
            const n = @min(roids.len, max_cached_columns);
            for (roids[0..n], 0..) |o, i| c.last_result_formats[i] = if (types.binResultOid(o)) 1 else 0;
            eo_mut.result_formats = c.last_result_formats[0..n];
            c.last_exec_format_len = n;
        } else {
            eo_mut.result_formats = null;
            c.last_exec_format_len = 0;
        }

        if (!cached and want_prepare and c.ctx.binary_first_exec and !eo.no_execute) {
            // Two phases on a cache miss: Parse+Describe+Sync learns the result
            // OIDs, then Bind can request binary exactly like a cache hit.
            // Costs one extra round trip, so it is opt-in.
            try c.writeParse(name, sql, oids);
            try c.writeDescribeStatement(name);
            try c.writeSyncMessage();
            try c.flushOut();
            try c.readQueryResults(.{ .sink = .none });

            if (!c.last_result_overflow and c.last_n_result > 0) {
                result_oids = c.last_result_oids[0..c.last_n_result];
            } else {
                result_oids = null;
            }
            if (result_oids) |roids| {
                const nf = @min(roids.len, max_cached_columns);
                for (roids[0..nf], 0..) |o, i| c.last_result_formats[i] = if (types.binResultOid(o)) 1 else 0;
                eo_mut.result_formats = c.last_result_formats[0..nf];
                c.last_exec_format_len = nf;
            } else {
                eo_mut.result_formats = null;
                c.last_exec_format_len = 0;
            }
            // The statement now exists server-side: record it before executing
            // so a later failure cannot make us re-Parse the same name.
            c.cacheInsert(name, oids);

            // Describe again: Execute alone does not repeat RowDescription, and
            // the sink needs the column metadata.
            try c.writeDescribeStatement(name);
            try c.writeBind(name, encs, result_oids);
            try c.writeExecute(eo.rows_limit);
            if (eo.use_sync) {
                try c.writeSyncMessage();
            } else {
                try c.writeFlushMessage();
            }
            try c.flushOut();
            try c.readQueryResults(eo_mut);
            c.cacheInsert(name, oids);
            return;
        }

        if (!cached) {
            try c.writeParse(name, sql, oids);
        }
        try c.writeDescribeStatement(name);
        if (eo.no_execute) {
            try c.writeSyncMessage();
        } else {
            try c.writeBind(name, encs, result_oids);
            try c.writeExecute(eo.rows_limit);
            if (eo.use_sync) {
                try c.writeSyncMessage();
            } else {
                try c.writeFlushMessage();
            }
        }
        try c.flushOut();

        try c.readQueryResults(eo_mut);

        if (!cached and want_prepare) {
            c.cacheInsert(name, oids);
        }
    }

    /// Simple protocol query (multi-statement, no parameters).
    pub fn execSimple(c: *Conn, sql: []const u8, eo: ExecOptions) errors.Error!void {
        _ = c.diag_arena.reset(.retain_capacity);
        c.setQueryContext(sql);
        try c.writeSimpleQuery(sql);
        try c.flushOut();
        try c.readQueryResults(eo);
    }

    pub fn readQueryResults(c: *Conn, eo: ExecOptions) errors.Error!void {
        var guard: usize = 0;
        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.error_response => return c.raiseError(msg.data),
                back.ready_for_query => {
                    c.tx_status = msg.data[0];
                    return;
                },
                back.row_description => try handleRowDescription(c, msg.data, eo.sink),
                back.data_row => try handleDataRow(c, msg.data, eo.sink, eo.raw_results, eo.result_formats),
                back.command_complete => {
                    try handleCommandComplete(c, msg.data, eo.sink);
                    if (eo.no_sync_terminator) return;
                },
                back.parameter_description => try handleParameterDescription(c, msg.data, eo.param_oids_out),
                back.parse_complete, back.bind_complete, back.close_complete, back.no_data, back.empty_query_response => {},
                back.portal_suspended => {
                    if (eo.suspended) |s| {
                        s.* = true;
                        return;
                    }
                    if (eo.no_sync_terminator) return;
                    return error.ProtocolError;
                },
                back.notice_response => c.dispatchNotice(msg.data),
                back.parameter_status => try c.handleParameterStatus(msg.data),
                back.notification_response => {},
                back.negotiate_protocol_version => {},
                back.copy_in_response => {
                    c.in_copy = .in;
                    return;
                },
                back.copy_out_response => {
                    c.in_copy = .out;
                    return;
                },
                else => return error.MessageNotSupported,
            }
            guard += 1;
            if (guard > 100_000_000) return error.ProtocolError;
        }
    }

    /// Read one statement's results inside a pipeline (stops at
    /// CommandComplete/EmptyQuery — no ReadyForQuery until the last one).
    pub fn readStatement(c: *Conn, eo: ExecOptions) errors.Error!void {
        var guard: usize = 0;
        while (true) {
            const msg = try c.readMessage();
            switch (msg.tag) {
                back.error_response => return c.raiseError(msg.data),
                back.command_complete => {
                    try handleCommandComplete(c, msg.data, eo.sink);
                    return;
                },
                back.empty_query_response => return,
                back.row_description => try handleRowDescription(c, msg.data, eo.sink),
                back.data_row => try handleDataRow(c, msg.data, eo.sink, eo.raw_results, eo.result_formats),
                back.parameter_description => try handleParameterDescription(c, msg.data, eo.param_oids_out),
                back.parse_complete, back.bind_complete, back.close_complete, back.no_data => {},
                back.notice_response => c.dispatchNotice(msg.data),
                back.parameter_status => try c.handleParameterStatus(msg.data),
                else => return error.MessageNotSupported,
            }
            guard += 1;
            if (guard > 100_000_000) return error.ProtocolError;
        }
    }

    fn handleParameterDescription(c: *Conn, data: []const u8, out: ?*std.ArrayList(u32)) errors.Error!void {
        const o = out orelse return;
        if (data.len < 2) return error.ProtocolError;
        const n = std.mem.readInt(u16, data[0..2], .big);
        if (n * 4 + 2 > data.len) return error.ProtocolError;
        var i: usize = 2;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const oid = std.mem.readInt(u32, data[i..][0..4], .big);
            i += 4;
            o.append(c.gpa, oid) catch return error.OutOfMemory;
        }
    }

    /// Record result-column OIDs from a RowDescription into per-connection
    /// scratch (consumed by cacheInsert). Sink-independent.
    fn noteResultOids(c: *Conn, data: []const u8) void {
        c.last_n_result = 0;
        c.last_result_overflow = true;
        const n = parseResultOids(data, c.last_result_oids[0..]);
        if (n == 0) return;
        c.last_n_result = n;
        c.last_result_overflow = false;
    }

    fn handleRowDescription(c: *Conn, data: []const u8, sink: RowSink) errors.Error!void {
        c.noteResultOids(data);
        switch (sink) {
            .none => {},
            .rows => |s| {
                if (s.statement_started) {
                    s.columns.items.len = 0;
                    s.rows.items.len = 0;
                    s.values.reset();
                }
                s.statement_started = true;
                try parseRowDescription(data, s.arena, &s.columns);
            },
            .stream => |s| {
                if (s.columns.items.len == 0) {
                    try parseRowDescription(data, s.columns_arena, &s.columns);
                }
            },
        }
    }

    fn handleDataRow(c: *Conn, data: []const u8, sink: RowSink, raw: bool, formats: ?[]const u8) errors.Error!void {
        switch (sink) {
            .none => {},
            .rows => |s| {
                if (s.columns.items.len == 0) return error.ProtocolError;
                s.bytes += data.len;
                if (s.bytes > s.max_bytes) return error.ResultTooLarge;
                const values = try parseDataRow(c, data, s.columns.items, s.values.allocator(), raw, formats);
                try s.rows.append(s.arena, .{ .values = values, .columns = s.columns.items });
            },
            .stream => |s| {
                if (s.columns.items.len == 0) return error.ProtocolError;
                const ra = s.row_arena.allocator();
                const values = try parseDataRow(c, data, s.columns.items, ra, raw, formats);
                try s.cb(s.ctx, s.columns.items, values);
                _ = s.row_arena.reset(.retain_capacity);
            },
        }
    }

    fn handleCommandComplete(c: *Conn, data: []const u8, sink: RowSink) errors.Error!void {
        _ = c;
        switch (sink) {
            .none => {},
            .rows => |s| {
                const tag = data[0 .. std.mem.indexOfScalar(u8, data, 0) orelse data.len];
                s.command_tag = s.arena.dupe(u8, tag) catch return error.OutOfMemory;
                var count: i64 = 0;
                var it = std.mem.splitBackwardsScalar(u8, tag, ' ');
                if (it.next()) |last| {
                    if (std.fmt.parseInt(i64, last, 10)) |v| {
                        count = v;
                    } else |_| {}
                }
                s.count = count;
            },
            .stream => {},
        }
    }

    fn parseRowDescription(data: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(Column)) errors.Error!void {
        if (data.len < 2) return error.ProtocolError;
        const n = std.mem.readInt(u16, data[0..2], .big);
        if (n > 1664) return error.MessageTooLarge;
        var i: usize = 2;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const name_z = std.mem.indexOfScalarPos(u8, data, i, 0) orelse return error.ProtocolError;
            const name = data[i..name_z];
            i = name_z + 1;
            if (i + 18 > data.len) return error.ProtocolError;
            const table_oid = std.mem.readInt(u32, data[i..][0..4], .big);
            const attnum = std.mem.readInt(i16, data[i + 4 ..][0..2], .big);
            const type_oid = std.mem.readInt(u32, data[i + 6 ..][0..4], .big);
            const typlen = std.mem.readInt(i16, data[i + 10 ..][0..2], .big);
            const format = std.mem.readInt(u16, data[i + 16 ..][0..2], .big);
            i += 18;
            try out.append(arena, .{
                .name = arena.dupe(u8, name) catch return error.OutOfMemory,
                .type_oid = type_oid,
                .typlen = typlen,
                .format = format,
                .table_oid = table_oid,
                .attnum = attnum,
            });
        }
    }

    fn parseDataRow(c: *Conn, data: []const u8, columns: []const Column, arena: std.mem.Allocator, raw: bool, formats: ?[]const u8) errors.Error![]Value {
        _ = c;
        if (data.len < 2) return error.ProtocolError;
        const n = std.mem.readInt(u16, data[0..2], .big);
        if (n != columns.len) return error.ProtocolError;
        const values = arena.alloc(Value, n) catch return error.OutOfMemory;
        var i: usize = 2;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (i + 4 > data.len) return error.ProtocolError;
            const len = std.mem.readInt(i32, data[i..][0..4], .big);
            i += 4;
            if (len < -1) return error.ProtocolError;
            if (len == -1) {
                values[k] = .null_;
                continue;
            }
            const l: usize = @intCast(len);
            if (i + l > data.len) return error.ProtocolError;
            const bytes = data[i .. i + l];
            i += l;
            const is_bin = if (formats) |f| (k < f.len and f[k] == 1) else false;
            values[k] = if (raw)
                if (is_bin)
                    .{ .bytea = arena.dupe(u8, bytes) catch return error.OutOfMemory }
                else
                    .{ .text = arena.dupe(u8, bytes) catch return error.OutOfMemory }
            else if (is_bin)
                try types.decodeBinary(arena, columns[k], bytes)
            else
                try types.decodeText(arena, columns[k], bytes);
        }
        return values;
    }
};

/// Opens a raw connection and sends a CancelRequest for the given
/// backend pid/secret (see PostgreSQL docs: "canceling queries in progress").
pub fn sendCancelRequest(ctx: *const ConnCtx, host_idx: usize, pid: u32, secret: u32) errors.Error!void {
    const r = ctx.resolved;

    var stream: std.Io.net.Stream = undefined;
    if (r.unix_path) |path| {
        const ua = std.Io.net.UnixAddress.init(path) catch return error.ConnectFailed;
        stream = std.Io.net.UnixAddress.connect(&ua, ctx.io) catch return error.ConnectFailed;
    } else {
        const host = r.hosts[host_idx];
        const port = if (r.ports.len > host_idx) r.ports[host_idx] else 5432;
        if (std.Io.net.IpAddress.parse(host, port)) |addr_literal| {
            stream = std.Io.net.IpAddress.connect(&addr_literal, ctx.io, .{ .mode = .stream }) catch return error.ConnectFailed;
        } else |_| {
            const hn = std.Io.net.HostName.init(host) catch return error.ConnectFailed;
            stream = std.Io.net.HostName.connect(hn, ctx.io, port, .{ .mode = .stream }) catch return error.ConnectFailed;
        }
    }

    var rbuf: [512]u8 = undefined;
    var wbuf: [512]u8 = undefined;
    var sreader = std.Io.net.Stream.Reader.init(stream, ctx.io, &rbuf);
    var swriter = std.Io.net.Stream.Writer.init(stream, ctx.io, &wbuf);

    var msg: [16]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 16, .big);
    std.mem.writeInt(u32, msg[4..8], cancel_request_code, .big);
    std.mem.writeInt(u32, msg[8..12], pid, .big);
    std.mem.writeInt(u32, msg[12..16], secret, .big);
    swriter.interface.writeAll(&msg) catch {
        stream.close(ctx.io);
        return error.WriteFailed;
    };
    swriter.interface.flush() catch {};
    _ = &sreader;
    stream.close(ctx.io);
}
