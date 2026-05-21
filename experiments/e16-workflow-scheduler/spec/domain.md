# E16 — Maintenance Workflow Scheduler

## Framing

This experiment compares **agent repair workflows**, not just languages:

| Track | Language | Toolchain |
|---|---|---|
| Beagle | `#lang beagle/clj` | daemon, beagle-check, beagle-fix, beagle-explain |
| Python | `.py` + type annotations | mypy (forced), pytest |

## Domain: Constrained Maintenance Workflow Scheduler

A facility maintenance scheduler. Workers are assigned to maintenance tasks
subject to hard constraints. The scheduler produces a deterministic assignment
or a structured explanation of why scheduling is impossible.

### Entities

```
Task {
  id:           string
  name:         string
  duration:     int          # minutes
  priority:     int          # 1 = highest
  deadline:     int          # absolute minute from epoch
  capabilities: list<string> # required worker capabilities
  resources:    list<string> # required resource IDs
  depends_on:   list<string> # task IDs that must complete first
  retry_policy: RetryPolicy
}

RetryPolicy {
  max_attempts: int          # 0 = no retry
  backoff:      int          # minutes between retries
}

Worker {
  id:          string
  name:        string
  capabilities: list<string>
  unavailable: list<Window>  # windows when worker cannot work
}

Window {
  start: int                 # inclusive, minutes from epoch
  end:   int                 # exclusive, minutes from epoch
}

Resource {
  id:       string
  name:     string
  capacity: int              # max concurrent users
}

Dependency {
  from_task: string          # must complete before...
  to_task:   string          # ...this task can start
}

Assignment {
  task_id:    string
  worker_id:  string
  start_time: int
  end_time:   int
  attempt:    int            # 1-based
}

ScheduleResult = Ok { assignments: list<Assignment> }
               | Error { failures: list<ScheduleFailure> }

ScheduleFailure {
  task_id: string
  reason:  FailureReason
}

FailureReason = DependencyCycle     { cycle: list<string> }
              | NoCapableWorker     { required: list<string>, available: list<list<string>> }
              | ResourceOverCapacity { resource_id: string, capacity: int, demanded: int }
              | DeadlineMissed      { earliest_start: int, duration: int, deadline: int }
              | WorkerUnavailable   { worker_id: string, windows: list<Window> }
```

### Modules

Each implementation MUST have these logical modules with these exact public APIs.
Internal helpers are free-form.

#### 1. `types` — Entity definitions

All entity structs/records/dataclasses above. Pure data, no logic.

#### 2. `graph` — Dependency analysis

```
build_dependency_graph(tasks: list<Task>) -> DependencyGraph
detect_cycles(graph: DependencyGraph) -> list<list<string>>
topological_order(graph: DependencyGraph) -> list<string> | CycleError
```

- Adjacency list representation
- Cycle detection returns ALL minimal cycles (not just one)
- Topological sort uses stable tie-breaking: sort by (priority ASC, id ASC)
- CycleError includes the cycle path

#### 3. `matcher` — Capability and resource matching

```
capable_workers(task: Task, workers: list<Worker>) -> list<Worker>
available_workers(workers: list<Worker>, start: int, end: int) -> list<Worker>
check_resource_capacity(
    resource: Resource,
    existing: list<Assignment>,
    start: int, end: int
) -> bool
find_eligible_workers(
    task: Task,
    workers: list<Worker>,
    resources: list<Resource>,
    existing: list<Assignment>,
    start: int
) -> list<Worker>
```

- `capable_workers`: worker must have ALL required capabilities
- `available_workers`: worker has no unavailable window overlapping [start, end)
- `check_resource_capacity`: count overlapping assignments, compare to capacity
- `find_eligible_workers`: intersection of capable + available + resource-feasible
- Deterministic ordering: sort eligible workers by (id ASC)

#### 4. `scheduler` — Core scheduling algorithm

```
schedule(
    tasks: list<Task>,
    workers: list<Worker>,
    resources: list<Resource>
) -> ScheduleResult
```

Algorithm:
1. Build dependency graph, detect cycles → return Error if any
2. Get topological order (priority ASC, id ASC tie-breaking)
3. For each task in order:
   a. Compute earliest_start = max(0, max(end_time of dependencies))
   b. Find eligible workers at earliest_start
   c. If no eligible workers, try sliding start forward in 1-minute increments
      up to task deadline (if set) or 1440 minutes (24h) from earliest_start
   d. If still no eligible workers, record failure reason
   e. Assign to first eligible worker (by id ASC)
   f. If task has retry_policy and fails, retry with backoff
