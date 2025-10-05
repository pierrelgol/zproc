const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "process basic lifecycle - start and exit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test successful process start and exit
    const argv = try utils.buildArgv(&[_][]const u8{"true"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/true",
        .argv = argv,
        .envp = envp,
    });

    // Monitor until completion
    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    try std.testing.expect(process.getExitSignal() == null);
}

test "process lifecycle - failed command" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test with non-existent command
    const argv = try utils.buildArgv(&[_][]const u8{"nonexistent"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/nonexistent/command",
        .argv = argv,
        .envp = envp,
    });

    // Monitor until completion or failure
    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    // Process should have failed to start or exited with error
    try std.testing.expect(process.hasExited() or process.failed_start);
}

test "process lifecycle - command with non-zero exit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test with command that exits with non-zero code
    const argv = try utils.buildArgv(&[_][]const u8{"false"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/false",
        .argv = argv,
        .envp = envp,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expect(process.getExitCode().? != 0);
}

test "process lifecycle - long running process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{ .start_gate_s = 0 };
    defer process.reset();

    // Test with long running process
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "2" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/sleep",
        .argv = argv,
        .envp = envp,
    });

    // Wait for process to start
    var iterations: u32 = 0;
    while (!process.isRunning() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.isRunning());

    // Wait for natural completion
    var iterations2: u32 = 0;
    while (process.isAlive() and iterations2 < 300) { // Wait up to 3 seconds
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations2 += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
}

test "process lifecycle - state transitions" {
    var process = Process{};

    // Initial state
    try std.testing.expectEqual(Process.State.stopped, process.state);
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(!process.hasExited());

    // Simulate starting state
    process.state = .starting;
    process.pid = 12345;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(!process.hasExited());

    // Simulate running state
    process.state = .running;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(process.isRunning());
    try std.testing.expect(!process.hasExited());

    // Simulate stopping state
    process.state = .stopping;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(!process.hasExited());

    // Simulate exited state
    process.state = .exited;
    process.exit_code = 0;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Simulate killed state
    process.state = .killed;
    process.exit_signal = 9;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 9), process.getExitSignal().?);
}

test "process lifecycle - reset functionality" {
    var process = Process{};

    // Set up process with various states
    process.pid = 12345;
    process.state = .running;
    process.start_time_ns = 1000;
    process.exit_code = 1;
    process.exit_signal = 9;
    process.failed_start = true;
    process.sent_kill = true;
    process.retries_count = 5;

    // Reset process
    process.reset();

    // Verify all fields are reset
    try std.testing.expect(process.pid == null);
    try std.testing.expectEqual(Process.State.stopped, process.state);
    try std.testing.expectEqual(@as(u64, 0), process.start_time_ns);
    try std.testing.expect(process.exit_code == null);
    try std.testing.expect(process.exit_signal == null);
    try std.testing.expect(!process.failed_start);
    try std.testing.expect(!process.sent_kill);
    try std.testing.expectEqual(@as(u32, 0), process.retries_count);
}

test "process lifecycle - uptime calculation" {
    var process = Process{};

    // No start time
    try std.testing.expectEqual(@as(u64, 0), process.getUptime());

    // Set start time
    const start_time = std.time.nanoTimestamp();
    process.start_time_ns = @truncate(@abs(start_time));

    std.Thread.sleep(10 * std.time.ns_per_ms);
    const uptime = process.getUptime();
    try std.testing.expect(uptime > 0);
    try std.testing.expect(uptime < 100 * std.time.ns_per_ms);
}

test "process lifecycle - backoff mechanism" {
    var process = Process{ .backoff_delay_s = 1 };

    // Enter backoff
    process.enterBackoff();
    try std.testing.expectEqual(Process.State.backoff, process.state);
    try std.testing.expect(process.backoff_until_ns > 0);
    try std.testing.expect(!process.isBackoffExpired());

    // Wait for backoff to expire
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try std.testing.expect(process.isBackoffExpired());
}

test "process lifecycle - start gate timing" {
    var process = Process{ .start_gate_s = 1 };
    const start_time = std.time.nanoTimestamp();
    process.start_time_ns = @truncate(@abs(start_time));
    process.start_gate_started_ns = process.start_time_ns;
    process.state = .starting;

    // Should still be in starting state
    try std.testing.expectEqual(Process.State.starting, process.state);

    // Wait for start gate to expire
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    const now_ns = @as(u64, @truncate(@abs(std.time.nanoTimestamp())));
    const start_gate_ns = process.start_gate_s * std.time.ns_per_s;
    if (now_ns - process.start_gate_started_ns >= start_gate_ns) {
        process.state = .running;
    }
    try std.testing.expectEqual(Process.State.running, process.state);
}
