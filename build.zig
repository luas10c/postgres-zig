const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pg_module = b.addModule("postgres-zig", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests (no server required)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "postgres-zig", .module = pg_module },
            },
        }),
    });
    const run_unit = b.addRunArtifact(unit_tests);
    const unit_step = b.step("test", "Run unit tests (no database required)");
    unit_step.dependOn(&run_unit.step);

    // Integration tests (require a running PostgreSQL; set PG_URL or defaults)
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "postgres-zig", .module = pg_module },
            },
        }),
    });
    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests against a live PostgreSQL (PG_URL or localhost defaults)");
    integration_step.dependOn(&run_integration.step);
}
