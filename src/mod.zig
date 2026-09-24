//! postgres-zig — a complete PostgreSQL driver for Zig, API-compatible with
//! postgres.js (https://github.com/porsager/postgres), zero dependencies
//! (Zig std only).
//!
//! ```zig
//! const std = @import("std");
//! const postgres = @import("postgres-zig").connect;
//!
//! pub fn main() !void {
//!     var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
//!     defer threaded.deinit();
//!     const io = threaded.io();
//!
//!     var db = try postgres(io, std.heap.page_allocator, .{
//!         .url = "postgres://user:pass@localhost:5432/app",
//!     });
//!     defer db.deinit();
//!
//!     // tagged-template equivalent: comptime SQL + runtime params
//!     const users = try db.query(
//!         "select name, age from users where age > {}",
//!         .{18},
//!     );
//!     defer users.deinit();
//! }
//! ```
//!
//! Security model highlights (PLANING.md §13):
//!   * query strings must be comptime — runtime SQL cannot enter the main API;
//!   * interpolated values always become binary protocol parameters ($n);
//!   * dynamic identifiers go through `pg.ident` (validated + quoted);
//!   * the only raw-SQL escape hatches are `pg.raw` and `db.unsafe`,
//!     both explicit and auditable (`deny_unsafe` / `on_unsafe` options);
//!   * SCRAM-SHA-256 with mandatory ServerSignature verification; MD5 and
//!     cleartext are opt-in (`allow_insecure_auth`);
//!   * `sslmode=require/verify_full` always verify certificates (hostname
//!     + chain) — the historical Node.js footgun does not exist here.

const std = @import("std");

pub const errors = @import("error.zig");
pub const options = @import("options.zig");
pub const types = @import("types.zig");
pub const query = @import("query.zig");
pub const conn_mod = @import("connection.zig");
pub const result_mod = @import("result.zig");
pub const pool_mod = @import("pool.zig");
pub const pg_mod = @import("postgres.zig");

pub const connect = pg_mod.connect;
pub const Postgres = pg_mod.Postgres;
pub const Tx = pg_mod.Tx;
pub const Savepoint = pg_mod.Savepoint;
pub const Reserved = pg_mod.Reserved;
pub const Cursor = pg_mod.Cursor;
pub const CopyWriter = pg_mod.CopyWriter;
pub const CopyReader = pg_mod.CopyReader;
pub const Listener = pg_mod.Listener;

pub const Options = options.Options;
pub const SslMode = options.SslMode;
pub const TargetSessionAttrs = options.TargetSessionAttrs;
pub const ColumnTransform = options.ColumnTransform;
pub const QueryOptions = pg_mod.QueryOptions;
pub const UnsafeOptions = pg_mod.UnsafeOptions;
pub const EndOptions = pg_mod.EndOptions;

pub const Result = result_mod.Result;
pub const Row = result_mod.Row;
pub const Describe = result_mod.Describe;
pub const Column = types.Column;
pub const Value = types.Value;
pub const valueToText = types.valueToText;
pub const State = result_mod.State;

pub const Diagnostics = errors.Diagnostics;
pub const Error = errors.Error;

pub const Timestamp = types.Timestamp;
pub const Date = types.Date;
pub const Time = types.Time;
pub const Interval = types.Interval;
pub const daysFromCivil = types.daysFromCivil;
pub const civilFromDays = types.civilFromDays;

pub const frag = query.frag;
pub const fragEmpty = query.fragEmpty;
pub const Frag = query.TypedFrag;
pub const ident = query.ident;
pub const Ident = query.Ident;
pub const raw = query.raw;
pub const Raw = query.Raw;
pub const valueList = query.valueList;
pub const ValueList = query.TypedValueList;
pub const insert = query.insert;
pub const insertAll = query.insertAll;
pub const insertMany = query.insertMany;
pub const Insert = query.TypedInsert;
pub const InsertMany = query.TypedInsertMany;
pub const update = query.update;
pub const updateAll = query.updateAll;
pub const Update = query.TypedUpdate;
pub const cols = query.cols;
pub const Cols = query.TypedCols;

pub const typed = types.typed;
pub const Typed = types.Typed;
pub const bytea = types.bytea;
pub const Bytea = types.Bytea;
pub const json = types.json;
pub const Json = types.Json;

pub const Conn = conn_mod.Conn;
pub const ConnCtx = conn_mod.ConnCtx;
pub const Notification = conn_mod.Conn.Notification;

test {
    std.testing.refAllDecls(@This());
    _ = @import("error.zig");
    _ = @import("options.zig");
    _ = @import("types.zig");
    _ = @import("query.zig");
    _ = @import("result.zig");
    _ = @import("scram.zig");
}
