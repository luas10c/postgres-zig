# postgres-zig

Driver PostgreSQL completo para Zig, inspirado no [postgres.js](https://github.com/porsager/postgres) (porsager/postgres) — mesma API e ergonomia, reimaginadas nos idiomas de Zig, com garantias de segurança em **tempo de compilação**.

- **Zero dependências externas** — apenas a `std` do Zig
- **Queries seguras por construção** — SQL `comptime`, valores sempre como parâmetros `$n` (SQL injection vira erro de compilação)
- **Protocolo binário**, prepared statements com cache, pool de conexões
- Transações, cursors, `COPY`, `LISTEN/NOTIFY`, pipeline, tipos customizados

Requer **Zig 0.16+** e **PostgreSQL 13+**.

## Instalação

Adicione como dependência no `build.zig.zon` do seu projeto:

```zig
.dependencies = .{
    .@"postgres-zig" = .{ .path = "../postgres-zig" },
},
```

E no `build.zig`:

```zig
const pg_dep = b.dependency("postgres-zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("postgres-zig", pg_dep.module("postgres-zig"));
```

## Quickstart

```zig
const std = @import("std");
const postgres = @import("postgres-zig").connect;

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try postgres(io, std.heap.page_allocator, .{
        .url = "postgres://user:pass@localhost:5432/app",
    });
    defer db.deinit();

    // equivalente ao tagged template: SQL comptime + valores runtime
    var users = try db.query(
        "select id, name, age from users where age > {} order by id",
        .{18},
    );
    defer users.deinit();

    for (users.rows) |row| {
        const name = try row.get([]const u8, "name");
        std.debug.print("{s}\n", .{name});
    }
}
```

Sem URL, as variáveis de ambiente do `psql` são usadas (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, ...).

## Queries

Cada `{}` na string (que **precisa** ser `comptime`) vira um parâmetro `$n`. Valores nunca entram no texto SQL:

```zig
var ins = try db.query(
    "insert into users (name, age) values ({}, {}) returning id, name, age",
    .{ "Murray", 68 },
);
defer ins.deinit();
try std.testing.expectEqual(@as(i64, 1), ins.count);

const first = ins.first().?; // ?Row
const id = try first.get(i64, "id");
const name = try first.get([]const u8, "name");
const age = try first.get(?i32, "age"); // NULL vira optional
```

Tipos aceitos como parâmetro: `bool`, `i16/i32/i64`, `u16/u32`, `f32/f64`, `[]const u8`, `?T`, enums, slices (viram arrays PG), `pg.Date/Time/Timestamp/Interval`, `[16]u8` (uuid), `pg.json(v)`, `pg.bytea(b)` e `pg.typed(v, oid)`.

### Decode direto para struct

```zig
const User = struct { id: i64, name: []const u8, age: ?i32 };
const users = try res.to(User); // []User, alocado na arena do Result
```

## Queries dinâmicas (fragmentos)

Fragmentos são valores — condicionais, identificadores e listas sem concatenar strings:

```zig
const pg = @import("postgres-zig"); // namespace p/ helpers

// fragmento condicional (equivale ao sql`` aninhado)
const older_than = pg.frag("and age > {}", .{50});
var rows = try db.query(
    "select * from users where name is not null {}",
    .{if (filtrar) older_than else pg.fragEmpty()},
);

// identificador dinâmico (ex.: ORDER BY) — com quoting seguro
var r = try db.query("select {} from {}", .{
    try pg.ident("name"),
    try pg.ident("users"),
}); // nomes com ponto viram "schema"."table"

// WHERE IN
var r2 = try db.query("select * from users where age in {}",
    .{pg.valueList(.{ 68, 1 })});

// INSERT/UPDATE a partir de struct
var r3 = try db.query("insert into users {} returning id",
    .{pg.insert(user, .{ "name", "age" })}); // ou pg.insertAll(user)
var r4 = try db.query("update users set {} where id = {}",
    .{ pg.update(user, .{"age"}), 1 });

// escape hatch explícito e auditável
var r5 = try db.query("select 1 where {}", .{pg.raw("1=1")});
```

`{{` e `}}` escapam chaves literais (ex.: `'{{1,2}}'` vira `'{1,2}'`).

## Transações

```zig
// estilo RAII
var tx = try db.begin("");
errdefer tx.rollback() catch {};
_ = try tx.query("update users set age = {} where id = {}", .{ 69, 1 });
try tx.commit();

// estilo callback (commit automático, rollback no erro)
try db.beginFn({}, struct {
    fn run(_: void, txn: *pg.Tx) !void {
        _ = try txn.query("insert into users (name) values ({})", .{"Ana"});
    }
}.run);

// savepoints + two-phase commit
var sp = try tx.savepoint("sp1");
try sp.rollback(); // ou try sp.release();
try tx.prepareTransaction("gid-123"); // PREPARE TRANSACTION
```

## Cursor, streaming e pipeline

```zig
// lotes de N linhas (ideal p/ resultados grandes)
var cur = try db.cursor(100, "select id from users order by id", .{});
while (try cur.next()) |batch| {
    for (batch) |row| { ... }
    if (pare_cedo) { try cur.close(); break; }
}
try cur.close();

// streaming sem materializar o Result (ctx é passado por valor ao callback)
var count: usize = 0;
try db.forEach(&count, struct {
    fn cb(c: *usize, row: pg.Row) !void {
        _ = row;
        c.* += 1;
    }
}.cb, "select id from users", .{});

// várias queries em 1 round-trip
const results = try db.pipeline(.{
    .{ "select 1 as x", .{} },
    .{ "insert into t (a) values ({}) returning id", .{7} },
});
defer { for (results) |*r| r.deinit(); gpa.free(results); }
```

## COPY e LISTEN/NOTIFY

```zig
// COPY OUT
var r = try db.readable("copy users to stdout", .{});
while (try r.next()) |chunk| { ... } // chunk é borrowed

// COPY IN
var w = try db.writable("copy users (name, age) from stdin", .{});
try w.writeAll("Alice\t30\nBob\t25\n");
const n = try w.end(); // nº de linhas copiadas; ou try w.fail("motivo") para abortar

// LISTEN/NOTIFY
var l = try db.listen("minha_fila");
defer l.close();
try db.notify("minha_fila", "{\"msg\":\"oi\"}");
const n = try l.poll(); // bloqueia até a próxima notificação
```

## Utilitários e erros

```zig
// multi-statement, sem parâmetros (protocolo simple)
var m = try db.simple("select 1; select 2;");

// SQL bruto com $1... (sem validação — use com cautela)
var u = try db.unsafe("select * from " ++ tabela, .{}, .{});

// roda arquivo .sql (útil p/ migrations/seeds)
var f = try db.file("schema.sql", .{}, .{});

// inspeciona a query final, OIDs dos params e colunas, sem executar
var d = try db.describe("select id from users where id = {}", .{@as(i64, 1)});
defer d.deinit();

// erros do servidor vêm com diagnóstico estruturado
var r = db.query("select * from nope", .{}) catch |e| {
    if (e == error.PgError) {
        const d = db.lastDiagnostics();
        // d.code ("42P01"), d.message, d.detail, d.hint, d.query...
        if (d.isUndefinedTable()) { ... }
    }
    return e;
};
```

## Opções de conexão

```zig
var db = try postgres(io, gpa, .{
    .url = "postgres://user:pass@host1:5432,host2:5432/db?sslmode=require",
    // ou campo a campo:
    // .hosts = &.{"localhost"}, .ports = &.{5432},
    // .database = "app", .username = "u", .password = "p",
    // .path = "/var/run/postgresql", // unix socket
    .ssl = .prefer, // .disable | .prefer | .require | .verify_ca | .verify_full
    .max = 10, // conexões no pool (lazy)
    .idle_timeout = 20 * std.time.ns_per_s,
    .connect_timeout = 30 * std.time.ns_per_s,
    .query_timeout = 5 * std.time.ns_per_s, // CancelRequest no deadline
    .prepare = true, // prepared statements (desligue p/ PgBouncer txn mode)
    .binary_first_exec = false, // 1a execução em binário (custa 1 round trip a mais por statement novo)
    .target_session_attrs = .any, // .read_write | .primary | ...
    .deny_unsafe = true, // rejeita db.unsafe()/pg.raw() — recomendado em prod
    .allow_insecure_auth = false, // opt-in p/ MD5/cleartext (SCRAM é default)
    .on_notice = minha_fn, .on_notice_data = null,
});
```

Notas de segurança: `sslmode=require` **sempre** verifica certificado + hostname (sem o footgun histórico do Node); SCRAM-SHA-256 com verificação obrigatória da assinatura do servidor; MD5/cleartext exigem opt-in explícito; parâmetros nunca entram no `Diagnostics`.

## Tipos PostgreSQL ↔ Zig

| PG | Zig (leitura) | Zig (parâmetro) |
|---|---|---|
| bool | `bool` | `bool` |
| int2/int4/int8 | `i16/i32/i64` | `i16/i32/i64` |
| float4/float8 | `f32/f64` | `f32/f64` |
| text/varchar/numeric/json | `[]const u8` | `[]const u8`, `pg.json(v)` |
| bytea | `[]const u8` | `pg.bytea(b)` |
| date/time/timestamp/timestamptz | `pg.Date/Time/Timestamp` (ou texto original) | `pg.Date/Time/Timestamp` |
| uuid | `[16]u8` | `[16]u8` |
| arrays (`int[]`, `text[]`…) | slices (`[]?i64`, `[]const []const u8`) | slices |
| NULL | `?T` | `null` / `?T` |

`row.get([]const u8, col)` só funciona quando o valor é texto. Para ler um valor
binário (int8, uuid, timestamp, bool) como string use `row.getText(buf, col)`
(ou `getTextAt(buf, i)`) — ele renderiza no formato de texto do PostgreSQL
usando o buffer que você passa, sem alocar:

```zig
var buf: [32]u8 = undefined;
const guild_id = try row.getText(&buf, "guild_id"); // "1098316516774129684"
```

Cada chamada precisa do seu próprio buffer (o resultado é emprestado).
Para IDs grandes, prefira `i64`/`u64` a `f64`: um snowflake do Discord
(1,09e18) perde precisão em `f64`.

Resultados chegam em formato texto (como no postgres.js) e são convertidos sob demanda; parâmetros escalares vão em formato binário.

## Testes

```sh
zig build test              # unitários (sem servidor)
zig build test-integration  # contra PostgreSQL local
```

Integração usa `postgres://postgres:password@localhost:5432/postgres` por padrão (ou `PG_URL`):

```sh
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=password postgres:16-alpine
```

## Status

Em desenvolvimento ativo (`0.1.0`). A maior parte da API do postgres.js está implementada e coberta por testes de integração. `subscribe` (replicação lógica) ainda não implementado.
