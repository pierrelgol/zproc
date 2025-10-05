const std = @import("std");
const posix = std.posix;
const Process = @import("Process.zig").Process;
const Logger = @import("Logger.zig").Logger;
pub const ProcessGroup = @This();

pub const AutoRestart = enum {
    always,
    never,
    unexpected,
};

arena: std.heap.ArenaAllocator,
name: []const u8 = "",
cmd: [:0]const u8 = "",
argv: ?[*:null]?[*:0]u8 = null,
envp: ?[*:null]?[*:0]u8 = null,
working_directory: [:0]const u8 = "",
stdout_path: [:0]const u8 = "",
stderr_path: [:0]const u8 = "",
redirect_stdout: bool = true,
redirect_stderr: bool = true,
umask: u16 = 0,
numprocs: u32 = 0,
start_retries: u32 = 0,
start_time: u32 = 0,
startsecs: u32 = 1,
autostart: bool = true,
stop_signal: u8 = posix.SIG.TERM,
stop_timeout: u32 = 0,
autorestart: AutoRestart = .unexpected,
exitcodes: []const u32 = &.{0},
children: []Process = &.{},

pub fn init(gpa: std.mem.Allocator) ProcessGroup {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
}

pub fn deinit(self: *ProcessGroup) void {
    self.arena.deinit();
}

pub fn setName(self: *ProcessGroup, name: []const u8) !void {
    self.name = try self.arena.allocator().dupe(u8, name);
}

pub fn setCmd(self: *ProcessGroup, cmd: []const u8) !void {
    self.cmd = try self.arena.allocator().dupeZ(u8, cmd);
}

pub fn setArgv(self: *ProcessGroup, argv: []const []const u8) !void {
    self.argv = try buildArgv(argv, self.arena.allocator());
}

pub fn setEnv(self: *ProcessGroup, envp: []const []const u8) !void {
    self.envp = try buildEnvp(envp, self.arena.allocator());
}

pub fn setWorkingDir(self: *ProcessGroup, wd: []const u8) !void {
    self.working_directory = try self.arena.allocator().dupeZ(u8, wd);
}

pub fn setStdoutPath(self: *ProcessGroup, path: []const u8) !void {
    self.stdout_path = try self.arena.allocator().dupeZ(u8, path);
}

pub fn setStderrPath(self: *ProcessGroup, path: []const u8) !void {
    self.stderr_path = try self.arena.allocator().dupeZ(u8, path);
}

pub fn setUmask(self: *ProcessGroup, mask: u16) void {
    self.umask = mask;
}

pub fn setNumProcs(self: *ProcessGroup, n: u32) void {
    self.numprocs = n;
}

pub fn setStartRetries(self: *ProcessGroup, n: u32) void {
    self.start_retries = n;
}

pub fn setStartTime(self: *ProcessGroup, secs: u32) void {
    self.start_time = secs;
}

pub fn setStopSignal(self: *ProcessGroup, sig: u8) void {
    self.stop_signal = sig;
}

pub fn setStopTimeout(self: *ProcessGroup, secs: u32) void {
    self.stop_timeout = secs;
}

pub fn setRedirectStdout(self: *ProcessGroup, redirect: bool) void {
    self.redirect_stdout = redirect;
}

pub fn setRedirectStderr(self: *ProcessGroup, redirect: bool) void {
    self.redirect_stderr = redirect;
}

pub fn setStartSecs(self: *ProcessGroup, secs: u32) void {
    self.startsecs = secs;
}

pub fn setAutostart(self: *ProcessGroup, auto: bool) void {
    self.autostart = auto;
}

pub fn setAutoRestart(self: *ProcessGroup, policy: AutoRestart) void {
    self.autorestart = policy;
}

pub fn setExitCodes(self: *ProcessGroup, codes: []const u32) !void {
    self.exitcodes = try self.arena.allocator().dupeZ(u32, codes);
}

pub fn spawnChildren(self: *ProcessGroup, logger: ?*Logger) !void {
    if (self.cmd.len == 0) return error.MissingCommand;
    if (self.argv == null) return error.MissingArgv;
    if (self.envp == null) return error.MissingEnvp;
    if (self.numprocs == 0) return error.NoProcesses;

    self.children = try self.arena.allocator().alloc(Process, self.numprocs);

    if (logger) |l| {
        l.info("Spawning {} processes for command: {s}", .{ self.numprocs, self.cmd });
    }

    for (self.children, 0..) |*c, i| {
        c.* = .{
            .id = @intCast(i),
            .start_gate_s = self.start_time,
        };

        c.startsecs = self.startsecs;
        try c.start(.{
            .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
            .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
            .redirect_stdout = self.redirect_stdout,
            .redirect_stderr = self.redirect_stderr,
            .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
            .umask = if (self.umask != 0) self.umask else null,
            .path = self.cmd,
            .argv = self.argv.?,
            .envp = self.envp.?,
        });

        if (logger) |l| {
            l.info("Started process {} with PID {}", .{ i, c.pid orelse 0 });
        }
    }
}

