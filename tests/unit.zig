//! Unit tests — no database required. Aggregates the per-module suites
//! under tests/unit/ and pulls in the tests embedded next to the code.

const std = @import("std");
const postgres = @import("postgres-zig");

test {
    std.testing.refAllDecls(postgres);
    _ = @import("unit/query.zig");
    _ = @import("unit/render.zig");
    _ = @import("unit/types.zig");
    _ = @import("unit/codec.zig");
    _ = @import("unit/diagnostics.zig");
    _ = @import("unit/storage.zig");
}
