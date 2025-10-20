const std = @import("std");

pub fn buildArgv(argv: []const []const u8, allocator: std.mem.Allocator) ![:null]?[*:0]u8 {
    const result = try allocator.allocSentinel(?[*:0]u8, argv.len, null);
    for (argv, 0..) |arg, i| {
        result[i] = try allocator.dupeZ(u8, arg);
    }
    return result;
}

pub fn buildEnvp(env: []const []const u8, allocator: std.mem.Allocator) ![:null]?[*:0]u8 {
    const envp = try allocator.allocSentinel(?[*:0]u8, env.len, null);
    for (env, 0..) |pair, i| {
        envp[i] = try allocator.dupeZ(u8, pair);
    }
    return envp;
}
