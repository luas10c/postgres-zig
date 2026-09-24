const std = @import("std");
const errors = @import("error.zig");

pub const SslMode = enum {
    disable,
    prefer,
    /// TLS required. Unlike the historical Node.js footgun, `require`
    /// ALWAYS verifies the server certificate (chain + hostname).
    require,
    verify_ca,
    verify_full,

    pub fn fromString(s: []const u8) ?SslMode {
        inline for (@typeInfo(SslMode).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @field(SslMode, f.name);
        }
        return null;
    }
};

pub const TargetSessionAttrs = enum { any, read_write, read_only, primary, standby, prefer_standby };

pub const ColumnTransform = enum { none, camel, pascal, kebab, snake };

pub const NoticeHook = *const fn (user_data: ?*anyopaque, diag: *const errors.Diagnostics) void;
pub const ParameterHook = *const fn (user_data: ?*anyopaque, name: []const u8, value: []const u8) void;
pub const UnsafeHook = *const fn (user_data: ?*anyopaque, query: []const u8) anyerror!void;

pub const Options = struct {
    /// Connection URL: `postgres://user:pass@host1:port[,host2:port]/db?sslmode=...`
    url: ?[]const u8 = null,

    hosts: []const []const u8 = &.{"localhost"},
    ports: []const u16 = &.{5432},
    /// Unix socket directory path (usually "/tmp" or "/var/run/postgresql").
    path: ?[]const u8 = null,

    database: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    ssl: SslMode = .prefer,
    ssl_negotiation: enum { postgres, direct } = .postgres,

    max: usize = 10,
    /// Max lifetime per connection; jittered like postgres.js (default 45-90 min).
    max_lifetime: ?u64 = null,
    /// nanoseconds
    idle_timeout: ?u64 = null,
    connect_timeout: u64 = 30 * std.time.ns_per_s,
    /// Default per-query timeout (may be overridden per call). nanoseconds.
    query_timeout: ?u64 = null,

    prepare: bool = true,
    /// Describe first execution of a prepared statement so it can request
    /// binary results too (one extra round trip per new statement).
    binary_first_exec: bool = false,
    target_session_attrs: TargetSessionAttrs = .any,
    application_name: []const u8 = "postgres-zig",
    /// Extra startup parameters (`key`, `value` pairs). Keys are validated.
    parameters: []const [2][]const u8 = &.{},

    transform_column: ColumnTransform = .none,

    /// Dynamic password source (tokens / rotating credentials).
    password_callback: ?struct {
        user_data: ?*anyopaque = null,
        fn_: *const fn (?*anyopaque) errors.Error![]const u8,
    } = null,

    on_notice: ?NoticeHook = null,
    on_notice_data: ?*anyopaque = null,
    on_parameter: ?ParameterHook = null,
    on_parameter_data: ?*anyopaque = null,
    on_unsafe: ?UnsafeHook = null,
    on_unsafe_data: ?*anyopaque = null,
    /// Reject every `db.unsafe()` / `pg.raw()` call (recommended in production).
    deny_unsafe: bool = false,
    /// Opt-in for MD5 / cleartext password auth (insecure; SCRAM is default).
    allow_insecure_auth: bool = false,

    max_message_bytes: usize = 512 * 1024 * 1024,
    /// Maximum bytes materialized by a single query() result (use cursors beyond).
    max_result_bytes: usize = 1024 * 1024 * 1024,

    /// Environment variables for PG* fallbacks (psql-compatible).
    /// Pass `init.environ_map` from `pub fn main(init: std.process.Init)`.
    /// When null, env fallbacks are skipped.
    environ: ?*const std.process.Environ.Map = null,
};

/// Fully resolved connection configuration (options + url + env), allocated.
pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []const []const u8,
    ports: []const u16,
    unix_path: ?[]const u8,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    application_name: []const u8,
    parameters: []const [2][]const u8,
    opts: Options,

    pub fn deinit(r: *Resolved) void {
        r.arena.deinit();
    }
};

