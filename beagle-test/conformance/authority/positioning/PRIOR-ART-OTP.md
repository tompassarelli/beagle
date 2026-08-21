# PRIOR ART — Erlang/OTP: live upgrades on trust

## License and source boundary

Prior-art source inspected: `~/code/resources/otp`, commit
`5d651b992aa1568d63ca6ce8c5aacecb1ecd09d9` (2026-08-12). Erlang/OTP is
licensed under the Apache License 2.0; the repository's governing text is
`~/code/resources/otp/LICENSE.txt`, and the inspected documentation carries
the corresponding Apache-2.0 notices. This note is an independent technical
analysis and copies no OTP source. Any future copied expression or derivative
implementation must preserve the applicable Apache-2.0 notices and license
text.

## Position

OTP is the ancestor of live engine promotion: put a new implementation beside
the running one, move live processes across a controlled boundary, and keep the
service alive while the change happens. It has made that operational pattern
credible for decades.

The important distinction for Beagle is that OTP proves a protocol was
executed, not that the new engine is semantically equivalent to the old one.
The operator supplies the `.appup`/`.relup` plan, state-migration callback,
dependency order, process inventory, and purge policy. OTP then suspends,
loads, transforms, resumes, restarts, or kills according to that plan. A
successful install is therefore a trusted transition report. Beagle Stage 5
can make the transition an admission decision: shadow parity, expected-head
CAS, a tick-boundary commit, and a reverse-promotion receipt.

## What OTP actually does

### Code server and the two-version rule

The code server holds at most two live instances of a module: `current` and
`old`. Loading a replacement makes the previous current version old. Both may
execute concurrently, but fully qualified calls resolve to current code; a
process already executing old code remains there until it makes a fully
qualified call back into the module. Loading a third instance purges old code
and terminates processes still lingering in it.

This is a sharp operational discipline, not a proof of compatibility. The
boundary is module-level, and the system tolerates a mixed-generation interval
by design. A normal loop can switch explicitly with a call such as `m:loop/0`.
Anonymous funs and process-local continuations therefore need care: a process
can carry old execution state while the export table points at the new code.

The code API exposes both policies:

- `code:soft_purge/1` refuses to remove old code while a process directly
  references it;
- `code:purge/1` removes old code and kills processes that still linger there;
- `code:delete/1` makes current code old without installing a replacement.

The two-version rule bounds the runtime's code generations. It does not bound
semantic drift, state-format drift, messages already in queues, external data,
or processes that were not included in the upgrade plan.

### `code_change` and synchronized replacement

An `.appup` file describes an application's upgrade and downgrade instructions.
`systools` combines those instructions with release metadata into a `.relup`
script. A high-level `update` normally:

1. discovers processes using a module by walking application supervision trees
   and reading each child specification's `Modules` field;
2. suspends those processes with `sys:suspend`;
3. loads the new module in the dependency order encoded by `relup`;
4. for an advanced update, invokes the behavior's `code_change/3` (or a
   special process's `system_code_change/4`) with the old version and
   operator-supplied `Extra`;
5. resumes the processes; and
6. soft-purges or brutally purges the old version according to the script.

`gen_server:code_change/3` is the migration hook for internal state. It returns
`{ok, NewState}` or `{error, Reason}`. The callback receives the old module
version, including `{down, Vsn}` for a downgrade, so one callback can support
both directions. A supervisor update is a separate instruction: its new
`init/1` result changes restart properties or existing child specifications;
adding and deleting children must be specified explicitly.

This is a useful separation of concerns: code loading, process quiescence,
state migration, dependency order, and process resumption are named steps. It
is not transactional state semantics. The callback is trusted code, `Extra` is
trusted input, and an apparently successful callback is not a parity result.

### `release_handler`, `appup`, and `relup`

Offline, `.appup` files are the application-local upgrade language and
`systools:make_relup` lowers them to a release-wide `.relup`. Online,
`release_handler` unpacks the release and evaluates the low-level script. The
script can add, load, update, delete, or purge modules; start, stop, or restart
applications; synchronize nodes; and request a runtime restart.

The script has a literal `point_of_no_return`. After it, a crash cannot recover
the in-memory transition; the system is restarted from the old release. If the
installation fails, OTP's documented escape is to start the old release again
and leave it as the effective release. If installation succeeds, the new
release becomes the default for the next restart. This is release selection and
process recovery, not an inverse of the state migration that already ran.

The release handler also knows the practical limits of its process inventory:
dynamic modules such as `gen_event` must report their installed handlers, and
the child-spec `Modules` lists must accurately describe residence and callback
modules. Distributed upgrades are local to each node; `sync_nodes` is an
explicit barrier, not a global atomic commit.

### Supervision trees and let-it-crash

A supervisor owns child specifications, starts children in declaration order,
terminates them in reverse order, monitors them, and applies a restart policy.
The useful shapes are:

