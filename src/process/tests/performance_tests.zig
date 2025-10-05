const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "performance - many processes creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(100); // Many processes
    pg.setAutoRestart(.never);

    const start_time = std.time.nanoTimestamp();
    try pg.spawnChildren();
    const end_time = std.time.nanoTimestamp();

    try std.testing.expectEqual(@as(usize, 100), pg.children.len);

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Created 100 processes in {} ns\n", .{duration});

    // All processes should be created successfully
    for (pg.children) |*child| {
        try std.testing.expect(child.state == .starting or child.state == .stopped);
    }
}

test "performance - process group monitoring efficiency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(50);
    pg.setAutoRestart(.never);

    try pg.spawnChildren();

    // Monitor processes multiple times
    const start_time = std.time.nanoTimestamp();
    for (0..100) |_| {
        try pg.monitorChildren();
    }
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Monitored 50 processes 100 times in {} ns\n", .{duration});

    // All processes should have exited
    try std.testing.expect(pg.getAllExited());
}

test "performance - process lifecycle timing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const argv = try utils.buildArgv(&[_][]const u8{"true"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    // Time process start
    const start_time = std.time.nanoTimestamp();
    try process.start(.{
        .path = "/bin/true",
        .argv = argv,
        .envp = envp,
    });
    const start_end_time = std.time.nanoTimestamp();

    // Time process monitoring
    const monitor_start_time = std.time.nanoTimestamp();
    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 100) {
        try process.monitor();
        std.Thread.sleep(1 * std.time.ns_per_ms);
        iterations += 1;
    }
    const monitor_end_time = std.time.nanoTimestamp();

    const start_duration = @as(u64, @intCast(start_end_time - start_time));
    const monitor_duration = @as(u64, @intCast(monitor_end_time - monitor_start_time));

    std.debug.print("Process start took {} ns\n", .{start_duration});
    std.debug.print("Process monitoring took {} ns\n", .{monitor_duration});

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
}

test "performance - signal handling timing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const argv = try utils.buildArgv(&[_][]const u8{ "sleep", "1" }, allocator);
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
        // Time signal sending
        const signal_start_time = std.time.nanoTimestamp();
        try process.sendSignal(std.posix.SIG.TERM);
        const signal_end_time = std.time.nanoTimestamp();

        // Wait for process to exit
        iterations = 0;
        while (process.isAlive() and iterations < 100) {
            try process.monitor();
            std.Thread.sleep(10 * std.time.ns_per_ms);
            iterations += 1;
        }

        const signal_duration = @as(u64, @intCast(signal_end_time - signal_start_time));
        std.debug.print("Signal sending took {} ns\n", .{signal_duration});

        try std.testing.expect(process.hasExited());
    }
}

test "performance - process group state queries" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure ProcessGroup with required fields
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setStartRetries(5); // Set high retry limit so test processes aren't considered fatal

    // Set up many processes with different states
    pg.children = try pg.arena.allocator().alloc(Process, 1000);
    for (pg.children, 0..) |*child, i| {
        child.* = .{ .id = @intCast(i) };
        if (i % 4 == 0) {
            child.state = .running;
        } else if (i % 4 == 1) {
            child.state = .starting;
        } else if (i % 4 == 2) {
            child.state = .exited;
        } else {
            child.state = .backoff;
        }
    }

    // Time state queries
    const start_time = std.time.nanoTimestamp();
    const running_count = pg.getRunningCount();
    const alive_count = pg.getAliveCount();
    const all_exited = pg.getAllExited();
    const has_fatal = pg.hasFatalProcesses();
    const total_uptime = pg.getTotalUptime();
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("State queries for 1000 processes took {} ns\n", .{duration});

    // Verify results
    try std.testing.expectEqual(@as(u32, 250), running_count); // 25% running
    try std.testing.expectEqual(@as(u32, 500), alive_count); // 50% alive
    try std.testing.expect(!all_exited);
    try std.testing.expect(!has_fatal);
    try std.testing.expectEqual(@as(u64, 0), total_uptime); // No uptime for test processes
}