pub fn stopChildren(self: *ProcessGroup, logger: ?*Logger) !void {
    if (logger) |l| {
        l.info("Stopping all processes", .{});
    }

    for (self.children, 0..) |*c, i| {
        if (c.isAlive()) {
            if (logger) |l| {
                l.info("Stopping process {} (PID: {})", .{ i, c.pid orelse 0 });
            }
            c.stop(self.stop_signal, self.stop_timeout) catch |err| switch (err) {
                error.InvalidState => {},
                else => return err,
            };
        }
    }
}

pub fn monitorChildren(self: *ProcessGroup, logger: ?*Logger) !void {
    for (self.children, 0..) |*c, i| {
        try c.monitor();

        if (c.hasExited()) {
            const exit_code = c.getExitCode();
            const exit_signal = c.getExitSignal();

            if (logger) |l| {
                if (exit_code) |code| {
                    l.info("Process {} exited with code {}", .{ i, code });
                } else if (exit_signal) |signal| {
                    l.info("Process {} killed by signal {}", .{ i, signal });
                } else {
                    l.info("Process {} exited unexpectedly", .{i});
                }
            }

            const should_restart = self.shouldRestart(c);
            if (should_restart and c.retries_count < self.start_retries) {
                c.retries_count += 1;
                c.reset();

                if (logger) |l| {
                    l.info("Restarting process {} (attempt {}/{})", .{ i, c.retries_count, self.start_retries });
                }

                try c.start(.{
                    .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
                    .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
                    .redirect_stdout = self.redirect_stdout,
                    .redirect_stderr = self.redirect_stderr,
                    .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
                    .umask = if (self.umask != 0) self.umask else null,
                    .path = self.cmd,
                    .argv = self.argv.?,
                    .envp = self.envp.?,
                });
            } else if (should_restart and c.retries_count >= self.start_retries) {
                if (logger) |l| {
                    l.err("Process {} exceeded restart limit, giving up", .{i});
                }
            }
        }
    }
}

pub fn getStatus(self: *const ProcessGroup) []const Process.State {
    return self.children;
}

pub fn getRunningCount(self: *const ProcessGroup) u32 {
    var count: u32 = 0;
    for (self.children) |*c| {
        if (c.isRunning()) count += 1;
    }
    return count;
}

pub fn getAliveCount(self: *const ProcessGroup) u32 {
    var count: u32 = 0;
    for (self.children) |*c| {
        if (c.isAlive()) count += 1;
    }
    return count;
}

pub fn getAllExited(self: *const ProcessGroup) bool {
    for (self.children) |*c| {
        if (c.isAlive()) return false;
    }
    return true;
}

pub fn stopChild(self: *ProcessGroup, child_id: u32) !void {
    if (child_id >= self.children.len) return error.InvalidChildId;
    try self.children[child_id].stop(self.stop_signal, self.stop_timeout);
}

pub fn killChild(self: *ProcessGroup, child_id: u32) !void {
    if (child_id >= self.children.len) return error.InvalidChildId;
    try self.children[child_id].kill();
}

pub fn restartChild(self: *ProcessGroup, child_id: u32) !void {
    if (child_id >= self.children.len) return error.InvalidChildId;
    var child = &self.children[child_id];

    if (child.isAlive()) {
        try child.stop(self.stop_signal, self.stop_timeout);

        return;
    }

    child.reset();
    child.retries_count = 0;

    child.startsecs = self.startsecs;
    try child.start(.{
        .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
        .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
        .redirect_stdout = self.redirect_stdout,
        .redirect_stderr = self.redirect_stderr,
        .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
        .umask = if (self.umask != 0) self.umask else null,
        .path = self.cmd,
        .argv = self.argv.?,
        .envp = self.envp.?,
    });
}

fn shouldRestart(self: *ProcessGroup, process: *Process) bool {
    switch (self.autorestart) {
        .always => return true,
        .never => return false,
        .unexpected => {
            if (process.getExitCode()) |code| {
                for (self.exitcodes) |expected_code| {
                    if (code == expected_code) {
                        return false;
                    }
                }
                return true;
            }
            return true;
        },
    }
}

fn buildArgv(argv: []const []const u8, arena: std.mem.Allocator) ![:null]?[*:0]u8 {
    const result = try arena.allocSentinel(?[*:0]u8, argv.len, null);
    for (argv, 0..) |arg, i| {
        result[i] = try std.fmt.allocPrintSentinel(arena, "{s}", .{arg}, 0);
    }
    return result;
}

