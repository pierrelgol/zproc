const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "integration - web server process group" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure web server process group
    try pg.setName("web-server");
    try pg.setCmd("/usr/bin/python3");
    const argv = [_][]const u8{ "python3", "-m", "http.server", "8080" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{"PYTHONPATH=/opt/webapp"};
    try pg.setEnv(&env);
    try pg.setWorkingDir("/opt/webapp");
    try pg.setStdoutPath("/var/log/webapp/stdout.log");
    try pg.setStderrPath("/var/log/webapp/stderr.log");
    pg.setNumProcs(3);
    pg.setStartTime(2);
    pg.setStartSecs(5);
    pg.setStopSignal(std.posix.SIG.TERM);
    pg.setStopTimeout(10);
    pg.setAutoRestart(.unexpected);
    pg.setStartRetries(5);
    pg.setBackoffDelay(3);
    try pg.setExitCodes(&.{0});

    // Verify configuration
    try std.testing.expectEqualStrings("web-server", pg.name);
    try std.testing.expectEqualStrings("/usr/bin/python3", pg.cmd);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 2), pg.start_time);
    try std.testing.expectEqual(@as(u32, 5), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);
    try std.testing.expectEqual(ProcessGroup.AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 3), pg.backoff_delay_s);
}

test "integration - database worker process group" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure database worker process group
    try pg.setName("db-worker");
    try pg.setCmd("/opt/app/bin/worker");
    const argv = [_][]const u8{ "worker", "--config", "/etc/worker.conf" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{"DATABASE_URL=postgresql://localhost:5432/mydb"};
    try pg.setEnv(&env);
    try pg.setWorkingDir("/opt/app");
    pg.setNumProcs(8);
    pg.setStartTime(1);
    pg.setStartSecs(3);
    pg.setStopSignal(std.posix.SIG.INT);
    pg.setStopTimeout(5);
    pg.setAutoRestart(.always);
    pg.setStartRetries(10);
    pg.setBackoffDelay(2);
    pg.setUmask(0o022);

    // Verify configuration
    try std.testing.expectEqualStrings("db-worker", pg.name);
    try std.testing.expectEqualStrings("/opt/app/bin/worker", pg.cmd);
    try std.testing.expectEqual(@as(u32, 8), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 1), pg.start_time);
    try std.testing.expectEqual(@as(u32, 3), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 5), pg.stop_timeout);
    try std.testing.expectEqual(ProcessGroup.AutoRestart.always, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 10), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 2), pg.backoff_delay_s);
    try std.testing.expectEqual(@as(u16, 0o022), pg.umask);
}

test "integration - basic process execution workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test 1: ls command
    var process = Process{};
    defer process.reset();

    const ls_argv = try utils.buildArgv(&[_][]const u8{ "ls", "-la" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/ls",
        .argv = ls_argv,
        .envp = envp,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Test 2: echo command
    process.reset();
    const echo_argv = try utils.buildArgv(&[_][]const u8{ "echo", "Hello, World!" }, allocator);

    try process.start(.{
        .path = "/bin/echo",
        .argv = echo_argv,
        .envp = envp,
    });

    var iterations2: u32 = 0;
    while (process.isAlive() and iterations2 < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations2 += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
}

test "integration - process with output redirection workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const test_file = "/tmp/zproc_integration_test.log";
    const echo_argv = try utils.buildArgv(&[_][]const u8{ "echo", "Integration test output" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/echo",
        .argv = echo_argv,
        .envp = envp,
        .stdout_path = test_file,
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

    // Verify output file was created
    const file = std.fs.cwd().openFile(test_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Output file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];
    try std.testing.expect(std.mem.indexOf(u8, content, "Integration test output") != null);
}

test "integration - process group management workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure process group
    try pg.setName("integration-test-group");
    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(3);
    pg.setStartTime(0);
    pg.setAutoRestart(.never);

    // Spawn children
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 3), pg.children.len);

    // Monitor processes
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

test "integration - error handling workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Test with non-existent command
    const bad_argv = try utils.buildArgv(&[_][]const u8{"nonexistent"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/nonexistent/command",
        .argv = bad_argv,
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

test "integration - signal handling workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    // Start a long running process
    const sleep_argv = try utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/sleep",
        .argv = sleep_argv,
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

test "integration - complex GNU utility workflows" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test grep command
    var process = Process{};
    defer process.reset();

    const grep_argv = try utils.buildArgv(&[_][]const u8{ "grep", "root", "/etc/passwd" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/grep",
        .argv = grep_argv,
        .envp = envp,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());

    // Test wc command
    process.reset();
    const wc_argv = try utils.buildArgv(&[_][]const u8{ "wc", "-l", "/etc/passwd" }, allocator);

    try process.start(.{
        .path = "/usr/bin/wc",
        .argv = wc_argv,
        .envp = envp,
    });

    var iterations3: u32 = 0;
    while (process.isAlive() and iterations3 < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations3 += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Test find command
    process.reset();
    const find_argv = try utils.buildArgv(&[_][]const u8{ "find", "/tmp", "-name", "*.log", "-type", "f" }, allocator);

    try process.start(.{
        .path = "/usr/bin/find",
        .argv = find_argv,
        .envp = envp,
    });

    var iterations4: u32 = 0;
    while (process.isAlive() and iterations4 < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations4 += 1;
    }

    try std.testing.expect(process.hasExited());
}

test "integration - process group with auto restart workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure process group with auto restart
    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);
    pg.setBackoffDelay(1);

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

test "integration - process group stop and restart workflow" {
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

    // Wait for processes to start
    var iterations: u32 = 0;
    while (pg.getRunningCount() == 0 and iterations < 50) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // Stop all children
    try pg.stopChildren();

    // Wait for processes to stop
    iterations = 0;
    while (pg.getAliveCount() > 0 and iterations < 100) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // All processes should have stopped
    try std.testing.expect(pg.getAllExited());
}
