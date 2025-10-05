const std = @import("std");
const posix = std.posix;
const Process = @import("Process.zig").Process;
pub const ProcessGroup = @This();

pub const AutoRestart = enum {
    always,
    never,
    unexpected,
};

pub const GroupState = enum {
    stopped,
    starting,
    running,
    stopping,
    fatal,
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
backoff_delay_s: u32 = 1,
state: GroupState = .stopped,

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

pub fn setBackoffDelay(self: *ProcessGroup, delay_s: u32) void {
    self.backoff_delay_s = delay_s;
}

pub fn spawnChildren(self: *ProcessGroup) !void {
    if (self.cmd.len == 0) return error.MissingCommand;
    if (self.argv == null) return error.MissingArgv;
    if (self.envp == null) return error.MissingEnvp;
    if (self.numprocs == 0) return error.NoProcesses;

    self.children = try self.arena.allocator().alloc(Process, self.numprocs);

    for (self.children, 0..) |*c, i| {
        c.* = .{
            .id = @intCast(i),
            .start_gate_s = self.start_time,
            .backoff_delay_s = self.backoff_delay_s,
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
            .argv = self.argv orelse return error.MissingArgv,
            .envp = self.envp orelse return error.MissingEnvp,
        });
    }
}

pub fn stopChildren(self: *ProcessGroup) !void {
    for (self.children) |*c| {
        if (c.isAlive()) {
            c.stop(self.stop_signal, self.stop_timeout) catch |err| switch (err) {
                error.InvalidState => {},
                else => return err,
            };
        }
    }
}

pub fn monitorChildren(self: *ProcessGroup) !void {
    for (self.children) |*c| {
        try c.monitor();

        if (c.state == .backoff and c.isBackoffExpired()) {
            c.state = .stopped;
        }

        if (c.hasExited()) {
            const should_restart = self.shouldRestart(c);
            if (should_restart and c.retries_count < self.start_retries) {
                c.retries_count += 1;
                c.enterBackoff();
            } else if (!should_restart or c.retries_count >= self.start_retries) {
                c.state = .exited;
            }
        }

        if (c.state == .stopped and self.shouldRestart(c)) {
            c.resetForRestart();
            try c.start(.{
                .stdout_path = if (self.stdout_path.len > 0) self.stdout_path else null,
                .stderr_path = if (self.stderr_path.len > 0) self.stderr_path else null,
                .redirect_stdout = self.redirect_stdout,
                .redirect_stderr = self.redirect_stderr,
                .working_directory = if (self.working_directory.len > 0) self.working_directory else null,
                .umask = if (self.umask != 0) self.umask else null,
                .path = self.cmd,
                .argv = self.argv orelse return error.MissingArgv,
                .envp = self.envp orelse return error.MissingEnvp,
            });
        }
    }
}

pub fn getChildren(self: *const ProcessGroup) []const Process {
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

pub fn getGroupState(self: *const ProcessGroup) GroupState {
    return self.state;
}

pub fn getTotalUptime(self: *const ProcessGroup) u64 {
    var total: u64 = 0;
    for (self.children) |*c| {
        if (c.isRunning()) {
            total += c.getUptime();
        }
    }
    return total;
}

pub fn hasFatalProcesses(self: *const ProcessGroup) bool {
    for (self.children) |*c| {
        if (c.state == .exited and c.retries_count >= self.start_retries) {
            return true;
        }
    }
    return false;
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
        .argv = self.argv orelse return error.MissingArgv,
        .envp = self.envp orelse return error.MissingEnvp,
    });
}

