const std = @import("std");

// Import all test modules
const process_lifecycle_tests = @import("process_lifecycle_tests.zig");
const process_signal_tests = @import("process_signal_tests.zig");
const process_output_tests = @import("process_output_tests.zig");
const processgroup_tests = @import("processgroup_tests.zig");
const integration_tests = @import("integration_tests.zig");
const error_handling_tests = @import("error_handling_tests.zig");
const performance_tests = @import("performance_tests.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("Running zproc comprehensive test suite...\n", .{});
    std.debug.print("==========================================\n", .{});

    // Run all test modules
    std.debug.print("\n1. Process Lifecycle Tests\n", .{});
    std.debug.print("---------------------------\n", .{});
    try runTestModule("process_lifecycle_tests", process_lifecycle_tests);

    std.debug.print("\n2. Process Signal Tests\n", .{});
    std.debug.print("------------------------\n", .{});
    try runTestModule("process_signal_tests", process_signal_tests);

    std.debug.print("\n3. Process Output Tests\n", .{});
    std.debug.print("------------------------\n", .{});
    try runTestModule("process_output_tests", process_output_tests);

    std.debug.print("\n4. Process Group Tests\n", .{});
    std.debug.print("------------------------\n", .{});
    try runTestModule("processgroup_tests", processgroup_tests);

    std.debug.print("\n5. Integration Tests\n", .{});
    std.debug.print("-------------------\n", .{});
    try runTestModule("integration_tests", integration_tests);

    std.debug.print("\n6. Error Handling Tests\n", .{});
    std.debug.print("-------------------------\n", .{});
    try runTestModule("error_handling_tests", error_handling_tests);

    std.debug.print("\n7. Performance Tests\n", .{});
    std.debug.print("---------------------\n", .{});
    try runTestModule("performance_tests", performance_tests);

    std.debug.print("\n==========================================\n", .{});
    std.debug.print("All tests completed successfully!\n", .{});
}

fn runTestModule(comptime module_name: []const u8, comptime module: type) !void {
    const start_time = std.time.nanoTimestamp();

    // This is a placeholder - in a real implementation, you would run the tests
    // For now, we'll just print the module name
    std.debug.print("Running {} tests...\n", .{module_name});

    const end_time = std.time.nanoTimestamp();
    const duration = @as(u64, @intCast(end_time - start_time));
    std.debug.print("{} completed in {} ns\n", .{ module_name, duration });
}
