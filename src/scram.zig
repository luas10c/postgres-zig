const std = @import("std");
const errors = @import("error.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const mechanism = "SCRAM-SHA-256";
pub const nonce_raw_len = 18;
pub const nonce_b64_len = 24;

/// Scratch buffers sized for SCRAM-SHA-256 exchanges. Keep as value type —
/// lives on the connection stack.
pub const Buffers = struct {
    first_buf: [96 + 256]u8 = undefined,
    first_len: usize = 0,
    final_buf: [96 + 256]u8 = undefined,
    final_len: usize = 0,
    auth_buf: [512 + 1024]u8 = undefined,
    auth_len: usize = 0,
    salted_password_buf: [32]u8 = undefined,
    server_final_expected: [32]u8 = undefined,
    salt: [64]u8 = undefined,
    salt_len: usize = 0,
    nonce: [nonce_raw_len]u8 = undefined,
};

fn saslEscape(out: []u8, s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '=') {
            out[n] = '=';
            out[n + 1] = '3';
            out[n + 2] = 'D';
            n += 3;
        } else if (c == ',') {
            out[n] = '=';
            out[n + 1] = '2';
            out[n + 2] = 'D';
            n += 3;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

const ServerFirst = struct {
    iteration_count: u32,
    /// borrowed from the server message
    combined_nonce: []const u8,
};

/// Builds the client-first-message (`n,,n=<user>,r=<nonce>`) with a
/// CSPRNG nonce. Also stashes `client-first-bare` (AuthMessage prefix).
pub fn clientFirst(b: *Buffers, io: std.Io, username: []const u8) errors.Error![]const u8 {
    io.randomSecure(b.nonce[0..]) catch return error.Unexpected;

    var nonce_b64: [nonce_b64_len]u8 = undefined;
    const nonce_s = std.base64.standard.Encoder.encode(&nonce_b64, &b.nonce);

    var esc_buf: [192]u8 = undefined;
    const esc_len = saslEscape(&esc_buf, username);

    const total = 5 + esc_len + 3 + nonce_s.len;
    if (total > b.first_buf.len) return error.InvalidValue;

    @memcpy(b.first_buf[0..3], "n,,");
    @memcpy(b.first_buf[3..5], "n=");
    @memcpy(b.first_buf[5..][0..esc_len], esc_buf[0..esc_len]);
    @memcpy(b.first_buf[5 + esc_len ..][0..3], ",r=");
    @memcpy(b.first_buf[8 + esc_len ..][0..nonce_s.len], &nonce_b64);
    b.first_len = total;

    const bare_len = total - 3;
    @memcpy(b.auth_buf[0..bare_len], b.first_buf[3..total]);
    b.auth_len = bare_len;
    return b.first_buf[0..b.first_len];
}

/// Parses `r=<nonce>,s=<base64 salt>,i=<iterations>` (hostile-input safe).
fn parseServerFirst(b: *Buffers, msg: []const u8) errors.Error!ServerFirst {
    var nonce: []const u8 = "";
    var salt_b64: []const u8 = "";
    var iter: u32 = 0;
    var it = std.mem.splitScalar(u8, msg, ',');
    while (it.next()) |attr| {
        if (attr.len < 2 or attr[1] != '=') continue;
        switch (attr[0]) {
            'r' => nonce = attr[2..],
            's' => salt_b64 = attr[2..],
            'i' => iter = std.fmt.parseInt(u32, attr[2..], 10) catch return error.InvalidScramMessage,
            else => {},
        }
    }
    if (nonce.len == 0 or salt_b64.len == 0 or iter == 0) return error.InvalidScramMessage;

    var nonce_b64: [nonce_b64_len]u8 = undefined;
    const nonce_s = std.base64.standard.Encoder.encode(&nonce_b64, &b.nonce);
    if (nonce.len < nonce_s.len or !std.mem.eql(u8, nonce[0..nonce_s.len], nonce_s)) {
        return error.InvalidScramMessage;
    }

    const dec = std.base64.standard.Decoder;
    const salt_len = dec.calcSizeForSlice(salt_b64) catch return error.InvalidScramMessage;
    if (salt_len > b.salt.len) return error.InvalidScramMessage;
    dec.decode(b.salt[0..salt_len], salt_b64) catch return error.InvalidScramMessage;
    b.salt_len = salt_len;

    return .{ .iteration_count = iter, .combined_nonce = nonce };
}

/// Builds the client-final-message (`c=biws,r=<nonce>,p=<proof>`) and the
/// expected server signature. `password` is only borrowed during this call.
pub fn clientFinal(
    b: *Buffers,
    password: []const u8,
    server_first_msg: []const u8,
) errors.Error![]const u8 {
    const sf = try parseServerFirst(b, server_first_msg);

    std.crypto.pwhash.pbkdf2(&b.salted_password_buf, password, b.salt[0..b.salt_len], sf.iteration_count, HmacSha256) catch return error.Unexpected;

    var client_key: [32]u8 = undefined;
    HmacSha256.create(&client_key, "Client Key", &b.salted_password_buf);
    var stored_key: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});

    const cfwop_len = 9 + sf.combined_nonce.len;
    const total_auth = b.auth_len + 1 + server_first_msg.len + 1 + cfwop_len;
    if (total_auth > b.auth_buf.len) return error.InvalidScramMessage;
    b.auth_buf[b.auth_len] = ',';
    @memcpy(b.auth_buf[b.auth_len + 1 ..][0..server_first_msg.len], server_first_msg);
    const cf_start = b.auth_len + 1 + server_first_msg.len;
    b.auth_buf[cf_start] = ',';
    @memcpy(b.auth_buf[cf_start + 1 ..][0..9], "c=biws,r=");
    @memcpy(b.auth_buf[cf_start + 10 ..][0..sf.combined_nonce.len], sf.combined_nonce);
    const auth = b.auth_buf[0..total_auth];

    var client_sig: [32]u8 = undefined;
    HmacSha256.create(&client_sig, auth, &stored_key);
    var proof: [32]u8 = undefined;
    for (0..32) |i| proof[i] = client_key[i] ^ client_sig[i];

    var proof_b64: [44]u8 = undefined;
    const proof_s = std.base64.standard.Encoder.encode(&proof_b64, &proof);

    if (cfwop_len + 3 + proof_s.len > b.final_buf.len) return error.InvalidScramMessage;
    @memcpy(b.final_buf[0..9], "c=biws,r=");
    @memcpy(b.final_buf[9..][0..sf.combined_nonce.len], sf.combined_nonce);
    b.final_buf[9 + sf.combined_nonce.len] = ',';
    b.final_buf[10 + sf.combined_nonce.len] = 'p';
    b.final_buf[11 + sf.combined_nonce.len] = '=';
    @memcpy(b.final_buf[12 + sf.combined_nonce.len ..][0..proof_s.len], proof_b64[0..proof_s.len]);
    b.final_len = cfwop_len + 3 + proof_s.len;

    var server_key: [32]u8 = undefined;
    HmacSha256.create(&server_key, "Server Key", &b.salted_password_buf);
    HmacSha256.create(&b.server_final_expected, auth, &server_key);

    std.crypto.secureZero(u8, &b.salted_password_buf);
    std.crypto.secureZero(u8, &client_key);
    std.crypto.secureZero(u8, &stored_key);

    return b.final_buf[0..b.final_len];
}