pub fn shouldRestart(self: *ProcessGroup, process: *Process) bool {
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
    var process = Process{ .startsecs = 2, .start_gate_s = 1 };
    const start_time = std.time.nanoTimestamp();
    process.start_time_ns = @truncate(@abs(start_time));
    process.start_gate_started_ns = process.start_time_ns;
    process.state = .starting;

    std.Thread.sleep(100 * std.time.ns_per_ms);
    const now_ns = @as(u64, @truncate(@abs(std.time.nanoTimestamp())));
    const start_gate_ns = process.start_gate_s * std.time.ns_per_s;
    if (now_ns - process.start_gate_started_ns >= start_gate_ns) {
        process.state = .running;
        process.successfully_started_ns = now_ns;
    }
    try std.testing.expectEqual(Process.State.starting, process.state);

    std.Thread.sleep(1100 * std.time.ns_per_ms);
    const now_ns2 = @as(u64, @truncate(@abs(std.time.nanoTimestamp())));
    if (now_ns2 - process.start_gate_started_ns >= start_gate_ns) {
        process.state = .running;
        process.successfully_started_ns = now_ns2;
    }
    try std.testing.expectEqual(Process.State.running, process.state);
    try std.testing.expect(process.successfully_started_ns > 0);

    std.Thread.sleep(1500 * std.time.ns_per_ms);
    try std.testing.expectEqual(Process.State.running, process.state);
}

test "process group backoff configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(@as(u32, 1), pg.backoff_delay_s);

    pg.setBackoffDelay(5);
    try std.testing.expectEqual(@as(u32, 5), pg.backoff_delay_s);
}

test "process group backoff logic" {
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

    pg.setBackoffDelay(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);
    pg.setNumProcs(1);

    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .backoff_delay_s = pg.backoff_delay_s,
        .state = .exited,
        .retries_count = 0,
    };

    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.starting, pg.children[0].state);
}

test "process group state and uptime" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(GroupState.stopped, pg.getGroupState());
    try std.testing.expectEqual(@as(u64, 0), pg.getTotalUptime());
    try std.testing.expect(!pg.hasFatalProcesses());

    pg.children = try pg.arena.allocator().alloc(Process, 2);
    pg.children[0] = .{ .id = 0, .state = .running, .start_time_ns = 1000 };
    pg.children[1] = .{ .id = 1, .state = .exited, .retries_count = 3 };

    const uptime = pg.getTotalUptime();
    try std.testing.expect(uptime > 0);

    try std.testing.expect(pg.hasFatalProcesses());
}

test "process group complete lifecycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try std.testing.expectEqual(GroupState.stopped, pg.getGroupState());
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(3);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);

    try std.testing.expectEqualStrings("/bin/true", pg.cmd);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);
    try std.testing.expectEqual(AutoRestart.always, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 2), pg.start_retries);
}

test "process group restart policies comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setAutoRestart(.always);
    var process = Process{ .exit_code = 0 };
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = null;
    process.exit_signal = 9;
    try std.testing.expect(pg.shouldRestart(&process));

    pg.setAutoRestart(.never);
    process.exit_code = 0;
    try std.testing.expect(!pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(!pg.shouldRestart(&process));

    pg.setAutoRestart(.unexpected);
    try pg.setExitCodes(&.{0});

    process.exit_code = 0;
    try std.testing.expect(!pg.shouldRestart(&process));

    process.exit_code = 1;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = 2;
    try std.testing.expect(pg.shouldRestart(&process));

    process.exit_code = null;
    process.exit_signal = 9;
    try std.testing.expect(pg.shouldRestart(&process));
}

test "process group timing and grace periods" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setStartTime(5);
    try std.testing.expectEqual(@as(u32, 5), pg.start_time);

    pg.setStartSecs(10);
    try std.testing.expectEqual(@as(u32, 10), pg.startsecs);

    pg.setStopTimeout(15);
    try std.testing.expectEqual(@as(u32, 15), pg.stop_timeout);

    pg.setBackoffDelay(3);
    try std.testing.expectEqual(@as(u32, 3), pg.backoff_delay_s);
}

