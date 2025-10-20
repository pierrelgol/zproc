const std = @import("std");

pub const Process = @import("process/Process.zig").Process;
pub const ProcessGroup = @import("process/ProcessGroup.zig").ProcessGroup;
pub const utils = @import("process/utils.zig");

comptime {
    std.testing.refAllDecls(Process);
    std.testing.refAllDecls(ProcessGroup);
    std.testing.refAllDecls(utils);
}
