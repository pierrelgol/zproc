const std = @import("std");
const posix = std.posix;
pub const Process = @This();

pub const ProcessParams = struct {
    stdout_path: ?[:0]const u8 = null,
    stderr_path: ?[:0]const u8 = null,
    redirect_stdout: bool = true,
    redirect_stderr: bool = true,
    working_directory: ?[:0]const u8 = null,
    umask: ?u16 = null,
    path: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
};

pid: ?posix.pid_t = null,
state: State = .stopped,
start_time_ns: u64 = 0,
stop_deadline_ns: u64 = 0,
exit_code: ?u8 = null,
exit_signal: ?u8 = null,
failed_start: bool = false,
sent_kill: bool = false,
retries_count: u32 = 0,
id: u32 = 0,
start_gate_s: u32 = 1,
start_gate_started_ns: u64 = 0,
startsecs: u32 = 1,
successfully_started_ns: u64 = 0,

pub fn start(self: *Process, exec: ProcessParams) !void {
    if (self.state != .stopped) {
        return error.InvalidState;
    }

    self.exit_code = null;
    self.exit_signal = null;
    self.failed_start = false;
    self.sent_kill = false;

    const pid = try posix.fork();
    if (pid == 0) {
        posix.setpgid(0, 0) catch {};

        if (exec.umask) |m| {
            _ = std.c.umask(m);
        }

        if (exec.working_directory) |wd| {
            try posix.chdirZ(wd);
        }

        const stdin_fd = try std.fs.cwd().openFileZ("/dev/null", .{ .mode = .read_only });
        defer stdin_fd.close();
        try posix.dup2(stdin_fd.handle, posix.STDIN_FILENO);

        if (exec.redirect_stdout) {
            if (exec.stdout_path) |path| {
                const dirname = std.fs.path.dirname(path) orelse ".";
                std.fs.cwd().makePath(dirname) catch {};

                const fd = try std.fs.cwd().createFileZ(path, .{ .read = false, .truncate = false, .mode = 0o644 });
                defer fd.close();
                try posix.dup2(fd.handle, posix.STDOUT_FILENO);
            } else {
                const fd = try std.fs.cwd().openFileZ("/dev/null", .{ .mode = .write_only });
                defer fd.close();
                try posix.dup2(fd.handle, posix.STDOUT_FILENO);
            }
        }

        if (exec.redirect_stderr) {
            if (exec.stderr_path) |path| {
                const dirname = std.fs.path.dirname(path) orelse ".";
                std.fs.cwd().makePath(dirname) catch {};

                const fd = try std.fs.cwd().createFileZ(path, .{ .read = false, .truncate = false, .mode = 0o644 });
                defer fd.close();
                try posix.dup2(fd.handle, posix.STDERR_FILENO);
            } else {
                const fd = try std.fs.cwd().openFileZ("/dev/null", .{ .mode = .write_only });
                defer fd.close();
                try posix.dup2(fd.handle, posix.STDERR_FILENO);
            }
        }

        posix.execveZ(exec.path, exec.argv, exec.envp) catch {
            std.posix.exit(1);
        };
    } else {
        self.pid = pid;
        self.state = .starting;
        self.start_time_ns = @truncate(@abs(std.time.nanoTimestamp()));
        self.start_gate_started_ns = self.start_time_ns;
    }
}

pub fn stop(self: *Process, sig: u8, timeout_s: u32) !void {
    if (self.state != .running and self.state != .starting) {
        return error.InvalidState;
    }

    if (self.pid) |p| {
        posix.kill(p, sig) catch |err| switch (err) {
            error.ProcessNotFound => {
                posix.kill(-p, sig) catch {};
            },
            else => return err,
        };
        self.state = .stopping;
        self.stop_deadline_ns = @as(u64, @truncate(@abs(std.time.nanoTimestamp()))) + timeout_s * std.time.ns_per_s;
    }
}

pub fn sendSignal(self: *Process, signal: u8) !void {
    if (self.state != .running) {
        return error.InvalidState;
    }

    if (self.pid) |p| {
        posix.kill(p, signal) catch |err| switch (err) {
            error.ProcessNotFound => {
                posix.kill(-p, signal) catch {};
            },
            else => return err,
        };
    }
}

pub fn kill(self: *Process) !void {
    if (self.state == .exited or self.state == .killed) {
        return error.InvalidState;
    }

    if (self.pid) |p| {
        posix.kill(p, posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {
                posix.kill(-p, posix.SIG.KILL) catch {};
            },
            else => return err,
        };
        self.state = .killed;
    }
}