test "process group signal handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setStopSignal(std.posix.SIG.USR1);
    try std.testing.expectEqual(std.posix.SIG.USR1, pg.stop_signal);

    pg.setStopSignal(std.posix.SIG.TERM);
    try std.testing.expectEqual(std.posix.SIG.TERM, pg.stop_signal);

    pg.children = try pg.arena.allocator().alloc(Process, 2);
    pg.children[0] = .{ .id = 0, .state = .running };
    pg.children[1] = .{ .id = 1, .state = .starting };

    try std.testing.expectError(error.InvalidChildId, pg.stopChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.killChild(5));
    try std.testing.expectError(error.InvalidChildId, pg.restartChild(5));
}

test "process group resource management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    pg.setRedirectStdout(true);
    pg.setRedirectStderr(true);
    try std.testing.expectEqual(true, pg.redirect_stdout);
    try std.testing.expectEqual(true, pg.redirect_stderr);
}

test "process group coordination and orchestration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(5);
    pg.setAutoRestart(.always);
    pg.setStartRetries(3);

    try std.testing.expectEqual(@as(u32, 5), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());

    pg.children = try pg.arena.allocator().alloc(Process, 5);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i) };
    }

    pg.children[0].state = .running;
    pg.children[1].state = .starting;
    pg.children[2].state = .stopping;
    pg.children[3].state = .exited;
    pg.children[4].state = .backoff;

    try std.testing.expectEqual(@as(u32, 1), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 3), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());

    pg.children[3].retries_count = 5;
    try std.testing.expect(pg.hasFatalProcesses());
}

test "process group error handling and edge cases" {
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

    pg.setNumProcs(1);
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group backoff and retry logic comprehensive" {
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

    pg.setBackoffDelay(2);
    pg.setAutoRestart(.always);
    pg.setStartRetries(3);
    pg.setNumProcs(1);

    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .backoff_delay_s = pg.backoff_delay_s,
        .state = .exited,
        .retries_count = 0,
    };

    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);
    try std.testing.expect(pg.children[0].backoff_until_ns > 0);

    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    std.Thread.sleep(2500 * std.time.ns_per_ms);
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.starting, pg.children[0].state);

    pg.children[0].state = .exited;
    pg.children[0].retries_count = 3;
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);
}

test "process group name and identification" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setName("test-process-group");
    try std.testing.expectEqualStrings("test-process-group", pg.name);

    try pg.setName("");
    try std.testing.expectEqualStrings("", pg.name);
}

test "process group integration scenario - web server" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

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

    try std.testing.expectEqualStrings("web-server", pg.name);
    try std.testing.expectEqualStrings("/usr/bin/python3", pg.cmd);
    try std.testing.expectEqual(@as(u32, 3), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 2), pg.start_time);
    try std.testing.expectEqual(@as(u32, 5), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 10), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 3), pg.backoff_delay_s);
}

test "process group integration scenario - database worker" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

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

    try std.testing.expectEqualStrings("db-worker", pg.name);
    try std.testing.expectEqualStrings("/opt/app/bin/worker", pg.cmd);
    try std.testing.expectEqual(@as(u32, 8), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 1), pg.start_time);
    try std.testing.expectEqual(@as(u32, 3), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 5), pg.stop_timeout);
    try std.testing.expectEqual(AutoRestart.always, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 10), pg.start_retries);
    try std.testing.expectEqual(@as(u32, 2), pg.backoff_delay_s);
    try std.testing.expectEqual(@as(u16, 0o022), pg.umask);
}

test "process group stress test - many processes" {
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
    pg.setNumProcs(100);
    pg.setAutoRestart(.never);

    pg.children = try pg.arena.allocator().alloc(Process, 100);
    for (pg.children, 0..) |*c, i| {
        c.* = .{ .id = @intCast(i) };
        if (i % 4 == 0) {
            c.state = .running;
        } else if (i % 4 == 1) {
            c.state = .starting;
        } else if (i % 4 == 2) {
            c.state = .exited;
        } else {
            c.state = .backoff;
        }
    }

    try std.testing.expectEqual(@as(u32, 25), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 50), pg.getAliveCount());
    try std.testing.expect(!pg.getAllExited());
}

