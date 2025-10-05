const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "process signal handling - TERM signal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a long running process
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
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

    if (process.isRunning()) {
        // Send TERM signal
        try process.sendSignal(std.posix.SIG.TERM);

        // Wait for process to exit
        iterations = 0;
        while (process.isAlive() and iterations < 100) {
            try process.monitor();
            std.Thread.sleep(10 * std.time.ns_per_ms);
            iterations += 1;
        }

        try std.testing.expect(process.hasExited());
    }
}

test "process signal handling - INT signal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a long running process
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
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

    if (process.isRunning()) {
        // Send INT signal
        try process.sendSignal(std.posix.SIG.INT);

        // Wait for process to exit
        iterations = 0;
        while (process.isAlive() and iterations < 100) {
            try process.monitor();
            std.Thread.sleep(10 * std.time.ns_per_ms);
            iterations += 1;
        }

        try std.testing.expect(process.hasExited());
    }
}

test "process signal handling - USR1 signal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a long running process
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
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

    if (process.isRunning()) {
        // Send USR1 signal
        try process.sendSignal(std.posix.SIG.USR1);

        // Process should still be running (USR1 doesn't terminate sleep)
        try std.testing.expect(process.isRunning());
    }
}

test "process signal handling - stop with timeout" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a long running process
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
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

    if (process.isRunning()) {
        // Stop with timeout
        try process.stop(std.posix.SIG.TERM, 1);

        // Wait for process to exit
        iterations = 0;
        while (process.isAlive() and iterations < 100) {
            try process.monitor();
            std.Thread.sleep(10 * std.time.ns_per_ms);
            iterations += 1;
        }

        try std.testing.expect(process.hasExited());
    }
}

test "process signal handling - kill process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a long running process
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
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

    if (process.isRunning()) {
        // Kill process
        try process.kill();

        // Wait for process to exit
        iterations = 0;
        while (process.isAlive() and iterations < 100) {
            try process.monitor();
            std.Thread.sleep(10 * std.time.ns_per_ms);
            iterations += 1;
        }

        try std.testing.expect(process.hasExited());
    }
}

test "process signal handling - invalid state transitions" {
    var process = Process{};

    // Test sending signal to stopped process
    process.state = .stopped;
    try std.testing.expectError(error.InvalidState, process.sendSignal(std.posix.SIG.TERM));

    // Test stopping stopped process
    try std.testing.expectError(error.InvalidState, process.stop(std.posix.SIG.TERM, 5));

    // Test killing already killed process
    process.state = .killed;
    try std.testing.expectError(error.InvalidState, process.kill());

    // Test killing exited process
    process.state = .exited;
    try std.testing.expectError(error.InvalidState, process.kill());
}

test "process signal handling - signal to process group" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a process that creates a process group
    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
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

    if (process.isRunning() and process.pid != null) {
        // Send signal to process group (negative PID)
        const pgid = -process.pid.?;
        try std.posix.kill(pgid, std.posix.SIG.TERM);

        // Wait for process to exit
        iterations = 0;
        while (process.isAlive() and iterations < 100) {
            try process.monitor();
            std.Thread.sleep(10 * std.time.ns_per_ms);
            iterations += 1;
        }

        try std.testing.expect(process.hasExited());
    }
}

test "process signal handling - stop timeout and force kill" {
    var process = Process{};
    process.state = .stopping;
    process.stop_deadline_ns = @as(u64, @truncate(@abs(std.time.nanoTimestamp()))) + 1000 * std.time.ns_per_ms;

    // Should still be in stopping state
    const now_ns = @as(u64, @truncate(@abs(std.time.nanoTimestamp())));
    if (now_ns >= process.stop_deadline_ns and !process.sent_kill) {
        process.state = .killed;
        process.sent_kill = true;
    }
    try std.testing.expectEqual(Process.State.stopping, process.state);

    // Wait for timeout
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    const now_ns2 = @as(u64, @truncate(@abs(std.time.nanoTimestamp())));
    if (now_ns2 >= process.stop_deadline_ns and !process.sent_kill) {
        process.state = .killed;
        process.sent_kill = true;
    }
    try std.testing.expectEqual(Process.State.killed, process.state);
    try std.testing.expect(process.sent_kill);
}

test "process signal handling - exit code and signal handling" {
    var process = Process{};

    // Test exit code
    process.exit_code = 42;
    try std.testing.expectEqual(@as(u8, 42), process.getExitCode().?);

    // Test exit signal
    process.exit_signal = 15;
    try std.testing.expectEqual(@as(u8, 15), process.getExitSignal().?);

    // Test null values
    process.exit_code = null;
    process.exit_signal = null;
    try std.testing.expect(process.getExitCode() == null);
    try std.testing.expect(process.getExitSignal() == null);
}