- `one_for_one`: restart only the failed child;
- `rest_for_one`: restart the failed child and later siblings, preserving a
  start-order dependency chain;
- `one_for_all`: tear down and restart the whole peer group when one member
  fails; and
- nested supervisors: make the failure domain and restart ownership explicit.

Each child also declares `permanent`, `transient`, or `temporary` restart
semantics. A restart intensity and period cap an endless crash loop. Once the
limit is exceeded, the supervisor terminates its children and itself, handing
the failure to its parent. This is the operational meaning of “let it crash”:
local state is disposable, the supervisor recreates it from its start
specification, and repeated failure escalates instead of spinning forever.

The model is excellent for containment and recovery. It does not say that a
restarted child has recovered the same logical state, that a new engine agrees
with its predecessor, or that a durable branch head was not concurrently
advanced by somebody else.

## How OTP fails in practice

These are failure classes documented by OTP's own reference, design, and
implementation material. They are precisely the cases where a receipt would
turn an operator's trust claim into an inspectable fact.

### 1. State migration can be absent, wrong, or non-invertible

An advanced update calls `code_change/3`; if the callback is missing, the call
can crash with `undef`. If it raises, returns a malformed result, or returns
`{error, Reason}`, the upgrade fails. Even a `{ok, State}` result only says the
callback accepted the term. It does not show that all queued messages,
external records, or sibling processes interpret the state under the same
semantic contract. A downgrade callback is a second trusted migration, not a
mathematical reverse of the first one.

### 2. Process discovery can be incomplete

The release handler decides which processes use a module from supervision-tree
child specifications, with a special reporting path for dynamic event
handlers. An omitted or inaccurate `Modules` entry means a process may not be
suspended or migrated. The process can continue executing old code while the
new release is installed. OTP documents this as a reason release handling can
be complicated, not as a condition proved by the VM.

### 3. Old code can block a soft purge, or a brutal purge can kill work

If a process still directly references old code, `soft_purge` returns false;
the release handler can report `{error, {old_processes, Mod}}` rather than
claiming a clean transition. With `brutal_purge`, old-code processes are
killed. The low-level handler comments make the trade explicit: a soft purge
refuses the new release in this case, while a brutal purge kills the old
processes. Neither policy proves that the lost process state was semantically
recovered.

### 4. Mixed generations and dependency order create runtime errors

Non-affected processes continue normal execution during an upgrade. New
processes can also start in the interval between suspension and module load and
therefore run old code. If a new `m1` calls a function added to `ch3` before
`ch3` is loaded, the call can fail. `.appup` dependency lists encode the
required order; circular dependencies can make a safe order difficult or
impossible. Cross-module and cross-node communication therefore remains a
mixed-version compatibility obligation.

### 5. Suspension and interrogation are live liveness hazards

System calls have timeouts. A process that does not respond to suspend or code
change can make the instruction fail or remain in the handler's exceptional
path. OTP's implementation notes that an unresponsive process may be left for
later killing during purge because killing it immediately could cause its
supervisor to restart it in the middle of the transition.

The handler must also interrogate supervision trees. OTP documents failures
when `which_children` is attempted against a suspended supervisor or when a
child-spec process cannot answer `get_modules`; these cases are logged and can
abort the operation, with a runtime restart to the old release as the recovery
path. This is a liveness and inventory problem, not just a code-loading error.

### 6. Release failure has a recovery boundary, not atomic rollback

Before `point_of_no_return`, a script can report an error. After it, a crash
means the running node is restarted from the old release. That is a powerful
availability story, but it is not an atomic undo of every callback, message,
side effect, application start, or external write performed before the crash.
The old release is selected on restart; the world outside the BEAM is not
rewound by that selection.

### 7. Supervision can contain failure or amplify it

`one_for_all` deliberately kills healthy siblings to restore a shared
invariant; `rest_for_one` deliberately kills later siblings. A bad start
specification can make every restart fail. A child that repeatedly crashes can
hit restart intensity and take down its supervisor, then its parent. “Let it
crash” gives a bounded, observable escalation path; it does not prevent a bad
candidate from repeatedly reappearing or prove that the replacement preserves
the logical service.

### 8. Distributed release handling is staged, not globally atomic

Each node runs its own release handler. `sync_nodes` waits for named nodes to
reach a script point, but node versions can differ during the rollout and
networked messages cross that boundary. A barrier proves arrival at a script
line, not parity of behavior or a single durable commit across nodes.

## What to steal for Beagle

- **Supervision as a failure-domain graph.** Use nested supervisors or their
  equivalent to make ownership, restart scope, dependency order, and escalation
  explicit. `one_for_one`, `rest_for_one`, and `one_for_all` are good named
  shapes for engine workers, coupled caches, and shared protocol state.

