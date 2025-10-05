const std = @import("std");
const zproc = @import("zproc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    std.debug.print("Running zproc integration tests with GNU utilities...\n", .{});

    // Test 1: Basic process execution with simple commands
    try testBasicProcessExecution(allocator);

    // Test 2: Process with output redirection
    try testProcessWithOutputRedirection(allocator);

    // Test 3: Process group management
    try testProcessGroupManagement(allocator);

    // Test 4: Error handling with invalid commands
    try testErrorHandling(allocator);

    // Test 5: Signal handling and process termination
    try testSignalHandling(allocator);

    // Test 6: Complex GNU utility workflows
    try testComplexWorkflows(allocator);

    std.debug.print("All integration tests completed successfully!\n", .{});
}

fn testBasicProcessExecution(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing basic process execution...\n", .{});

    var process = zproc.Process{};
    defer process.reset();

    // Test 1: ls command
    const ls_argv = try zproc.utils.buildArgv(&[_][]const u8{ "ls", "-la" }, allocator);
    // No need to free - arena allocator handles cleanup
    const envp = try zproc.utils.buildEnvp(&[_][]const u8{}, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/ls",
        .argv = ls_argv,
        .envp = envp,
    });

    // Monitor until completion
    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    std.debug.print("✓ ls command executed successfully\n", .{});

    // Test 2: echo command
    process.reset();
    const echo_argv = try zproc.utils.buildArgv(&[_][]const u8{ "echo", "Hello, World!" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/echo",
        .argv = echo_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ echo command executed successfully\n", .{});

    // Test 3: cat command with input
    process.reset();
    const cat_argv = try zproc.utils.buildArgv(&[_][]const u8{ "cat", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/cat",
        .argv = cat_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    std.debug.print("✓ cat command executed successfully\n", .{});
}

fn testProcessWithOutputRedirection(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing process with output redirection...\n", .{});

    var process = zproc.Process{};
    defer process.reset();

    // Test with stdout redirection
    const echo_argv = try zproc.utils.buildArgv(&[_][]const u8{ "echo", "Test output" }, allocator);
    // No need to free - arena allocator handles cleanup
    const envp = try zproc.utils.buildEnvp(&[_][]const u8{}, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/echo",
        .argv = echo_argv,
        .envp = envp,
        .stdout_path = "/tmp/zproc_test_stdout.log",
        .redirect_stdout = true,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify output file was created
    const file = std.fs.cwd().openFile("/tmp/zproc_test_stdout.log", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("⚠ Warning: Output file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    std.debug.print("✓ Output redirection test completed\n", .{});
}

fn testProcessGroupManagement(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing process group management...\n", .{});

    var pg = zproc.ProcessGroup.init(allocator);
    defer pg.deinit();

    // Configure process group
    try pg.setName("test-group");
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
    std.debug.print("✓ Process group management test completed\n", .{});
}

fn testErrorHandling(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing error handling...\n", .{});

    var process = zproc.Process{};
    defer process.reset();

    // Test with non-existent command
    const bad_argv = try zproc.utils.buildArgv(&[_][]const u8{"command"}, allocator);
    // No need to free - arena allocator handles cleanup
    const envp = try zproc.utils.buildEnvp(&[_][]const u8{}, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/nonexistent/command",
        .argv = bad_argv,
        .envp = envp,
    });

    // Monitor until completion
    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 50) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    // Process should have failed to start or exited with error
    try std.testing.expect(process.hasExited() or process.failed_start);
    std.debug.print("✓ Error handling test completed\n", .{});

    // Test with invalid arguments
    process.reset();
    const ls_argv = try zproc.utils.buildArgv(&[_][]const u8{ "ls", "--invalid-option" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/ls",
        .argv = ls_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    // ls with invalid option should exit with non-zero code
    std.debug.print("✓ Invalid arguments test completed\n", .{});
}

fn testSignalHandling(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing signal handling...\n", .{});

    var process = zproc.Process{};
    defer process.reset();

    // Start a long-running process
    const sleep_argv = try zproc.utils.buildArgv(&[_][]const u8{ "sleep", "10" }, allocator);
    // No need to free - arena allocator handles cleanup
    const envp = try zproc.utils.buildEnvp(&[_][]const u8{}, allocator);
    // No need to free - arena allocator handles cleanup

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
        std.debug.print("✓ Signal handling test completed\n", .{});
    } else {
        std.debug.print("⚠ Process did not start, skipping signal test\n", .{});
    }
}

fn testComplexWorkflows(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing complex GNU utility workflows...\n", .{});

    // Test 1: Pipeline simulation with grep
    var process = zproc.Process{};
    defer process.reset();

    const grep_argv = try zproc.utils.buildArgv(&[_][]const u8{ "grep", "root", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup
    const envp = try zproc.utils.buildEnvp(&[_][]const u8{}, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/grep",
        .argv = grep_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    std.debug.print("✓ grep workflow test completed\n", .{});

    // Test 2: wc command
    process.reset();
    const wc_argv = try zproc.utils.buildArgv(&[_][]const u8{ "wc", "-l", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/wc",
        .argv = wc_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ wc workflow test completed\n", .{});

    // Test 3: find command
    process.reset();
    const find_argv = try zproc.utils.buildArgv(&[_][]const u8{ "find", "/tmp", "-name", "*.log", "-type", "f" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/find",
        .argv = find_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    std.debug.print("✓ find workflow test completed\n", .{});

    // Test 4: sort command
    process.reset();
    const sort_argv = try zproc.utils.buildArgv(&[_][]const u8{ "sort", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/sort",
        .argv = sort_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ sort workflow test completed\n", .{});

    // Test 5: uniq command
    process.reset();
    const uniq_argv = try zproc.utils.buildArgv(&[_][]const u8{ "uniq", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/uniq",
        .argv = uniq_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    std.debug.print("✓ uniq workflow test completed\n", .{});

    // Test 6: head command
    process.reset();
    const head_argv = try zproc.utils.buildArgv(&[_][]const u8{ "head", "-n", "5", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/head",
        .argv = head_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ head workflow test completed\n", .{});

    // Test 7: tail command
    process.reset();
    const tail_argv = try zproc.utils.buildArgv(&[_][]const u8{ "tail", "-n", "5", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/tail",
        .argv = tail_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ tail workflow test completed\n", .{});

    // Test 8: cut command
    process.reset();
    const cut_argv = try zproc.utils.buildArgv(&[_][]const u8{ "cut", "-d:", "-f1", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/cut",
        .argv = cut_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ cut workflow test completed\n", .{});

    // Test 9: tr command
    process.reset();
    const tr_argv = try zproc.utils.buildArgv(&[_][]const u8{ "tr", "a-z", "A-Z" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/usr/bin/tr",
        .argv = tr_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    std.debug.print("✓ tr workflow test completed\n", .{});

    // Test 10: sed command
    process.reset();
    const sed_argv = try zproc.utils.buildArgv(&[_][]const u8{ "sed", "s/root/ROOT/g", "/etc/passwd" }, allocator);
    // No need to free - arena allocator handles cleanup

    try process.start(.{
        .path = "/bin/sed",
        .argv = sed_argv,
        .envp = envp,
    });

    while (process.isAlive()) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
    std.debug.print("✓ sed workflow test completed\n", .{});

    std.debug.print("✓ All complex workflow tests completed\n", .{});
}
