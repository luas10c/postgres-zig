//! Integration tests — run against a live PostgreSQL:
//!   zig build test-integration
//!
//! Connection: PG_URL env var, or defaults to the local docker container
//! (postgres:password@localhost:5432). Tests are SKIPPED (not failed) when
//! no server is reachable.
//!
//! Everything runs inside a dedicated `pgz_test` schema — no user data is touched.

const std = @import("std");
const postgres_mod = @import("postgres-zig");
const postgres = postgres_mod.connect;

var skipped = false;

fn url() []const u8 {
    return "postgres://postgres:password@localhost:5432/postgres";
}

fn connectDb(io: std.Io, gpa: std.mem.Allocator) !*postgres_mod.Postgres {
    const db = postgres(io, gpa, .{
        .url = url(),
        .max = 4,
        .idle_timeout = 5 * std.time.ns_per_s,
    }) catch |e| switch (e) {
        error.ConnectFailed, error.UnknownHostName => {
            skipped = true;
            return error.SkipDbUnavailable;
        },
        else => return e,
    };
    return db;
}

test {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    var db = connectDb(io, gpa) catch |e| switch (e) {
        error.SkipDbUnavailable => {
            std.debug.print("\n== SKIP: no PostgreSQL reachable at {s} ==\n", .{url()});
            return;
        },
        else => return e,
    };
    defer db.deinit();

    std.debug.print("\n== postgres-zig integration @ {s} ==\n", .{url()});

    // setup: dedicated schema -------------------------------------------
    {
        var res = try db.unsafe(
            \\create schema if not exists pgz_test;
            \\drop table if exists pgz_test.users;
            \\drop table if exists pgz_test.copytest;
            \\create table pgz_test.users (
            \\  id serial primary key,
            \\  name text not null,
            \\  age int,
            \\  meta jsonb,
            \\  tags text[],
            \\  nums int[],
            \\  created timestamptz default now()
            \\);
            \\create table pgz_test.copytest (name text, age int);
        ,
            .{},
            .{},
        );
        res.deinit();
    }

    // comptime query + params + returning ----------------------------------
    {
        var ins = try db.query(
            "insert into pgz_test.users (name, age) values ({}, {}) returning id, name, age",
            .{ "Murray", 68 },
        );
        defer ins.deinit();
        try std.testing.expectEqual(@as(i64, 1), ins.count);
        const first = ins.first().?;
        const id = try first.get(i64, "id");
        try std.testing.expectEqual(@as(i64, 1), id);
        try std.testing.expectEqualStrings("Murray", try first.get([]const u8, "name"));
        try std.testing.expectEqual(@as(i32, 68), try first.get(i32, "age"));
    }

    std.debug.print("{s}\n", .{"STEP to-user"});
    // .to(User) comptime decode -------------------------------------------
    {
        var res = try db.query("select id, name, age from pgz_test.users where age > {}", .{18});
        defer res.deinit();
        const UserT = struct { id: i64, name: []const u8, age: ?i32 };
        const users = try res.to(UserT);
        try std.testing.expectEqual(@as(usize, 1), users.len);
        try std.testing.expectEqualStrings("Murray", users[0].name);
        try std.testing.expectEqual(@as(i32, 68), users[0].age.?);
    }

    std.debug.print("{s}\n", .{"STEP null"});
    // null handling ---------------------------------------------------------
    {
        var res = try db.query(
            "insert into pgz_test.users (name, age) values ({}, {}) returning age",
            .{ "NoAge", null },
        );
        defer res.deinit();
        const age: ?i32 = try res.first().?.get(?i32, "age");
        try std.testing.expectEqual(@as(?i32, null), age);
    }

    std.debug.print("{s}\n", .{"STEP types"});
    // types battery -----------------------------------------------------------
    {
        var res = try db.query(
            \\select
            \\  1::int2 as i2, 2::int4 as i4, 3::int8 as i8,
            \\  1.5::float4 as f4, 2.5::float8 as f8, true as b,
            \\  'hi'::text as t, 'bytes'::bytea as by,
            \\  '2026-09-23'::date as d, '2026-09-23 10:00:00'::timestamp as ts,
            \\  '2026-09-23 10:00:00+00'::timestamptz as tstz,
            \\  '12.50'::numeric as num,
            \\  '{{"a":1}}'::jsonb as js,
            \\  '{{1,2,NULL,4}}'::int[] as arr,
            \\  '{{"x","y"}}'::text[] as tarr,
            \\  gen_random_uuid()::text as uuid_text,
            \\  '01:02:03'::time as tm
        ,
            .{},
        );
        defer res.deinit();
        const row = res.first().?;
        try std.testing.expectEqual(@as(i64, 1), try row.get(i64, "i2"));
        try std.testing.expectEqual(@as(i64, 2), try row.get(i64, "i4"));
        try std.testing.expectEqual(@as(i64, 3), try row.get(i64, "i8"));
        try std.testing.expectEqual(@as(f64, 1.5), try row.get(f64, "f4"));
        try std.testing.expectEqual(@as(f64, 2.5), try row.get(f64, "f8"));
        try std.testing.expectEqual(true, try row.get(bool, "b"));
        try std.testing.expectEqualStrings("hi", try row.get([]const u8, "t"));
        try std.testing.expectEqualStrings("bytes", try row.get([]const u8, "by"));
        try std.testing.expectEqualStrings("12.50", try row.get([]const u8, "num"));
        try std.testing.expectEqualStrings("{\"a\": 1}", try row.get([]const u8, "js"));
        try std.testing.expectEqualStrings("01:02:03", try row.get([]const u8, "tm"));

        // date decode
        const date = try row.get(postgres_mod.Date, "d");
        const civil = postgres_mod.civilFromDays(date.days + postgres_mod.types.days_from_1970_to_2000);
        try std.testing.expectEqual(@as(i32, 2026), civil.y);
        try std.testing.expectEqual(@as(u8, 9), civil.m);
        try std.testing.expectEqual(@as(u8, 23), civil.d);

        // timestamp decode
        const ts = try row.get(postgres_mod.Timestamp, "ts");
        const c2 = postgres_mod.civilFromDays(@intCast(@divFloor(ts.usec, 86_400 * std.time.us_per_s) + postgres_mod.types.days_from_1970_to_2000));
        try std.testing.expectEqual(@as(i32, 2026), c2.y);

        // int array
        const arr = try row.get([]?i64, "arr");
        try std.testing.expectEqual(@as(usize, 4), arr.len);
        try std.testing.expectEqual(@as(i64, 1), arr[0].?);
        try std.testing.expectEqual(@as(?i64, null), arr[2]);
        try std.testing.expectEqual(@as(i64, 4), arr[3].?);

        // text array
        const tarr = try row.get([]const []const u8, "tarr");
        try std.testing.expectEqual(@as(usize, 2), tarr.len);
        try std.testing.expectEqualStrings("x", tarr[0]);
    }

    std.debug.print("{s}\n", .{"STEP binary-params"});
    // binary params: arrays, json, timestamps ------------------------------------
    {
        var res = try db.query(
            "insert into pgz_test.users (name, age, meta, tags, nums) values ({}, {}, {}, {}, {}) returning id",
            .{ "Binary", 1, postgres_mod.json(.{ .ok = true }), &[_][]const u8{ "a", "b c" }, &[_]i32{ 1, 2, 3 } },
        );
        defer res.deinit();
        try std.testing.expect(res.first() != null);

        var back = try db.query("select tags, nums, meta from pgz_test.users where name = {}", .{"Binary"});
        defer back.deinit();
        const row = back.first().?;
        const tags = try row.get([]const []const u8, "tags");
        try std.testing.expectEqualStrings("a", tags[0]);
        try std.testing.expectEqualStrings("b c", tags[1]);
        const nums = try row.get([]const ?i64, "nums");
        try std.testing.expectEqual(@as(i64, 3), nums[2].?);
        try std.testing.expect(std.mem.indexOf(u8, try row.get([]const u8, "meta"), "true") != null);
    }

    std.debug.print("{s}\n", .{"STEP frags"});
    // fragments + helpers ----------------------------------------------------------
    {
        const older_than = postgres_mod.frag("and age > {}", .{1});
        var res = try db.query(
            "select id from pgz_test.users where name is not null {}",
            .{older_than},
        );
        defer res.deinit();
        try std.testing.expect(res.rows.len >= 1);

        var by_ident = try db.query(
            "select {} from {} where id = {}",
            .{ try postgres_mod.ident("name"), try postgres_mod.ident("pgz_test.users"), 1 },
        );
        defer by_ident.deinit();
        try std.testing.expectEqualStrings("Murray", try by_ident.first().?.get([]const u8, "name"));

        var inlist = try db.query(
            "select count(*) as c from pgz_test.users where age in {}",
            .{postgres_mod.valueList(.{ 68, 1 })},
        );
        defer inlist.deinit();
        try std.testing.expectEqual(@as(i64, 2), try inlist.first().?.get(i64, "c"));

        const NewUserT = struct { name: []const u8, age: i32 };
        var ins = try db.query(
            "insert into pgz_test.users {} returning id",
            .{postgres_mod.insert(NewUserT{ .name = "InsertHelper", .age = 5 }, .{ "name", "age" })},
        );
        defer ins.deinit();
        try std.testing.expect(ins.first() != null);

        var upd = try db.query(
            "update pgz_test.users set {} where name = {} returning id",
            .{ postgres_mod.update(NewUserT{ .name = "x", .age = 6 }, .{"age"}), "InsertHelper" },
        );
        defer upd.deinit();
        try std.testing.expectEqual(@as(i64, 1), upd.count);
    }

    std.debug.print("{s}\n", .{"STEP tx"});
    // transactions + savepoints ------------------------------------------------------
    {
        var tx = try db.begin("");
        errdefer tx.rollback() catch {};

        _ = try tx.query("insert into pgz_test.users (name, age) values ({}, {})", .{ "TxUser", 99 });
        var sp = try tx.savepoint("sp1");
        _ = try tx.query("insert into pgz_test.users (name, age) values ({}, {})", .{ "SpUser", 100 });
        try sp.rollback();
        try tx.commit();

        var res = try db.query("select count(*) as c from pgz_test.users where name = {}", .{"TxUser"});
        defer res.deinit();
        try std.testing.expectEqual(@as(i64, 1), try res.first().?.get(i64, "c"));

        var res2 = try db.query("select count(*) as c from pgz_test.users where name = {}", .{"SpUser"});
        defer res2.deinit();
        try std.testing.expectEqual(@as(i64, 0), try res2.first().?.get(i64, "c"));

        // auto-rollback on error via beginFn
        const Failer = struct {
            fn run(_: void, txn: *postgres_mod.Tx) !void {
                _ = try txn.query("insert into pgz_test.users (name, age) values ({}, {})", .{ "Rolled", 1 });
                return error.Deliberate;
            }
        };
        try std.testing.expectError(error.Deliberate, db.beginFn({}, Failer.run));
        var res3 = try db.query("select count(*) as c from pgz_test.users where name = {}", .{"Rolled"});
        defer res3.deinit();
        try std.testing.expectEqual(@as(i64, 0), try res3.first().?.get(i64, "c"));
    }

    std.debug.print("{s}\n", .{"STEP errors"});
    // error handling: PgError + diagnostics --------------------------------------------
    {
        const bad = db.query("select * from pgz_test.nope", .{});
        try std.testing.expectError(error.PgError, bad);
        const d = db.lastDiagnostics();
        try std.testing.expect(d.isUndefinedTable());
        try std.testing.expect(std.mem.indexOf(u8, d.message, "pgz_test.nope") != null);
        try std.testing.expect(std.mem.indexOf(u8, d.query, "pgz_test.nope") != null);

        // connection is healthy afterwards
        var ok = try db.query("select 1 as x", .{});
        defer ok.deinit();
        try std.testing.expectEqual(@as(i64, 1), try ok.first().?.get(i64, "x"));
    }

    std.debug.print("{s}\n", .{"STEP cursor"});
    // cursor ----------------------------------------------------------------------------
    {
        var cur = try db.cursor(10, "select id from pgz_test.users order by id", .{});
        var total: usize = 0;
        while (try cur.next()) |batch| {
            total += batch.len;
        }
        try cur.close();
        try std.testing.expect(total >= 4);

        // early close (sql.CLOSE)
        var cur2 = try db.cursor(1, "select id from pgz_test.users order by id", .{});
        _ = try cur2.next();
        try cur2.close();
    }

    std.debug.print("{s}\n", .{"STEP foreach"});
    // forEach streaming ------------------------------------------------------------------
    {
        var count: usize = 0;
        try db.forEach(
            &count,
            struct {
                fn cb(c: *usize, row: postgres_mod.Row) !void {
                    _ = row;
                    c.* += 1;
                }
            }.cb,
            "select id from pgz_test.users",
            .{},
        );
        try std.testing.expect(count >= 4);
    }

    std.debug.print("{s}\n", .{"STEP copy"});
    // COPY in/out ------------------------------------------------------------------------
    {
        var w = try db.writable("copy pgz_test.copytest from stdin", .{});
        try w.writeAll("Alice\t30\nBob\t25\n");
        const copied = try w.end();
        try std.testing.expectEqual(@as(i64, 2), copied);

        var r = try db.readable("copy pgz_test.copytest to stdout", .{});
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        while (try r.next()) |chunk| {
            try out.appendSlice(gpa, chunk);
        }
        try std.testing.expect(std.mem.startsWith(u8, out.items, "Alice\t30"));
    }

    std.debug.print("{s}\n", .{"STEP pipeline"});
    // pipeline ----------------------------------------------------------------------------
    {
        const results = try db.pipeline(.{
            .{ "select 1 as x", .{} },
            .{ "insert into pgz_test.users (name, age) values ({}, {}) returning id", .{ "Piped", 7 } },
            .{ "select 2 as y", .{} },
        });
        defer {
            for (results) |*r| r.deinit();
            gpa.free(results);
        }
        try std.testing.expectEqual(@as(usize, 3), results.len);
        try std.testing.expectEqual(@as(i64, 1), try results[0].first().?.get(i64, "x"));
        try std.testing.expectEqual(@as(i64, 2), try results[2].first().?.get(i64, "y"));
        try std.testing.expect(results[1].first() != null);
    }

    std.debug.print("{s}\n", .{"STEP describe"});
    // describe ------------------------------------------------------------------------------
    {
        var d = try db.describe("select id, name from pgz_test.users where id = {}", .{@as(i64, 1)});
        defer d.deinit();
        try std.testing.expectEqual(@as(usize, 2), d.columns.len);
        try std.testing.expectEqualStrings("id", d.columns[0].name);
        try std.testing.expect(d.param_oids.len == 1);
        try std.testing.expect(std.mem.startsWith(u8, d.statement_name, "pgz_"));
    }

    std.debug.print("{s}\n", .{"STEP simple"});
    // simple multi-statement -----------------------------------------------------------------
    {
        var res = try db.simple("select 1 as a; select 2 as b");
        defer res.deinit();
        try std.testing.expectEqualStrings("SELECT 1", res.command_tag);
    }

    std.debug.print("{s}\n", .{"STEP reuse"});
    // prepared statement reuse (cache hit path) -----------------------------------------------
    {
        for (0..10) |i| {
            var res = try db.query("select {}::int8 as v", .{@as(i64, @intCast(i))});
            defer res.deinit();
            try std.testing.expectEqual(@as(i64, @intCast(i)), try res.first().?.get(i64, "v"));
        }
    }

    std.debug.print("{s}\n", .{"STEP concurrency"});
    // concurrency: pool with multiple threads ---------------------------------------------------
    {
        const Worker = struct {
            fn run(pdb: *postgres_mod.Postgres) void {
                for (0..20) |_| {
                    var res = pdb.query("select 1 as x", .{}) catch continue;
                    defer res.deinit();
                }
            }
        };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*t| {
            t.* = try std.Thread.spawn(.{}, Worker.run, .{db});
        }
        for (&threads) |*t| t.join();
    }

    std.debug.print("{s}\n", .{"STEP listen"});
    // listen/notify ------------------------------------------------------------------------------
    {
        var l = try db.listen("pgz_chan");
        _ = try db.notify("pgz_chan", "{\"hello\":\"world\"}");
        const n = try l.poll();
        try std.testing.expectEqualStrings("pgz_chan", n.channel);
        try std.testing.expect(std.mem.indexOf(u8, n.payload, "world") != null);
        l.close();
    }

    std.debug.print("{s}\n", .{"STEP injection"});
    // sql injection: payloads arrive as parameters, never as SQL -----------------------------------
    {
        var res = try db.query("select {}::text as t", .{"'; drop table x; --"});
        defer res.deinit();
        try std.testing.expectEqualStrings("'; drop table x; --", try res.first().?.get([]const u8, "t"));
    }

    // max_result_bytes guard ------------------------------------------------------
    {
        var small = try connectDb(io, gpa);
        small.max_result_bytes = 64;
        defer small.deinit();
        try std.testing.expectError(
            error.ResultTooLarge,
            small.query("select id, name from pgz_test.users", .{}),
        );
    }

    std.debug.print("== integration: ALL PASSED ==\n", .{});
}
