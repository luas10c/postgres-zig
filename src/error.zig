const std = @import("std");

/// Every error the driver can produce. Kept explicit (no inferred sets)
/// so the public API is self-documenting.
pub const Error = error{
    /// Server error; details in `lastDiagnostics()`.
    PgError,
    UnsafeTransaction,
    MessageNotSupported,
    SaslSignatureMismatch,
    AuthTypeNotImplemented,
    AuthFailed,
    ConnectionClosed,
    ConnectionEnded,
    ConnectionDestroyed,
    ConnectTimeout,
    ConnectFailed,
    CopyInProgress,
    Timeout,
    Cancelled,
    MessageTooLarge,
    ResultTooLarge,
    ProtocolError,
    TlsFailed,
    TlsRequired,
    TlsAlert,
    TypeMismatch,
    InvalidIdent,
    InvalidQuery,
    InvalidUrl,
    InvalidScramMessage,
    InvalidValue,
    UndefinedColumn,
    UnknownHostName,
    StatementTooLarge,
    UnsafeDenied,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    WouldBlock,
    SystemResources,
    Unexpected,
};

/// Structured PostgreSQL error/notice fields (protocol v3 ErrorResponse).
/// All strings are copies owned by the diagnostics arena.
pub const Diagnostics = struct {
    severity: []const u8 = "",
    severity_non_local: []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    hint: []const u8 = "",
    position: []const u8 = "",
    internal_position: []const u8 = "",
    internal_query: []const u8 = "",
    where: []const u8 = "",
    schema: []const u8 = "",
    table: []const u8 = "",
    column: []const u8 = "",
    datatype: []const u8 = "",
    constraint: []const u8 = "",
    file: []const u8 = "",
    line: []const u8 = "",
    routine: []const u8 = "",
    /// Final query text that was executing (never includes parameters).
    query: []const u8 = "",

    pub fn isUniqueViolation(d: Diagnostics) bool {
        return std.mem.eql(u8, d.code, "23505");
    }
    pub fn isSerializationFailure(d: Diagnostics) bool {
        return std.mem.eql(u8, d.code, "40001");
    }
    pub fn isQueryCanceled(d: Diagnostics) bool {
        return std.mem.eql(u8, d.code, "57014");
    }
    pub fn isUndefinedTable(d: Diagnostics) bool {
        return std.mem.eql(u8, d.code, "42P01");
    }
};

/// Parse an ErrorResponse/NoticeResponse payload (sequence of
/// `field_code:u8, cstring` pairs, terminated by a 0 byte) into `d`,
/// copying every string into `arena`. Malformed payloads are tolerated
/// (parser treats server as hostile — never panics).
pub fn parseErrorFields(payload: []const u8, arena: std.mem.Allocator, d: *Diagnostics) !void {
    var i: usize = 0;
    while (i < payload.len) {
        const code = payload[i];
        if (code == 0) return;
        i += 1;
        const start = i;
        while (i < payload.len and payload[i] != 0) : (i += 1) {}
        const value = payload[start..i];
        if (i < payload.len) i += 1;
        const copy = try arena.dupe(u8, value);
        switch (code) {
            'S' => d.severity = copy,
            'V' => d.severity_non_local = copy,
            'C' => d.code = copy,
            'M' => d.message = copy,
            'D' => d.detail = copy,
            'H' => d.hint = copy,
            'P' => d.position = copy,
            'p' => d.internal_position = copy,
            'q' => d.internal_query = copy,
            'W' => d.where = copy,
            's' => d.schema = copy,
            't' => d.table = copy,
            'c' => d.column = copy,
            'd' => d.datatype = copy,
            'n' => d.constraint = copy,
            'F' => d.file = copy,
            'L' => d.line = copy,
            'R' => d.routine = copy,
            else => {},
        }
    }
}

test "parseErrorFields tolerates truncation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d = Diagnostics{};
    try parseErrorFields("C23505Mdup key", arena_state.allocator(), &d);
    try std.testing.expectEqualStrings("23505", d.code);
    try std.testing.expectEqualStrings("dup key", d.message);
}
