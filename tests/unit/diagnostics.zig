//! Diagnostics-parsing unit tests — no database required.

const std = @import("std");
const postgres = @import("postgres-zig");
const errors = postgres.errors;
const testing = std.testing;
const Diagnostics = errors.Diagnostics;
const parseErrorFields = errors.parseErrorFields;

test "parseErrorFields reads every field and tolerates truncation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var d = Diagnostics{};
    try parseErrorFields("SERROR\x00VERROR\x00C23505\x00Mdup key\x00Fscram.sasl\x00\x00", a, &d);
    try testing.expectEqualStrings("23505", d.code);
    try testing.expectEqualStrings("dup key", d.message);
    try testing.expectEqualStrings("ERROR", d.severity);
    try testing.expectEqualStrings("scram.sasl", d.file);

    // payload cut mid-field: the remainder is taken as the value, no over-read
    var d2 = Diagnostics{};
    try parseErrorFields("C23505", a, &d2);
    try testing.expectEqualStrings("23505", d2.code);
    try testing.expectEqualStrings("", d2.message);

    // unknown field codes are skipped, terminator ends the loop
    var d3 = Diagnostics{};
    try parseErrorFields("\x00Mignored\x00", a, &d3);
    try testing.expectEqualStrings("", d3.message);
}
