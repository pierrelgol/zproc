const std = @import("std");

pub const Process = @import("process/Process.zig").Process;
pub const ProcessGroup = @import("process/ProcessGroup.zig").ProcessGroup;
pub const utils = @import("process/utils.zig");

// Import test modules
const process_lifecycle_tests = @import("process/tests/process_lifecycle_tests.zig");
const process_signal_tests = @import("process/tests/process_signal_tests.zig");
const process_output_tests = @import("process/tests/process_output_tests.zig");
const processgroup_tests = @import("process/tests/processgroup_tests.zig");
const integration_tests = @import("process/tests/integration_tests.zig");
const error_handling_tests = @import("process/tests/error_handling_tests.zig");

comptime {
    std.testing.refAllDecls(Process);
    std.testing.refAllDecls(ProcessGroup);
    std.testing.refAllDecls(utils);
    std.testing.refAllDecls(process_lifecycle_tests);
    std.testing.refAllDecls(process_signal_tests);
    std.testing.refAllDecls(process_output_tests);
    std.testing.refAllDecls(processgroup_tests);
    std.testing.refAllDecls(integration_tests);
    std.testing.refAllDecls(error_handling_tests);
}