test "performance - process group backoff calculations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure ProcessGroup with required fields
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);

    // Set up processes in backoff state
    pg.children = try pg.arena.allocator().alloc(Process, 100);
    for (pg.children, 0..) |*child, i| {
        child.* = .{
            .id = @intCast(i),
            .state = .backoff,
            .backoff_delay_s = 1,
        };
        child.enterBackoff();
    }

    // Time backoff expiration checks
    const start_time = std.time.nanoTimestamp();
    for (pg.children) |*child| {
        _ = child.isBackoffExpired();
    }
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Backoff expiration checks for 100 processes took {} ns\n", .{duration});

    // All should be in backoff
    for (pg.children) |*child| {
        try std.testing.expectEqual(Process.State.backoff, child.state);
        try std.testing.expect(!child.isBackoffExpired());
    }
}

test "performance - process group monitoring with mixed states" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure ProcessGroup with required fields
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setAutoRestart(.never); // Prevent processes from being restarted during monitoring

    // Set up processes with mixed states
    pg.children = try pg.arena.allocator().alloc(Process, 500);
    for (pg.children, 0..) |*child, i| {
        child.* = .{ .id = @intCast(i) };
        switch (i % 5) {
            0 => child.state = .running,
            1 => child.state = .starting,
            2 => child.state = .stopping,
            3 => child.state = .exited,
            4 => child.state = .backoff,
            else => unreachable,
        }
    }

    // Time monitoring
    const start_time = std.time.nanoTimestamp();
    try pg.monitorChildren();
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Monitoring 500 processes with mixed states took {} ns\n", .{duration});

    // Verify state distribution
    var running_count: u32 = 0;
    var alive_count: u32 = 0;
    for (pg.children) |*child| {
        if (child.isRunning()) running_count += 1;
        if (child.isAlive()) alive_count += 1;
    }

    try std.testing.expectEqual(@as(u32, 200), running_count); // 40% running (100 initial + 100 from starting->running)
    try std.testing.expectEqual(@as(u32, 300), alive_count); // 60% alive
}

test "performance - process group restart logic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure ProcessGroup with required fields
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);

    // Set up processes that need restart decisions
    pg.children = try pg.arena.allocator().alloc(Process, 200);
    for (pg.children, 0..) |*child, i| {
        child.* = .{
            .id = @intCast(i),
            .state = .exited,
            .exit_code = if (i % 2 == 0) 0 else 1,
        };
    }

    pg.setAutoRestart(.unexpected);
    try pg.setExitCodes(&.{0});

    // Time restart decision logic
    const start_time = std.time.nanoTimestamp();
    for (pg.children) |*child| {
        _ = pg.shouldRestart(child);
    }
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Restart decisions for 200 processes took {} ns\n", .{duration});

    // Verify restart decisions
    var restart_count: u32 = 0;
    for (pg.children) |*child| {
        if (pg.shouldRestart(child)) restart_count += 1;
    }

    try std.testing.expectEqual(@as(u32, 100), restart_count); // 50% should restart
}

test "performance - process group individual child operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(50);
    pg.setStopSignal(std.posix.SIG.TERM);
    pg.setStopTimeout(5);

    try pg.spawnChildren();

    // Time individual child operations
    const start_time = std.time.nanoTimestamp();
    for (0..50) |i| {
        try pg.stopChild(@intCast(i));
    }
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Individual stop operations for 50 processes took {} ns\n", .{duration});

    // All children should be in stopping state
    for (pg.children) |*child| {
        try std.testing.expect(child.state == .stopping or child.state == .stopped);
    }
}

test "performance - memory allocation patterns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test memory allocation for many process groups
    const start_time = std.time.nanoTimestamp();
    for (0..100) |_| {
        var pg = ProcessGroup.init(allocator);

        try pg.setName("test-process");
        try pg.setCmd("/bin/true");
        const argv = [_][]const u8{"true"};
        try pg.setArgv(&argv);
        const env = [_][]const u8{};
        try pg.setEnv(&env);
        pg.setNumProcs(10);

        try pg.spawnChildren();
        try std.testing.expectEqual(@as(usize, 10), pg.children.len);

        pg.deinit();
    }
    const end_time = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("Created and destroyed 100 process groups with 10 processes each in {} ns\n", .{duration});
}