fn percentDecode(arena: std.mem.Allocator, s: []const u8) errors.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len + 1 and i + 2 <= s.len - 1 + 1) {
            if (i + 2 < s.len) {
                const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidUrl;
                const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.InvalidUrl;
                try out.append(arena, hi * 16 + lo);
                i += 2;
            } else return error.InvalidUrl;
        } else {
            try out.append(arena, s[i]);
        }
    }
    return out.items;
}

fn envOr(res: *const Options, arena: std.mem.Allocator, comptime names: []const []const u8, fallback: []const u8) errors.Error![]const u8 {
    const map = res.environ orelse return fallback;
    inline for (names) |n| {
        if (map.get(n)) |v| {
            if (v.len > 0) return arena.dupe(u8, v) catch return error.OutOfMemory;
        }
    }
    return fallback;
}

/// Resolve URL + options + environment into a `Resolved`.
pub fn resolve(gpa: std.mem.Allocator, o: Options) errors.Error!Resolved {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var hosts = std.ArrayList([]const u8).empty;
    var ports = std.ArrayList(u16).empty;

    var database: []const u8 = "";
    var username: []const u8 = "";
    var password: []const u8 = "";
    var ssl: SslMode = o.ssl;
    var application_name: []const u8 = o.application_name;
    var connect_timeout: u64 = o.connect_timeout;
    var idle_timeout: ?u64 = o.idle_timeout;
    var target: TargetSessionAttrs = o.target_session_attrs;
    var unix_path: ?[]const u8 = null;
    var path_explicit = false;

    if (o.path) |p| {
        unix_path = try arena.dupe(u8, p);
        path_explicit = true;
    }

    var used_explicit_hosts = false;
    if (o.hosts.len > 0 and !std.mem.eql(u8, o.hosts[0], "")) {
        for (o.hosts) |h| try hosts.append(arena, try arena.dupe(u8, h));
        for (o.ports) |p| try ports.append(arena, p);
        while (ports.items.len < hosts.items.len) try ports.append(arena, 5432);
        used_explicit_hosts = true;
    }

    if (o.url) |raw_url| {
        var url = raw_url;
        if (std.mem.startsWith(u8, url, "postgres://")) {
            url = url["postgres://".len..];
        } else if (std.mem.startsWith(u8, url, "postgresql://")) {
            url = url["postgresql://".len..];
        } else return error.InvalidUrl;

        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, url, '?')) |qi| {
            query = url[qi + 1 ..];
            url = url[0..qi];
        }

        if (std.mem.indexOfScalar(u8, url, '/')) |si| {
            database = try arena.dupe(u8, url[si + 1 ..]);
            url = url[0..si];
        }

        if (std.mem.lastIndexOfScalar(u8, url, '@')) |ai| {
            const userinfo = url[0..ai];
            url = url[ai + 1 ..];
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |ci| {
                username = try percentDecode(arena, userinfo[0..ci]);
                password = try percentDecode(arena, userinfo[ci + 1 ..]);
            } else {
                username = try percentDecode(arena, userinfo);
            }
        }

        if (url.len > 0) {
            hosts.clearRetainingCapacity();
            ports.clearRetainingCapacity();
            var it = std.mem.splitScalar(u8, url, ',');
            while (it.next()) |hp| {
                if (hp.len == 0) continue;
                if (hp[0] == '/') {
                    unix_path = try arena.dupe(u8, hp);
                    continue;
                }
                var host = hp;
                var port: u16 = 5432;
                if (std.mem.lastIndexOfScalar(u8, hp, ':')) |ci| {
                    if (std.mem.indexOfScalar(u8, hp, ']')) |bi| {
                        if (ci > bi) {
                            host = hp[0..ci];
                            port = std.fmt.parseInt(u16, hp[ci + 1 ..], 10) catch return error.InvalidUrl;
                        }
                    } else {
                        host = hp[0..ci];
                        port = std.fmt.parseInt(u16, hp[ci + 1 ..], 10) catch return error.InvalidUrl;
                    }
                }
                if (host.len > 0) {
                    try hosts.append(arena, try arena.dupe(u8, host));
                    try ports.append(arena, port);
                }
            }
            used_explicit_hosts = true;
        }

        var pit = std.mem.splitScalar(u8, query, '&');
        while (pit.next()) |kv_raw| {
            if (kv_raw.len == 0) continue;
            var kv = kv_raw;
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const key = kv[0..eq];
            const val_raw = kv[eq + 1 ..];
            _ = &kv;
            const val = try percentDecode(arena, val_raw);
            if (std.mem.eql(u8, key, "sslmode")) {
                ssl = SslMode.fromString(val) orelse return error.InvalidUrl;
            } else if (std.mem.eql(u8, key, "application_name")) {
                application_name = val;
            } else if (std.mem.eql(u8, key, "connect_timeout")) {
                connect_timeout = @as(u64, std.fmt.parseInt(u32, val, 10) catch return error.InvalidUrl) * std.time.ns_per_s;
            } else if (std.mem.eql(u8, key, "idle_timeout")) {
                idle_timeout = @as(u64, std.fmt.parseInt(u32, val, 10) catch return error.InvalidUrl) * std.time.ns_per_s;
            } else if (std.mem.eql(u8, key, "target_session_attrs")) {
                target = std.meta.stringToEnum(TargetSessionAttrs, val) orelse return error.InvalidUrl;
            }
        }
    }

    if (username.len == 0) username = try envOr(&o, arena, &.{ "PGUSERNAME", "PGUSER" }, "");
    if (password.len == 0) password = try envOr(&o, arena, &.{"PGPASSWORD"}, "");
    if (database.len == 0) database = try envOr(&o, arena, &.{"PGDATABASE"}, "");
    if (application_name.len == 0 or std.mem.eql(u8, application_name, "postgres-zig")) {
        const env_app = try envOr(&o, arena, &.{"PGAPPNAME"}, "");
        if (env_app.len > 0) application_name = env_app;
    }
    if (!path_explicit and unix_path == null) {
        if (o.environ) |map| {
            if (map.get("PGHOST")) |h| {
                if (h.len > 0 and h[0] == '/') {
                    unix_path = try arena.dupe(u8, h);
                }
            }
        }
    }
    if (!used_explicit_hosts and unix_path == null) {
        const env_host = try envOr(&o, arena, &.{"PGHOST"}, "localhost");
        hosts.clearRetainingCapacity();
        ports.clearRetainingCapacity();
        try hosts.append(arena, env_host);
        try ports.append(arena, std.fmt.parseInt(u16, try envOr(&o, arena, &.{"PGPORT"}, "5432"), 10) catch 5432);
    }
    if (o.ssl == .prefer) {
        if (o.environ) |map| {
            if (map.get("PGSSLMODE")) |m| {
                if (SslMode.fromString(m)) |mode| ssl = mode;
            }
        }
    }
    if (o.connect_timeout == 30 * std.time.ns_per_s) {
        if (o.environ) |map| {
            if (map.get("PGCONNECT_TIMEOUT")) |v| {
                if (std.fmt.parseInt(u32, v, 10)) |secs| {
                    connect_timeout = @as(u64, secs) * std.time.ns_per_s;
                } else |_| {}
            }
        }
    }

    if (hosts.items.len == 0 and unix_path == null) return error.InvalidUrl;
    if (username.len == 0) return error.InvalidUrl;
    if (database.len == 0) database = username;

    const pw_copy = try arena.dupe(u8, password);

    return .{
        .arena = arena_state,
        .hosts = hosts.items,
        .ports = ports.items,
        .unix_path = unix_path,
        .database = database,
        .username = username,
        .password = pw_copy,
        .application_name = application_name,
        .parameters = o.parameters,
        .opts = o,
    };
}

test "resolve url" {
    var r = try resolve(std.testing.allocator, .{
        .url = "postgres://alice:pw%40x@host1:5433,host2/mydb?sslmode=require",
    });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.hosts.len);
    try std.testing.expectEqualStrings("host1", r.hosts[0]);
    try std.testing.expectEqual(@as(u16, 5433), r.ports[0]);
    try std.testing.expectEqualStrings("host2", r.hosts[1]);
    try std.testing.expectEqualStrings("alice", r.username);
    try std.testing.expectEqualStrings("pw@x", r.password);
    try std.testing.expectEqualStrings("mydb", r.database);
    try std.testing.expectEqual(SslMode.require, r.opts.ssl);
}
