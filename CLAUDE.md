## 🧩 Process Management Library — Functional Scope

A standalone library that abstracts the **lifecycle, timing, and policy management** of UNIX processes and process groups.
It provides deterministic primitives to **spawn, monitor, restart, and terminate** groups of processes under defined behavioral constraints.

---

### 1. Core Responsibilities

The library must handle:

1. **Process creation and execution**

   * Spawn new processes via `fork()` + `execve()`
   * Set up execution environment (working dir, umask, envp)
   * Redirect or discard standard streams
   * Support one process or multiple parallel instances (process pool per group)

2. **Process supervision**

   * Track process identifiers (PIDs)
   * Monitor liveness and termination (via waitpid or SIGCHLD)
   * Distinguish between *graceful* and *unexpected* exits
   * Maintain internal state transitions (`starting`, `running`, `stopping`, `exited`, `backoff`, `fatal`)

3. **Controlled termination**

   * Send configurable stop signal (e.g., SIGTERM)
   * Wait a specified delay for graceful exit
   * Force-kill (SIGKILL) on timeout
   * Support stopping single or all processes within a group

4. **Restart and backoff policies**

   * Retry starting a process up to a maximum count
   * Enforce a cooldown (“backoff”) delay between restart attempts
   * Support policy variants:

     * **Always restart**
     * **Restart only on unexpected exit**
     * **Never restart**
   * Mark a process or group as `fatal` once retry limit reached

5. **Timing and uptime accounting**

   * Record start and stop timestamps
   * Compute runtime durations
   * Apply *start grace period* (time required before considering process “successfully started”)
   * Support per-process or per-group timers (for backoff, stop timeout, etc.)

6. **Group orchestration**

   * Maintain a collection of homogeneous processes sharing one command definition
   * Start/stop/restart all processes as a unit
   * Handle partial restarts or replacement of failed instances
   * Ensure that the number of running processes matches the desired target count

7. **State introspection**

   * Expose pure data structures describing:

     * process PID
     * current state
     * retry count
     * uptime
     * exit code
   * Allow external systems (like Taskmaster) to poll or subscribe to changes

8. **Signal integration**

   * Respond to and emit process-level signals
   * Integrate with external event loops or supervisors that manage signal dispatch
   * Provide non-blocking APIs suitable for use inside a poll/select loop

9. **Resource management**

   * Own all allocations for processes and per-group state
   * Provide predictable cleanup (`deinit`), ensuring no zombie processes
   * Use arenas or allocators to support safe live reinitialization by higher layers

10. **Failure resilience**

    * Handle fork/exec errors gracefully
    * Prevent runaway restart loops
    * Detect and mark unmanageable states (e.g., exec repeatedly failing instantly)
    * Never crash on invalid process state transitions

---

### 2. Behavioral Guarantees

The library should guarantee that:

* **Process lifecycle is deterministic** — state transitions are explicit and traceable.
* **No zombie processes** remain after shutdown or reload.
* **Restart logic** respects timing, retry, and backoff semantics.
* **Concurrency is safe** — multiple groups can be managed independently.
* **External layers** (like the Taskmaster supervisor or shell) can drive all behavior through a simple control interface (start/stop/status), without reimplementing process semantics.

---

### 3. Intended Role

This library acts as the **mechanical substrate** for Taskmaster:

* Taskmaster provides *configuration, logging, command handling, and IPC*.
* The library provides *pure process lifecycle management*:

  * spawning
  * supervision
  * timing
  * retry/backoff
  * graceful shutdown
  * state reporting

It must remain **policy-agnostic** (no parsing, no config file awareness, no logging), yet complete enough that Taskmaster can compose it into a full supervisor.

---

### 4. Summary of Functional Capabilities

| Domain                | Responsibilities                                         |
| --------------------- | -------------------------------------------------------- |
| **Lifecycle control** | Start, stop, restart processes and groups                |
| **Supervision**       | Track PID, state, exit codes, liveness                   |
| **Timing**            | Start grace, stop timeout, uptime tracking               |
| **Recovery**          | Retry limits, backoff, fatal states                      |
| **Coordination**      | Maintain desired number of live instances                |
| **Isolation**         | Working directory, umask, environment setup              |
| **Introspection**     | Expose structured state for external consumers           |
| **Resilience**        | Safe error handling, zombie reaping, predictable cleanup |

