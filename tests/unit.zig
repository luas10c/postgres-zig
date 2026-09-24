//! Unit tests — no database required. Aggregates the per-module suites
//! under tests/unit/.

const std = @import("std");
const postgres = @import("postgres-zig");

test {
    std.testing.refAllDecls(postgres);
    _ = @import("unit/query.zig");
    _ = @import("unit/types.zig");
}