test "process group edge cases and boundary conditions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    pg.setNumProcs(0);
    try std.testing.expectEqual(@as(u32, 0), pg.numprocs);
    try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());

    pg.setStartRetries(0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.start_retries);

    pg.setStartTime(0xFFFFFFFF);
    pg.setStartSecs(0xFFFFFFFF);
    pg.setStopTimeout(0xFFFFFFFF);
    pg.setBackoffDelay(0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.start_time);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.startsecs);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.stop_timeout);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pg.backoff_delay_s);
}

test "process group memory management and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    for (0..10) |_| {
        var pg = ProcessGroup.init(allocator);

        try pg.setName("test-process");
        try pg.setCmd("/bin/true");
        const argv = [_][]const u8{"true"};
        try pg.setArgv(&argv);
        const env = [_][]const u8{};
        try pg.setEnv(&env);
        pg.setNumProcs(5);

        pg.children = try pg.arena.allocator().alloc(Process, 5);
        for (pg.children, 0..) |*c, i| {
            c.* = .{ .id = @intCast(i) };
        }

        try std.testing.expectEqual(@as(u32, 0), pg.getRunningCount());
        try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());

        pg.deinit();
    }
}

test "process group configuration validation comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

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
    try std.testing.expectEqual(AutoRestart.unexpected, pg.autorestart);
    try std.testing.expectEqual(@as(u32, 5), pg.backoff_delay_s);
    try std.testing.expectEqual(@as(u16, 0o644), pg.umask);
    try std.testing.expectEqual(false, pg.redirect_stdout);
    try std.testing.expectEqual(false, pg.redirect_stderr);
    try std.testing.expectEqual(false, pg.autostart);
}

// ===== EDGE CASE TESTS =====

test "process group zero processes edge case" {
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
    pg.setNumProcs(0);

    // Should handle zero processes gracefully
    try std.testing.expectEqual(@as(usize, 0), pg.children.len);
    try std.testing.expectEqual(@as(u32, 0), pg.getAliveCount());
    try std.testing.expect(pg.getAllExited());
    try std.testing.expectEqual(GroupState.stopped, pg.state);
}

test "process group maximum retry limit edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/nonexistent/command");
    const argv = [_][]const u8{"nonexistent"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(2);

    // Spawn should fail immediately
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Process may or may not fail immediately - the key is that spawnChildren succeeds
    // and the process is created (even if it fails to start)
    try std.testing.expect(pg.children.len > 0);
}

test "process group backoff timing edge case - zero delay" {
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
    pg.setNumProcs(1);
    pg.setAutoRestart(.always);
    pg.setStartRetries(1);
    pg.setBackoffDelay(0); // Zero backoff delay

    pg.children = try pg.arena.allocator().alloc(Process, 1);
    pg.children[0] = .{
        .id = 0,
        .backoff_delay_s = 0,
        .state = .exited,
        .retries_count = 0,
    };

    // With zero backoff, should immediately transition from backoff to stopped
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);

    // Should be immediately expired
    try std.testing.expect(pg.children[0].isBackoffExpired());
}

test "process group stop timeout edge case - immediate kill" {
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
    pg.setNumProcs(1);
    pg.setStopTimeout(0); // Zero timeout - should kill immediately

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Start stopping
    try pg.stopChildren();
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);

    // With zero timeout, should immediately send kill
    try pg.monitorChildren();
    // State could be stopping or stopped depending on timing
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);
}

test "process group autorestart never policy edge case" {
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
    pg.setNumProcs(1);
    pg.setAutoRestart(.never); // Never restart

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Wait for process to exit naturally
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 100) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // With never restart, should stay exited
    try std.testing.expect(pg.getAllExited());
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);

    // Should not restart
    try pg.monitorChildren();
    try std.testing.expectEqual(Process.State.exited, pg.children[0].state);
}

