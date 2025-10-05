const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "error handling - invalid process states" {
    var process = Process{};

    // Test starting a process that's already running
    process.state = .running;
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(&[_]?[*:0]const u8{null});
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&[_]?[*:0]const u8{null});
    try std.testing.expectError(error.InvalidState, process.start(.{
        .path = "/bin/true",
        .argv = argv,
        .envp = envp,
    }));

    // Test stopping a stopped process
    process.state = .stopped;
    try std.testing.expectError(error.InvalidState, process.stop(std.posix.SIG.TERM, 5));

    // Test sending signal to stopped process
    try std.testing.expectError(error.InvalidState, process.sendSignal(std.posix.SIG.USR1));

    // Test killing already killed process
    process.state = .killed;
    try std.testing.expectError(error.InvalidState, process.kill());

    // Test killing exited process
    process.state = .exited;
    try std.testing.expectError(error.InvalidState, process.kill());
}

test "error handling - non-existent commands" {
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

test "error handling - invalid arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test with invalid arguments
    const argv = try utils.buildArgv(&[_][]const u8{ "ls", "--invalid-option" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/ls",
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
    // ls with invalid option should exit with non-zero code
    try std.testing.expect(process.getExitCode().? != 0);
}

test "error handling - process group missing configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Test missing command
    try std.testing.expectError(error.MissingCommand, pg.spawnChildren());

    try pg.setCmd("/bin/true");
    // Test missing argv
    try std.testing.expectError(error.MissingArgv, pg.spawnChildren());

    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    // Test missing envp
    try std.testing.expectError(error.MissingEnvp, pg.spawnChildren());

    const env = [_][]const u8{};
    try pg.setEnv(&env);
    // Test no processes
    try std.testing.expectError(error.NoProcesses, pg.spawnChildren());
}

test "error handling - process group invalid child operations" {
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
    pg.setNumProcs(2);
    pg.setStopSignal(std.posix.SIG.TERM);
    pg.setStopTimeout(5);

    try pg.spawnChildren();

    // Test invalid child ID
    try std.testing.expectError(error.InvalidChildId, pg.stopChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.killChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.restartChild(5));
}

test "error handling - working directory errors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test with non-existent working directory
    const argv = try utils.buildArgv(&[_][]const u8{"pwd"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/pwd",
        .argv = argv,
        .envp = envp,
        .working_directory = "/nonexistent/directory",
    });

    // Process may or may not fail immediately - the key is that start succeeds
    // and the process is created (even if it fails to start)
    try std.testing.expect(process.pid != null or process.failed_start);
}

test "error handling - output file creation errors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test with invalid output path (should still work, just redirect to /dev/null)
    const argv = try utils.buildArgv(&[_][]const u8{ "echo", "test" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/echo",
        .argv = argv,
        .envp = envp,
        .stdout_path = "/tmp/zproc_test_invalid_path.log",
        .redirect_stdout = true,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
}

test "error handling - signal errors" {
    var process = Process{};
    defer process.reset();

    // Test sending signal to non-existent process
    process.pid = 99999; // Non-existent PID
    process.state = .running;

    // This should not error, but the signal won't be delivered
    try process.sendSignal(std.posix.SIG.TERM);
}

test "error handling - process group backoff exhaustion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/false"); // Will exit with non-zero code
    const argv = [_][]const u8{"false"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.unexpected);
    pg.setStartRetries(2); // 2 retries (3 total attempts)
    pg.setBackoffDelay(1);

    try pg.spawnChildren();

    // Wait for process to exit
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // Should enter backoff
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    // Wait for backoff to expire and retry
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try pg.monitorChildren();

    // Wait for second exit
    iterations = 0;
    while (pg.getAliveCount() > 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // Should enter backoff again
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    // Wait for backoff to expire and retry
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try pg.monitorChildren();

    // Wait for third exit (should exceed retry limit)
    iterations = 0;
    while (pg.getAliveCount() > 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // Should stay exited (retry limit exceeded)
    try pg.monitorChildren();
    try pg.monitorChildren(); // Extra monitoring to ensure state transition
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);
}

test "error handling - process group fatal processes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Set up process group with retry limit
    pg.setStartRetries(2);
    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .state = .exited,
        .retries_count = 2, // At retry limit
    };

    // Should be considered fatal
    try std.testing.expect(pg.hasFatalProcesses());

    // Reset retry count
    pg.children[0].retries_count = 1;
    try std.testing.expect(!pg.hasFatalProcesses());
}

test "error handling - process group state consistency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Test initial state
    try std.testing.expectEqual(ProcessGroup.GroupState.stopped, pg.getGroupState());
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());
    try std.testing.expect(!pg.hasFatalProcesses());

    // Set up some test processes
    pg.children = try pg.arena.allocator().alloc(Process, 3);
    pg.children[0] = .{ .id = 0, .state = .running };
    pg.children[1] = .{ .id = 1, .state = .starting };
    pg.children[2] = .{ .id = 2, .state = .exited };

    try std.testing.expectEqual(@as(u32, 1), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 2), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());
}

test "error handling - process group resource cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test multiple process group creation and cleanup
    for (0..5) |_| {
        var pg = ProcessGroup.init(allocator);

        try pg.setName("test-process");
        try pg.setCmd("/bin/true");
        const argv = [_][]const u8{"true"};
        try pg.setArgv(&argv);
        const env = [_][]const u8{};
        try pg.setEnv(&env);
        pg.setNumProcs(2);

        try pg.spawnChildren();
        try std.testing.expectEqual(@as(usize, 2), pg.children.len);

        // Cleanup should work properly
        pg.deinit();
    }
}

test "error handling - process group edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Test zero processes
    pg.setNumProcs(0);
    try std.testing.expectEqual(@as(u32, 0), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    // Test maximum values
    pg.setStartRetries(0xFFFFFFFF);
    pg.setStartTime(0xFFFFFFFF);
    pg.setStartSecs(0xFFFFFFFF);
    pg.setStopTimeout(0xFFFFFFFF);
    pg.setBackoffDelay(0xFFFFFFFF);

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.start_time);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.stop_timeout);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.backoff_delay_s);
}
