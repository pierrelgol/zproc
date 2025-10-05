# ZProc Test Suite

This directory contains comprehensive tests for the zproc process management library, covering all the features evaluated in the taskmaster markingsheet.

## Test Structure

The test suite is organized into the following modules:

### 1. Process Lifecycle Tests (`process_lifecycle_tests.zig`)
Tests the core process lifecycle management features:
- Process start and exit
- State transitions (stopped → starting → running → stopping → exited)
- Process monitoring and state validation
- Reset functionality
- Uptime calculation
- Backoff mechanism
- Start gate timing

### 2. Process Signal Tests (`process_signal_tests.zig`)
Tests signal handling and process termination:
- TERM, INT, USR1 signal handling
- Stop with timeout
- Kill process
- Signal to process groups
- Invalid state transitions
- Exit code and signal handling

### 3. Process Output Tests (`process_output_tests.zig`)
Tests output redirection and file handling:
- Stdout redirection
- Stderr redirection
- Both stdout and stderr redirection
- No redirection
- Working directory changes
- Umask setting
- Directory creation
- Append mode

### 4. Process Group Tests (`processgroup_tests.zig`)
Tests process group management features:
- Group initialization and configuration
- Spawn children
- Auto-restart policies (always, never, unexpected)
- Individual child control
- Backoff and retry logic
- State and uptime tracking
- Resource management
- Signal handling
- Comprehensive configuration

### 5. Integration Tests (`integration_tests.zig`)
Tests complete workflows and real-world scenarios:
- Web server process group
- Database worker process group
- Basic process execution workflow
- Process with output redirection workflow
- Process group management workflow
- Error handling workflow
- Signal handling workflow
- Complex GNU utility workflows
- Process group with auto restart workflow
- Process group stop and restart workflow

### 6. Error Handling Tests (`error_handling_tests.zig`)
Tests error conditions and edge cases:
- Invalid process states
- Non-existent commands
- Invalid arguments
- Process group missing configuration
- Invalid child operations
- Working directory errors
- Output file creation errors
- Signal errors
- Process group backoff exhaustion
- Process group fatal processes
- State consistency
- Resource cleanup
- Edge cases

### 7. Performance Tests (`performance_tests.zig`)
Tests performance and scalability:
- Many processes creation
- Process group monitoring efficiency
- Process lifecycle timing
- Signal handling timing
- Process group state queries
- Process group backoff calculations
- Process group monitoring with mixed states
- Process group restart logic
- Process group individual child operations
- Memory allocation patterns

## Running Tests

### Individual Test Files
```bash
# Run specific test file
zig test tests/process_lifecycle_tests.zig

# Run with verbose output
zig test tests/process_lifecycle_tests.zig --verbose
```

### All Tests
```bash
# Run all tests
zig test tests/

# Run with test runner
zig run tests/test_runner.zig
```

### Build and Run
```bash
# Build the project
zig build

# Run tests
zig build test
```

## Test Features Covered

### Process Management Features
- ✅ Process lifecycle (start, stop, kill, monitor)
- ✅ State management (stopped, starting, running, stopping, exited, killed, backoff)
- ✅ Signal handling (TERM, INT, USR1, custom signals)
- ✅ Process monitoring (isAlive, isRunning, hasExited)
- ✅ Exit code/signal handling
- ✅ Retry logic and backoff mechanism
- ✅ Timing controls (start_gate_s, startsecs, backoff_delay_s)
- ✅ Process parameters (stdout/stderr redirection, working directory, umask)

### Process Group Management Features
- ✅ Group management (spawnChildren, stopChildren, monitorChildren)
- ✅ Auto-restart policies (always, never, unexpected)
- ✅ Process coordination (getRunningCount, getAliveCount, getAllExited)
- ✅ Individual process control (stopChild, killChild, restartChild)
- ✅ Configuration management (all setter methods)
- ✅ Resource management (working directory, output redirection, umask)
- ✅ Timing controls (start_time, startsecs, stop_timeout, backoff_delay_s)

### Error Handling and Edge Cases
- ✅ Invalid state transitions
- ✅ Non-existent commands
- ✅ Invalid arguments
- ✅ Missing configuration
- ✅ Resource errors
- ✅ Signal errors
- ✅ Backoff exhaustion
- ✅ Fatal process detection

### Performance and Scalability
- ✅ Many processes creation
- ✅ Efficient monitoring
- ✅ State query performance
- ✅ Memory allocation patterns
- ✅ Signal handling performance

## Test Coverage

The test suite provides comprehensive coverage of all process management features:

1. **Process Lifecycle**: Complete process lifecycle from start to exit
2. **Signal Handling**: All signal types and termination scenarios
3. **Output Management**: All output redirection scenarios
4. **Process Groups**: Complete group management functionality
5. **Error Handling**: All error conditions and edge cases
6. **Integration**: Real-world workflows and scenarios
7. **Performance**: Scalability and performance characteristics

## Test Results

Each test module includes:
- Multiple test cases covering different scenarios
- Error condition testing
- Edge case handling
- Performance measurements
- Real-world workflow validation

The tests are designed to validate that all process management features work correctly according to the taskmaster markingsheet requirements.