- **Two-version discipline.** Permit at most one candidate and one current
  engine in the live runtime. Make the promotion boundary explicit and reject a
  third live generation. A tick-boundary call into the new engine is Beagle's
  analogue of OTP's fully qualified call into current code.

- **A narrow migration callback.** Give an engine/schema migration an explicit
  old version, new version, and bounded migration payload. Require a structured
  success or failure result. Treat the callback as a migration step to be
  checked, not as evidence that migration was correct.

- **Restart semantics as a policy, not an accident.** Classify workers as
  always-restart, restart-on-abnormal-failure, or never-restart. Bound restart
  intensity and escalate to a larger failure domain when a candidate keeps
  crashing.

- **Offline upgrade plans.** Compile application-level change declarations
  into an ordered release plan with dependency edges, explicit quiescence,
  migration, resume, and purge steps. Reject cycles or require a deliberately
  staged compatibility plan.

- **Named barriers and failure reports.** OTP's `sync_nodes`, suspend, and
  resume vocabulary is useful, provided every barrier emits an owned receipt
  and every timeout preserves the failed phase and leaves the head unchanged.

## What to refuse

- Do not treat “module loaded,” “callback returned `ok`,” “supervisor restarted,”
  or “release handler returned success” as semantic proof.

- Do not copy OTP's mixed-generation tolerance as Beagle's default. Beagle
  should keep the transition at a tick boundary, shadow the candidate against
  the incumbent, and admit only a parity receipt tied to the expected head.

- Do not make `brutal_purge` the rollback mechanism. Killing an old engine or
  worker is an allowed containment action only after the receipt records what
  was killed, what state was retained, and why promotion remains valid.

- Do not infer the process inventory from an approximate module list. The
  candidate's reachable engine handles, active evaluations, and durable-store
  references must be explicit and checked at admission.

- Do not call release selection after a crash “reverse promotion.” OTP's old
  release fallback restarts an earlier program; Beagle's reverse-promotion
  receipt must prove the live head moved back from the candidate to the known
  incumbent without silently accepting a concurrent head.

- Do not let supervision liveness substitute for semantic correctness. A
  healthy restart tree can repeatedly recreate a wrong engine. The semantic
  gate remains shadow parity plus expected-head CAS.

## First three experiments

1. **Two-version tick-boundary probe.** Run incumbent `E0` and candidate `E1`
   against the same deterministic tick stream. Keep `E0` live while `E1`
   shadows it, then admit `E1` only at a tick boundary after equal outputs and
   equal derived-state digests. Attempt a third engine and an old-continuation
   call during the transition. Acceptance requires: at most two live versions,
   a promotion receipt naming the tick, both engine digests, and the expected
   head; no receipt or head movement on parity failure.

2. **`code_change` analogue with a poisoned migration.** Define one state-format
   migration from `E0` to `E1` and a deliberate failure after partial work.
   Require the migration to be isolated from the durable head until parity and
   CAS pass. Then exercise reverse promotion with a second deliberate failure.
   Acceptance requires forward and reverse receipts, unchanged head on either
   rejection, and a proof that external side effects were not mistaken for
   rollback.

3. **Supervision and race matrix.** Build a small tree with `one_for_one`,
   `rest_for_one`, and `one_for_all` equivalents around engine, cache, and
   protocol workers. Inject candidate crashes before shadow parity, after parity,
   between expected-head read and CAS, and after CAS. Add worker churn at the
   promotion boundary and a concurrent head writer. Acceptance requires bounded
   restart/escalation receipts, exactly one successful head transition, a CAS
   rejection for the race, and a reverse-promotion receipt that names the
   original incumbent rather than merely restarting a process.

## Evidence

Read directly from the Apache-2.0 OTP source at
`~/code/resources/otp` commit `5d651b992aa1568d63ca6ce8c5aacecb1ecd09d9`:

- `system/doc/reference_manual/code_loading.md` and `lib/kernel/src/code.erl`
  for current/old code, the two-version rule, and soft versus brutal purge;
- `system/doc/design_principles/release_handling.md` and
  `system/doc/design_principles/appup_cookbook.md` for the suspend/load/
  `code_change`/resume workflow and upgrade hazards;
- `lib/sasl/doc/references/appup.md` and `relup.md` for instruction semantics,
  dependency ordering, purge policy, `point_of_no_return`, and node
  synchronization;
- `lib/sasl/src/release_handler_1.erl` for process discovery, purge behavior,
  timeout/error paths, and the documented old-process and suspended-supervisor
  cases;
- `system/doc/design_principles/sup_princ.md` and `lib/stdlib/src/supervisor.erl`
  for supervision shapes, restart kinds, and restart-intensity escalation; and
- `lib/stdlib/src/sys.erl` and `lib/stdlib/src/gen_server.erl` for system
  messages, suspend/change/resume, and `code_change/3` result handling.

PRIOR-OTP-DONE