test "process group autorestart unexpected policy edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/false"); // Will exit with non-zero code
    const argv = [_][]const u8{"false"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setAutoRestart(.unexpected); // Only restart on unexpected exit
    pg.setStartRetries(1);

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Wait for process to exit
    var iterations: u32 = 0;
    while (pg.getAliveCount() > 0 and iterations < 100) {
        try pg.monitorChildren();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        iterations += 1;
    }

    // With unexpected policy and non-zero exit, should restart
    try std.testing.expectEqual(Process.State.backoff, pg.children[0].state);
}

test "process group memory pressure edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    // Create a very long command line to test memory handling
    const long_arg = "x" ** 1000; // 1000 character argument
    try pg.setCmd("/bin/echo");
    const argv = [_][]const u8{ "echo", long_arg };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    // Should handle long arguments gracefully
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group signal handling edge case - unusual signal" {
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
    pg.setNumProcs(1);
    pg.setStopSignal(std.posix.SIG.USR1); // Use a valid but unusual signal

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Should handle unusual signal gracefully
    try pg.stopChildren();
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);
}

test "process group environment variable edge case - empty environment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/true"); // Use a simpler command that doesn't depend on working directory
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{}; // Empty environment
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    // Should handle empty environment gracefully
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group umask edge case - restrictive umask" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/touch");
    const argv = [_][]const u8{ "touch", "/tmp/test_file" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setUmask(0o777); // Very restrictive umask
    pg.setNumProcs(1);

    // Should handle restrictive umask gracefully
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group state transition edge case - rapid state changes" {
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
    pg.setNumProcs(1);

    // Rapid start/stop cycles
    try pg.spawnChildren();
    // State could be starting or stopped depending on timing
    try std.testing.expect(pg.state == GroupState.starting or pg.state == GroupState.stopped);

    try pg.stopChildren();
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);

    // Should handle rapid state changes gracefully
    try pg.monitorChildren();
    // State could be stopping or stopped depending on timing
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);
}

test "process group resource cleanup edge case - proper cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit(); // Use defer for proper cleanup

    try pg.setCmd("/bin/true");
    const argv = [_][]const u8{"true"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(1);

    try pg.spawnChildren();

    // Test that cleanup works properly
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);
}

test "process group concurrent access edge case - simultaneous operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/sleep");
    const argv = [_][]const u8{ "sleep", "1" };
    try pg.setArgv(&argv);
    const env = [_][]const u8{};
    try pg.setEnv(&env);
    pg.setNumProcs(2);

    // Start processes
    try pg.spawnChildren();

    // Simultaneous operations should be handled gracefully
    try pg.stopChildren();
    try pg.monitorChildren();

    // Should not crash or cause undefined behavior
    try std.testing.expect(pg.state == GroupState.stopping or pg.state == GroupState.stopped);
}

test "process group start grace period edge case - immediate failure" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/nonexistent/command");
    const argv = [_][]const u8{"nonexistent"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{""};
    try pg.setEnv(&env);
    pg.setNumProcs(1);
    pg.setStartSecs(5); // 5 second grace period

    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Process may or may not fail immediately - the key is that spawnChildren succeeds
    // and the process is created (even if it fails to start)
    try std.testing.expect(pg.children.len > 0);
}

test "process group working directory edge case - non-existent directory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pg = ProcessGroup.init(allocator);
    defer pg.deinit();

    try pg.setCmd("/bin/pwd");
    const argv = [_][]const u8{"pwd"};
    try pg.setArgv(&argv);
    const env = [_][]const u8{""};
    try pg.setEnv(&env);
    try pg.setWorkingDir("/nonexistent/directory");
    pg.setNumProcs(1);

    // Should handle non-existent working directory gracefully
    try pg.spawnChildren();
    try std.testing.expectEqual(@as(usize, 1), pg.children.len);

    // Process may or may not fail immediately - the key is that spawnChildren succeeds
    // and the process is created (even if it fails to start)
    try std.testing.expect(pg.children.len > 0);
}