pub fn monitor(self: *Process) !void {
    const now_ns = @as(u64, @truncate(@abs(std.time.nanoTimestamp())));

    if (self.state == .starting) {
        if (self.pid) |p| {
            posix.kill(p, 0) catch |err| switch (err) {
                error.ProcessNotFound => {
                    self.failed_start = true;
                    self.state = .exited;
                    self.pid = null;
                    return;
                },
                else => return err,
            };
        }

        const start_gate_ns = self.start_gate_s * std.time.ns_per_s;
        if (now_ns - self.start_gate_started_ns >= start_gate_ns) {
            self.state = .running;
            self.successfully_started_ns = now_ns;
        }
    }

    if (self.state == .running and self.successfully_started_ns > 0) {
        const startsecs_ns = self.startsecs * std.time.ns_per_s;
        if (now_ns - self.successfully_started_ns >= startsecs_ns) {}
    }

    if (self.state == .stopping and now_ns >= self.stop_deadline_ns and !self.sent_kill) {
        try self.kill();
        self.sent_kill = true;
    }

    if (self.pid) |p| {
        const result = posix.waitpid(p, posix.W.NOHANG);
        if (result.pid != 0) {
            const status = result.status;
            if (posix.W.IFEXITED(status)) {
                self.exit_code = posix.W.EXITSTATUS(status);
            } else if (posix.W.IFSIGNALED(status)) {
                self.exit_signal = @as(u8, @intCast(posix.W.TERMSIG(status)));
            }

            if (self.state == .starting) {
                self.failed_start = true;
            }

            self.state = .exited;
            self.pid = null;
        }
    }
}

pub fn isAlive(self: *const Process) bool {
    return self.state == .running or self.state == .starting or self.state == .stopping;
}

pub fn isRunning(self: *const Process) bool {
    return self.state == .running;
}

pub fn hasExited(self: *const Process) bool {
    return self.state == .exited or self.state == .killed;
}

pub fn getExitCode(self: *const Process) ?u8 {
    return self.exit_code;
}

pub fn getExitSignal(self: *const Process) ?u8 {
    return self.exit_signal;
}

pub fn reset(self: *Process) void {
    self.pid = null;
    self.state = .stopped;
    self.start_time_ns = 0;
    self.stop_deadline_ns = 0;
    self.exit_code = null;
    self.exit_signal = null;
    self.failed_start = false;
    self.sent_kill = false;
    self.start_gate_started_ns = 0;
    self.successfully_started_ns = 0;
}

pub const State = enum(u8) {
    none,
    stopped,
    starting,
    running,
    stopping,
    exited,
    killed,
};

test "process start gate timing" {
    var process = Process{ .start_gate_s = 1 };
    const start_time = std.time.nanoTimestamp();
    process.start_time_ns = @truncate(@abs(start_time));
    process.start_gate_started_ns = process.start_time_ns;
    process.state = .starting;
    process.pid = 12345;

    try std.testing.expectEqual(Process.State.starting, process.state);

    std.time.sleep(100 * std.time.ns_per_ms);
    try process.monitor();
    try std.testing.expectEqual(Process.State.starting, process.state);

    std.time.sleep(1100 * std.time.ns_per_ms);
    try process.monitor();
    try std.testing.expectEqual(Process.State.running, process.state);
}

test "process state transitions" {
    var process = Process{};

    try std.testing.expectEqual(Process.State.stopped, process.state);

    process.state = .starting;
    try std.testing.expectEqual(Process.State.starting, process.state);

    process.state = .running;
    try std.testing.expectEqual(Process.State.running, process.state);

    process.state = .stopping;
    try std.testing.expectEqual(Process.State.stopping, process.state);

    process.state = .exited;
    try std.testing.expectEqual(Process.State.exited, process.state);
}

test "process retry counting" {
    var process = Process{};

    try std.testing.expectEqual(@as(u32, 0), process.retries_count);

    process.retries_count += 1;
    try std.testing.expectEqual(@as(u32, 1), process.retries_count);

    process.retries_count = 0;
    try std.testing.expectEqual(@as(u32, 0), process.retries_count);
}

test "process utility functions" {
    var process = Process{};

    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(!process.hasExited());
    try std.testing.expect(process.getExitCode() == null);
    try std.testing.expect(process.getExitSignal() == null);

    process.state = .running;
    try std.testing.expect(process.isAlive());
    try std.testing.expect(process.isRunning());
    try std.testing.expect(!process.hasExited());

    process.state = .exited;
    process.exit_code = 42;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 42), process.getExitCode().?);

    process.state = .killed;
    process.exit_signal = 9;
    try std.testing.expect(!process.isAlive());
    try std.testing.expect(!process.isRunning());
    try std.testing.expect(process.hasExited());
    try std.testing.expectEqual(@as(u8, 9), process.getExitSignal().?);
}

test "process reset function" {
    var process = Process{};

    process.pid = 12345;
    process.state = .running;
    process.exit_code = 1;
    process.exit_signal = 9;
    process.failed_start = true;
    process.sent_kill = true;

    process.reset();

    try std.testing.expect(process.pid == null);
    try std.testing.expectEqual(Process.State.stopped, process.state);
    try std.testing.expect(process.exit_code == null);
    try std.testing.expect(process.exit_signal == null);
    try std.testing.expect(!process.failed_start);
    try std.testing.expect(!process.sent_kill);
}

test "process state validation" {
    var process = Process{};

    process.state = .running;
    try std.testing.expectError(error.InvalidState, process.start(.{
        .path = "/bin/true",
        .argv = &[_]?[*:0]const u8{null},
        .envp = &[_]?[*:0]const u8{null},
    }));

    process.state = .stopped;
    try std.testing.expectError(error.InvalidState, process.stop(std.posix.SIG.TERM, 5));

    process.state = .stopped;
    try std.testing.expectError(error.InvalidState, process.sendSignal(std.posix.SIG.USR1));

    process.state = .exited;
    try std.testing.expectError(error.InvalidState, process.kill());
}
