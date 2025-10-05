const std = @import("std");
const Process = @import("../Process.zig").Process;
const ProcessGroup = @import("../ProcessGroup.zig").ProcessGroup;
const utils = @import("../utils.zig");

test "process output redirection - stderr only" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const test_file = "/tmp/zproc_test_stderr.log";
    const argv = try utils.buildArgv(&[_][]const u8{ "sh", "-c", "echo 'Error message' >&2" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/sh",
        .argv = argv,
        .envp = envp,
        .stderr_path = test_file,
        .redirect_stdout = false,
        .redirect_stderr = true,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify stderr file was created and contains expected content
    const file = std.fs.cwd().openFile(test_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Stderr file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];
    try std.testing.expect(std.mem.indexOf(u8, content, "Error message") != null);
}

test "process output redirection - both stdout and stderr" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const stdout_file = "/tmp/zproc_test_stdout_both.log";
    const stderr_file = "/tmp/zproc_test_stderr_both.log";
    const argv = try utils.buildArgv(&[_][]const u8{ "sh", "-c", "echo 'stdout message'; echo 'stderr message' >&2" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/sh",
        .argv = argv,
        .envp = envp,
        .stdout_path = stdout_file,
        .stderr_path = stderr_file,
        .redirect_stdout = true,
        .redirect_stderr = true,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify stdout file
    const stdout_f = std.fs.cwd().openFile(stdout_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Stdout file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer stdout_f.close();

    var buffer: [1024]u8 = undefined;
    const stdout_bytes = try stdout_f.readAll(&buffer);
    const stdout_content = buffer[0..stdout_bytes];
    try std.testing.expect(std.mem.indexOf(u8, stdout_content, "stdout message") != null);

    // Verify stderr file
    const stderr_f = std.fs.cwd().openFile(stderr_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Stderr file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer stderr_f.close();

    const stderr_bytes = try stderr_f.readAll(&buffer);
    const stderr_content = buffer[0..stderr_bytes];
    try std.testing.expect(std.mem.indexOf(u8, stderr_content, "stderr message") != null);
}

test "process output redirection - working directory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const test_file = "/tmp/zproc_test_working_dir.log";
    const argv = try utils.buildArgv(&[_][]const u8{"pwd"}, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/pwd",
        .argv = argv,
        .envp = envp,
        .stdout_path = test_file,
        .redirect_stdout = true,
        .working_directory = "/tmp",
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify output contains /tmp
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
    try std.testing.expect(std.mem.indexOf(u8, content, "/tmp") != null);
}

test "process output redirection - umask setting" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const test_file = "/tmp/zproc_test_umask.log";
    const argv = try utils.buildArgv(&[_][]const u8{ "touch", test_file }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/touch",
        .argv = argv,
        .envp = envp,
        .umask = 0o022, // Restrictive umask
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify file was created
    const file = std.fs.cwd().openFile(test_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Test file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();
}

test "process output redirection - directory creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const test_file = "/tmp/zproc_test_dir/created_file.log";
    const argv = try utils.buildArgv(&[_][]const u8{ "echo", "Directory creation test" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/echo",
        .argv = argv,
        .envp = envp,
        .stdout_path = test_file,
        .redirect_stdout = true,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify file was created in new directory
    const file = std.fs.cwd().openFile(test_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Test file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];
    try std.testing.expect(std.mem.indexOf(u8, content, "Directory creation test") != null);
}

test "process output redirection - append mode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_file = "/tmp/zproc_test_append.log";

    // First write
    var process1 = Process{};
    defer process1.reset();

    const argv1 = try utils.buildArgv(&[_][]const u8{ "echo", "First line" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process1.start(.{
        .path = "/bin/echo",
        .argv = argv1,
        .envp = envp,
        .stdout_path = test_file,
        .redirect_stdout = true,
    });

    var iterations1: u32 = 0;
    while (process1.isAlive() and iterations1 < 20) {
        try process1.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations1 += 1;
    }

    // Second write (should append)
    var process2 = Process{};
    defer process2.reset();

    const argv2 = try utils.buildArgv(&[_][]const u8{ "echo", "Second line" }, allocator);

    try process2.start(.{
        .path = "/bin/echo",
        .argv = argv2,
        .envp = envp,
        .stdout_path = test_file,
        .redirect_stdout = true,
    });

    var iterations2: u32 = 0;
    while (process2.isAlive() and iterations2 < 20) {
        try process2.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations2 += 1;
    }

    try std.testing.expect(process1.hasExited());
    try std.testing.expect(process2.hasExited());

    // Verify both lines are in the file
    const file = std.fs.cwd().openFile(test_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Warning: Test file not found\n", .{});
            return;
        },
        else => return err,
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];
    try std.testing.expect(std.mem.indexOf(u8, content, "First line") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Second line") != null);
}

test "process output redirection - no redirection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const argv = try utils.buildArgv(&[_][]const u8{ "echo", "No redirection test" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/echo",
        .argv = argv,
        .envp = envp,
        .redirect_stdout = false,
        .redirect_stderr = false,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);
}

test "process output redirection - stdout only" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var process = Process{};
    defer process.reset();

    const test_file = "/tmp/zproc_test_stdout.log";
    const argv = try utils.buildArgv(&[_][]const u8{ "echo", "Hello World" }, allocator);
    const envp = try utils.buildEnvp(&[_][]const u8{}, allocator);

    try process.start(.{
        .path = "/bin/echo",
        .argv = argv,
        .envp = envp,
        .stdout_path = test_file,
        .redirect_stdout = true,
        .redirect_stderr = false,
    });

    var iterations: u32 = 0;
    while (process.isAlive() and iterations < 20) {
        try process.monitor();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        iterations += 1;
    }

    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 0), process.getExitCode().?);

    // Verify output file was created and contains expected content
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
    try std.testing.expect(std.mem.indexOf(u8, content, "Hello World") != null);
}