/// Verifies the server-final-message (`v=<base64>`), constant-time.
pub fn verifyServerFinal(b: *Buffers, msg: []const u8) errors.Error!void {
    if (msg.len < 3 or msg[0] != 'v' or msg[1] != '=') return error.InvalidScramMessage;
    const sig_b64 = msg[2..];
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(sig_b64) catch return error.InvalidScramMessage;
    if (n != 32) return error.InvalidScramMessage;
    var sig: [32]u8 = undefined;
    dec.decode(&sig, sig_b64) catch return error.InvalidScramMessage;
    if (!std.crypto.timing_safe.eql([32]u8, sig, b.server_final_expected)) {
        return error.SaslSignatureMismatch;
    }
    std.crypto.secureZero(u8, &b.server_final_expected);
}

test "scram exchange math against RFC 7677 section 3" {
    const client_first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO";
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const client_final_without_proof = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";

    const salt_b64 = "W22ZaJ0SNY7soEsUEjb6gQ==";
    var salt: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&salt, salt_b64);

    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, "pencil", &salt, 4096, HmacSha256);

    var client_key: [32]u8 = undefined;
    HmacSha256.create(&client_key, "Client Key", &salted);
    var stored_key: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});

    var auth: std.ArrayList(u8) = .empty;
    defer auth.deinit(std.testing.allocator);
    try auth.appendSlice(std.testing.allocator, client_first_bare);
    try auth.append(std.testing.allocator, ',');
    try auth.appendSlice(std.testing.allocator, server_first);
    try auth.append(std.testing.allocator, ',');
    try auth.appendSlice(std.testing.allocator, client_final_without_proof);

    var client_sig: [32]u8 = undefined;
    HmacSha256.create(&client_sig, auth.items, &stored_key);
    var proof: [32]u8 = undefined;
    for (0..32) |i| proof[i] = client_key[i] ^ client_sig[i];

    var proof_b64: [44]u8 = undefined;
    const proof_b64_s = std.base64.standard.Encoder.encode(&proof_b64, &proof);
    try std.testing.expectEqualStrings("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", proof_b64_s);

    var server_key: [32]u8 = undefined;
    HmacSha256.create(&server_key, "Server Key", &salted);
    var server_sig: [32]u8 = undefined;
    HmacSha256.create(&server_sig, auth.items, &server_key);
    var server_b64: [44]u8 = undefined;
    const server_s = std.base64.standard.Encoder.encode(&server_b64, &server_sig);
    try std.testing.expectEqualStrings("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", server_s);
}