fn buildEnvp(env: []const []const u8, arena: std.mem.Allocator) ![:null]?[*:0]u8 {
    const envp = try arena.allocSentinel(?[*:0]u8, env.len, null);
    for (env, 0..) |pair, i| {
        envp[i] = try std.fmt.allocPrintSentinel(arena, "{s}", .{pair}, 0);
    }
    return envp;
}

test "process group initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(@as(u32, 0), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 0), pg.start_time);
    try std.testing.expectEqual(@as(u32, 0), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(std.posix.SIG.TERM, pg.stop_signal);
}

test "process group configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("test-process");
    try std.testing.expectEqualStrings("test-process", pg.name);

    try pg.setCmd("/bin/sleep");
    try std.testing.expectEqualStrings("/bin/sleep", pg.cmd);

    pg.setNumProcs(3);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);

    pg.setStartTime(5);
    try std.testing.expectEqual(@as(u32, 5), pg.start_time);

    pg.setStopTimeout(10);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);

    pg.setAutoRestart(.always);
    try std.testing.expectEqual(AutoRestart.always, pg.autorestart);
}

test "auto restart logic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setAutoRestart(.always);
    var process = Process{ .exit_code = 0 };
    try std.testing.expect(pg.shouldRestart(&process));

    pg.setAutoRestart(.never);
    try std.testing.expect(!pg.shouldRestart(&process));

    pg.setAutoRestart(.unexpected);
    try pg.setExitCodes(&.{0});
    try std.testing.expect(!pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = null;
    process.exit_signal = 9;
    try std.testing.expect(pg.shouldRestart(&process));
}

test "process group spawn children configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{"TEST=1"};
    try pg.setEnv(&env);
    pg.setNumProcs(2);
    pg.setStartTime(3);

    pg.children = try pg.arena.allocator().alloc(Process, pg.numprocs);
    for (pg.children, 0..) |*c, i| {
        c.* = .{
            .id = @intCast(i),
            .start_gate_s = pg.start_time,
        };
    }

    try std.testing.expectEqual(@as(usize, 2), pg.children.len);
    for (pg.children) |*c| {
        try std.testing.expectEqual(@as(u32, 3), c.start_gate_s);
    }
}

test "process group management functions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(3);

    pg.children = try pg.arena.allocator().alloc(Process, pg.numprocs);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i) };
    }

    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    pg.children[0].state = .running;
    pg.children[1].state = .starting;
    pg.children[2].state = .exited;

    try std.testing.expectEqual(@as(u32, 1), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 2), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());
}

test "process group configuration validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectError(error.MissingCommand, pg.spawnChildren());

    try pg.setCmd("/bin/true");
    try std.testing.expectError(error.MissingArgv, pg.spawnChildren());

    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    try std.testing.expectError(error.MissingEnvp, pg.spawnChildren());

    const env = [_][]const u8{};
    try pg.setEnv(&env);
    try std.testing.expectError(error.NoProcesses, pg.spawnChildren());
}

test "process group individual child control" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    pg.children = try pg.arena.allocator().alloc(Process, pg.numprocs);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i), .state = .running };
    }

    try std.testing.expectError(error.InvalidChildId, pg.stopChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.killChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.restartChild(5));

    pg.stopChild(0) catch |err| switch (err) {
        error.InvalidState => {},
        else => return err,
    };
}

test "process group new configuration options" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setAutostart(false);
    try std.testing.expectEqual(false, pg.autostart);
    pg.setAutostart(true);
    try std.testing.expectEqual(true, pg.autostart);

    pg.setRedirectStdout(false);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    pg.setRedirectStdout(true);
    try std.testing.expectEqual(true, pg.redirect_stdout);

    pg.setRedirectStderr(false);
    try std.testing.expectEqual(false, pg.redirect_stderr);
    pg.setRedirectStderr(true);
    try std.testing.expectEqual(true, pg.redirect_stderr);

    pg.setStartSecs(5);
    try std.testing.expectEqual(@as(u32, 5), pg.startsecs);
    pg.setStartSecs(10);
    try std.testing.expectEqual(@as(u32, 10), pg.startsecs);
}

test "process startsecs validation" {
    var process = Process{ .startsecs = 2 };
    const start_time = std.time.nanoTimestamp();
    process.start_time_ns = @truncate(@abs(start_time));
    process.start_gate_started_ns = process.start_time_ns;
    process.state = .starting;
    process.pid = 12345;

    std.time.sleep(100 * std.time.ns_per_ms);
    try process.monitor();
    try std.testing.expectEqual(Process.State.starting, process.state);

    std.time.sleep(1100 * std.time.ns_per_ms);
    try process.monitor();
    try std.testing.expectEqual(Process.State.running, process.state);
    try std.testing.expect(process.successfully_started_ns > 0);

    std.time.sleep(1500 * std.time.ns_per_ms);
    try process.monitor();
    try std.testing.expectEqual(Process.State.running, process.state);
}