4. If any task failed, return Error with all failures
5. Return Ok with assignments

Retry logic:
- On failure (no eligible worker at any time), wait `backoff` minutes from
  the last attempted start and try again
- Max `max_attempts` total attempts (attempt 1 is the first try)
- Each retry attempt slides the window forward

#### 5. `validator` — Constraint verification

```
validate_assignments(
    assignments: list<Assignment>,
    tasks: list<Task>,
    workers: list<Worker>,
    resources: list<Resource>
) -> list<Violation>

Violation {
  assignment: Assignment
  kind: ViolationKind
}

ViolationKind = CapabilityMismatch { missing: list<string> }
              | WindowConflict     { window: Window }
              | ResourceExceeded   { resource_id: string, at_time: int, count: int, capacity: int }
              | DependencyOrder    { dependency_id: string, dep_end: int, task_start: int }
              | DeadlineExceeded   { deadline: int, end_time: int }
              | OverlapViolation   { other_task_id: string }
```

- `validate_assignments` checks ALL constraints post-hoc
- A correct scheduler produces zero violations
- This is the hidden oracle: bugs are detected by validation failures

#### 6. `errors` — Structured error types

Language-idiomatic error types:
- Beagle: `deferror` or union types
- Python: exception hierarchy or dataclass results

### Determinism Contract

Given identical input, all implementations MUST produce identical output:
- Same assignment order (sorted by start_time ASC, task_id ASC)
- Same worker selection (first by id ASC)
- Same failure messages (same cycle paths, same reasons)

### Test Scenarios (Oracle Assertions)

The verification oracle tests these categories:

**Happy path** (~80 assertions):
- Single task, single worker → correct assignment
- Multiple independent tasks → parallel assignment
- Chain of dependencies → sequential assignment
- Priority ordering affects schedule order
- Multiple capable workers → deterministic selection (id ASC)

**Dependency graph** (~50 assertions):
- Linear chain A→B→C
- Diamond dependency A→B, A→C, B→D, C→D
- Simple cycle A→B→A detected
- Complex cycle A→B→C→A detected
- Multiple disjoint cycles detected simultaneously
- Self-dependency detected

**Capability matching** (~40 assertions):
- Worker with exact capabilities matches
- Worker with superset capabilities matches
- Worker missing one capability rejected
- No capable worker → structured error

**Resource constraints** (~40 assertions):
- Single resource, capacity 1, two tasks → sequential
- Single resource, capacity 2, two tasks → parallel OK
- Resource at capacity → task waits
- Multiple resources required simultaneously

**Time windows** (~40 assertions):
- Worker unavailable during task window → next available slot
- Worker unavailable all day → different worker assigned
- Tight deadline + unavailable window → deadline missed error

**Retry logic** (~30 assertions):
- Task fails, retry succeeds after backoff
- Task fails all retries → failure with attempt count
- Backoff pushes past deadline → deadline failure

**Edge cases** (~20 assertions):
- Empty task list → empty assignments
- Task with no dependencies and no deadline → scheduled at t=0
- All workers unavailable → structured error per task
- Zero-duration task
- Task depending on nonexistent task → error

**Total: ~300 assertions**

### Bug Categories for Injection

After golden implementations pass all assertions:

| Category | Count | Examples |
|---|---|---|
| Off-by-one | 4 | Window boundary inclusive/exclusive, retry count |
| Type confusion | 3 | Priority ordering reversed, capacity vs count |
| Missing edge case | 3 | Empty list, self-dependency, zero duration |
| Logic error | 4 | Wrong tie-breaking, wrong overlap check |
| Error handling | 3 | Swallowed error, wrong failure reason, missing cycle |
| Data flow | 3 | Stale reference, wrong field access, dropped assignment |
| **Total** | **20** | |

Pilot: first 5 bugs (1 per category except last), then scale.

### Metrics

Primary (correctness):
- Correct fixes (assertion delta)
- Partial fixes (some assertions fixed, others broken)
- **Wrong fixes** (assertions that were passing now fail)
- Hidden oracle pass rate

Secondary (efficiency):
- Wall-clock time
- Agent turns
- Tool calls (check, explain, fix, test)
- Estimated cost (USD)

Tertiary (workflow quality):
- First diagnostic quality (did initial check find the bug?)
- Repair tool usage (did agent use explain/fix-plan?)
- Fix-then-break rate (introduced regressions during repair)
