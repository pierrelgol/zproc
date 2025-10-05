const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "process group initialization and configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Test initial state
    try std.testing.expectEqual(@as(u32, 0), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 0), pg.start_time);
    try std.testing.expectEqual(@as(u32, 0), pg.stop_timeout);
    try std.testing.expectEqual(ProcessGroup.AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(std.posix.SIG.TERM, pg.stop_signal);

    // Test configuration methods
    try pg.setName("test-process");
    try std.testing.expectEqualStrings("test-process", pg.name);

    try pg.setCmd("/bin/sleep");
    try std.testing.expectEqualStrings("/bin/sleep", pg.cmd);

    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);

    const env = [_][]const u8{"TEST=1"};
    try pg.setEnv(&env);

    pg.setNumProcs(3);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);

    pg.setStartTime(5);
    try std.testing.expectEqual(@as(u32, 5), pg.start_time);

    pg.setStopTimeout(10);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);

    pg.setAutoRestart(.always);
    try std.testing.expectEqual(ProcessGroup.AutoRestart.always, pg.autorestart);
}

test "process group spawn children" {
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
    pg.setNumProcs(3);

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 3), pg.children.len);

    // All children should be in starting or stopped state initially
    for (pg.children) |*child| {
        try std.testing.expect(child.state == .starting or child.state == .stopped);
    }
}

test "process group spawn children - error cases" {
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

test "process group monitoring and state management" {
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
    pg.setNumProcs(2);
    pg.setAutoRestart(.never);

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 2), pg.children.len);

    // Monitor until all processes complete
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 100) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // All processes should have exited
    try std.testing.expect(pg.getAllExited());
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
}

test "process group auto restart - always policy" {
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
    pg.setNumProcs(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);

    try pg.spawnChildren();

    // Wait for process to exit
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // With always restart, process should restart
    try pg.monitorChildren();
    // Process should be in backoff or starting state
    try std.testing.expect(pg.children[0].state == .backoff or pg.children[0].state == .starting);
}

test "process group auto restart - never policy" {
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
    pg.setNumProcs(1);
    pg.setAutoRestart(.never);

    try pg.spawnChildren();

    // Wait for process to exit
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // With never restart, process should stay exited
    try std.testing.expect(pg.getAllExited());
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);

    // Should not restart
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);
}

test "process group auto restart - unexpected policy" {
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
    pg.setStartRetries(1);
    try pg.setExitCodes(&.{0});

    try pg.spawnChildren();

    // Wait for process to exit
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // With unexpected policy and non-zero exit, should restart
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);
}

test "process group individual child control" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "10" };
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

    // Test valid child control
    try pg.stopChild(0);
    try pg.killChild(1);
}

test "process group backoff and retry logic" {
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
    pg.setBackoffDelay(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);
    pg.setNumProcs(1);

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

    // Wait for backoff to expire
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.starting, pg.children[0].state);
}

test "process group state and uptime tracking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(ProcessGroup.GroupState.stopped, pg.getGroupState());
    try std.testing.expectEqual(@as(u64, 0), pg.getTotalUptime());
    try std.testing.expect(!pg.hasFatalProcesses());

    // Set up some test processes
    pg.children = try pg.arena.allocator().alloc(Process, 2);
    pg.children[0] = .{ .id = 0, .state = .running, .start_time_ns = 1000 };
    pg.children[1] = .{ .id = 1, .state = .exited, .retries_count = 3 };

    const uptime = pg.getTotalUptime();
    try std.testing.expect(uptime > 0);

    try std.testing.expect(pg.hasFatalProcesses());
}

test "process group resource management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setWorkingDir("/tmp");
    try std.testing.expectEqualStrings("/tmp", pg.working_directory);

    try pg.setStdoutPath("/tmp/stdout.log");
    try pg.setStderrPath("/tmp/stderr.log");
    try std.testing.expectEqualStrings("/tmp/stdout.log", pg.stdout_path);
    try std.testing.expectEqualStrings("/tmp/stderr.log", pg.stderr_path);

    pg.setUmask(0o077);
    try std.testing.expectEqual(@as(u16, 0o077), pg.umask);

    pg.setRedirectStdout(false);
    pg.setRedirectStderr(false);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    try std.testing.expectEqual(false, pg.redirect_stderr);
}

test "process group signal handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setStopSignal(std.posix.SIG.USR1);
    try std.testing.expectEqual(std.posix.SIG.USR1, pg.stop_signal);

    pg.setStopSignal(std.posix.SIG.TERM);
    try std.testing.expectEqual(std.posix.SIG.TERM, pg.stop_signal);

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "10" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(2);

    try pg.spawnChildren();

    // Test stopping all children
    try pg.stopChildren();
    try std.testing.expect(pg.state == ProcessGroup.GroupState.stopping or pg.state == ProcessGroup.GroupState.stopped);
}

test "process group comprehensive configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Comprehensive configuration
    try pg.setName("comprehensive-test");
    try pg.setCmd("/bin/echo");
    const argv = [_][]const u8{ "echo", "hello", "world" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{ "TEST=1", "DEBUG=true" };
    try pg.setEnv(&env);
    try pg.setWorkingDir("/tmp");
    try pg.setStdoutPath("/tmp/out.log");
    try pg.setStderrPath("/tmp/err.log");
    pg.setNumProcs(7);
    pg.setStartRetries(3);
    pg.setStartTime(4);
    pg.setStartSecs(6);
    pg.setStopSignal(std.posix.SIG.QUIT);
    pg.setStopTimeout(8);
    pg.setAutoRestart(.unexpected);
    pg.setBackoffDelay(5);
    pg.setUmask(0o644);
    pg.setRedirectStdout(false);
    pg.setRedirectStderr(false);
    pg.setAutostart(false);
    try pg.setExitCodes(&.{ 0, 1, 2 });

    // Verify all settings
    try std.testing.expectEqualStrings("comprehensive-test", pg.name);
    try std.testing.expectEqualStrings("/bin/echo", pg.cmd);
    try std.testing.expectEqualStrings("/tmp", pg.working_directory);
    try std.testing.expectEqualStrings("/tmp/out.log", pg.stdout_path);
    try std.testing.expectEqualStrings("/tmp/err.log", pg.stderr_path);
    try std.testing.expectEqual(@as(u32, 7), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 3), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 4), pg.start_time);
    try std.testing.expectEqual(@as(u32, 6), pg.startsecs);
    try std.testing.expectEqual(std.posix.SIG.QUIT, pg.stop_signal);
    try std.testing.expectEqual(@as(u32, 8), pg.stop_timeout);
    try std.testing.expectEqual(ProcessGroup.AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.backoff_delay_s);
    try std.testing.expectEqual(@as(u16, 0o644), pg.umask);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    try std.testing.expectEqual(false, pg.redirect_stderr);
    try std.testing.expectEqual(false, pg.autostart);
}
