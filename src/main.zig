const std = @import("std");
pub fn main() !void {
    const username = "luas10c";
    std.debug.print("Welcome, {s}!", .{username});
}
