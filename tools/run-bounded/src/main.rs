// run-bounded: give one command a deadline and contain its entire descendant
// tree, so nothing it spawned can outlive the bound.
//
// CLI: run-bounded SECONDS KILL-GRACE -- COMMAND [ARG ...]
// Status: the child's exit status; 128+N when the child died by signal N;
// 124 when the deadline is what ended it; 2 on a supervisor contract failure.
// Progress is one START line and one END/TIMEOUT line on stderr, both prefixed
// `beagle supervisor: ` (bin/beagle-materialize-wasm filters on that prefix).
//
// Containment, not merely timing, is the reason this program exists: coreutils
// `timeout` signals the direct child only, so a grandchild that outlives its
// parent is orphaned and keeps running past the deadline. Two containment
// modes, in preference order:
//
//   1. A private PID namespace. unshare(CLONE_NEWUSER|CLONE_NEWPID) then fork:
//      the forked child is PID 1 of the new namespace, so kill(-1, sig) reaches
//      every process in it and nothing outside it, and the namespace dies with
//      that PID 1. The syscalls are issued directly rather than by re-execing
//      through unshare(1), which is what made the Racket and Python supervisors
//      cost a second interpreter boot per phase.
//   2. When the host forbids unprivileged user namespaces, a dedicated process
//      group plus PR_SET_CHILD_SUBREAPER. The group is not a real boundary --
//      a descendant that calls setsid() leaves it -- but the subreaper contract
//      is: an orphaned descendant is reparented HERE, so /proc names it as a
//      child of this process and the sweep repeats until none remain. This mode
//      never signals PID -1.
//
// Environment:
//   BEAGLE_BOUNDED_COMPLETION_RECEIPT   path written only after the child and
//                                       every adopted descendant are reaped
//   BEAGLE_DEADLINE_SCALE               positive rational deadline multiplier
//   BEAGLE_BOUNDED_FORCE_PROCESS_GROUP  1 forces containment mode 2
//
// The child's stdin is /dev/null. That is the incumbent Racket supervisor's
// observable behaviour -- it hands the child a pipe and closes it immediately,
// so every supervised phase already sees EOF -- and inheriting a terminal
// instead lets a phase that reads stdin stop on SIGTTIN in its background
// process group and then be killed as a deadline breach. stdout and stderr are
// inherited untouched.

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- kernel ABI

type CInt = i32;
type CULong = u64;

const CLONE_NEWUSER: CInt = 0x1000_0000;
const CLONE_NEWPID: CInt = 0x2000_0000;
const PR_SET_PDEATHSIG: CInt = 1;
const PR_SET_CHILD_SUBREAPER: CInt = 36;
const SIG_BLOCK: CInt = 0;
const SIG_SETMASK: CInt = 2;
const WNOHANG: CInt = 1;
const SIGHUP: CInt = 1;
const SIGINT: CInt = 2;
const SIGKILL: CInt = 9;
const SIGTERM: CInt = 15;
const SIGCHLD: CInt = 17;
const EINTR: CInt = 4;
const EAGAIN: CInt = 11;

/// Reported by `wait_for_signal` when the wait was cut short by a signal that
/// is not in the supervised set; real signal numbers are positive.
const WAIT_INTERRUPTED: CInt = -1;

#[repr(C)]
#[derive(Clone, Copy)]
struct SigSet {
    words: [u64; 16],
}

#[repr(C)]
struct TimeSpec {
    tv_sec: i64,
    tv_nsec: i64,
}

// siginfo_t is 128 bytes on every Linux ABI this runs on; only si_signo (the
// leading int) is read, and sigtimedwait returns it directly.
#[repr(C, align(8))]
struct SigInfo {
    bytes: [u8; 128],
}

extern "C" {
    fn unshare(flags: CInt) -> CInt;
    fn fork() -> CInt;
    fn getpid() -> CInt;
    fn geteuid() -> u32;
    fn getegid() -> u32;
    fn kill(pid: CInt, sig: CInt) -> CInt;
    fn waitpid(pid: CInt, status: *mut CInt, options: CInt) -> CInt;
    fn prctl(option: CInt, a: CULong, b: CULong, c: CULong, d: CULong) -> CInt;
    fn sigemptyset(set: *mut SigSet) -> CInt;
    fn sigaddset(set: *mut SigSet, sig: CInt) -> CInt;
    fn sigprocmask(how: CInt, set: *const SigSet, old: *mut SigSet) -> CInt;
    fn sigtimedwait(set: *const SigSet, info: *mut SigInfo, timeout: *const TimeSpec) -> CInt;
    fn __errno_location() -> *mut CInt;
    fn _exit(status: CInt) -> !;
}

fn errno() -> CInt {
    unsafe { *__errno_location() }
}

fn empty_sigset() -> SigSet {
    let mut set = SigSet { words: [0; 16] };
    unsafe { sigemptyset(&mut set) };
    set
}

fn supervised_signals() -> SigSet {
    let mut set = empty_sigset();
    for signal in [SIGCHLD, SIGINT, SIGTERM, SIGHUP] {
        unsafe { sigaddset(&mut set, signal) };
    }
    set
}

// ------------------------------------------------------------------ contract

fn fail(detail: &str) -> ! {
    eprintln!("beagle supervisor: {detail}");
    unsafe { _exit(2) }
}

fn positive_seconds(text: &OsStr, name: &str) -> u64 {
    match text.to_string_lossy().parse::<u64>() {
        Ok(value) if value > 0 => value,
        _ => fail(&format!("{name} must be a positive integer")),
    }
}

/// A malformed scale is a contract failure, never a silent 1: a check whose
/// bound came from a typo is not bounded.
///
/// Returns the multiplier and the operator's own text. The text is what the
/// START line reports, so an exact rational reads back as it was written.
fn deadline_scale() -> (f64, String) {
    let raw = match env::var("BEAGLE_DEADLINE_SCALE") {
        Err(_) => return (1.0, String::from("1")),
        Ok(raw) if raw.is_empty() => return (1.0, String::from("1")),
        Ok(raw) => raw,
    };
    match parse_rational(&raw) {
        Some(value) if value.is_finite() && value > 0.0 => (value, raw),
        _ => fail(&format!(
            "BEAGLE_DEADLINE_SCALE must be a positive rational: {raw}"
        )),
    }
}

/// Accepts what the incumbent Racket supervisor accepts, which is a Racket
/// number: decimals AND exact fractions such as `3/2`. Rejecting a fraction
/// here would turn a valid CI scale into a contract failure.
fn parse_rational(raw: &str) -> Option<f64> {
    let text = raw.trim();
    match text.split_once('/') {
        None => text.parse::<f64>().ok(),
        Some((numerator, denominator)) => {
            let numerator = numerator.trim().parse::<f64>().ok()?;
            let denominator = denominator.trim().parse::<f64>().ok()?;
            (denominator != 0.0).then(|| numerator / denominator)
        }
    }
}

fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn resolve_executable(name: &OsStr) -> Option<PathBuf> {
    let candidate = Path::new(name);
    if name.as_bytes().contains(&b'/') {
        return candidate.is_file().then(|| candidate.to_path_buf());
    }
    env::split_paths(&env::var_os("PATH")?)
        .map(|directory| directory.join(candidate))
        .find(|full| is_executable_file(full))
}

// --------------------------------------------------------------- containment

enum Role {
    /// The forked PID 1 of a private PID namespace: it supervises.
    Namespace,
    /// The process that created the namespace: it relays for its PID 1.
    Relay(CInt),
    /// No namespace available: supervise here, contained by a process group.
    ProcessGroup,
}

/// Enter a private PID namespace and fork its PID 1, or report that the host
/// forbids it. An unprivileged user namespace is what makes the PID namespace
/// reachable without privilege; both are unshared in one call, so a host that
/// refuses either leaves this process untouched and falls back.
fn enter_pid_namespace() -> Role {
    if unsafe { getpid() } == 1 {
        return Role::Namespace;
    }
    if env::var("BEAGLE_BOUNDED_FORCE_PROCESS_GROUP").as_deref() == Ok("1") {
        return Role::ProcessGroup;
    }
    let uid = unsafe { geteuid() };
    let gid = unsafe { getegid() };
    if unsafe { unshare(CLONE_NEWUSER | CLONE_NEWPID) } != 0 {
        return Role::ProcessGroup;
    }
    // Past this point the user namespace exists and cannot be undone, so a
    // failed identity mapping is a contract failure rather than a fallback:
    // continuing would run the command as the overflow uid.
    let _ = fs::write("/proc/self/setgroups", "deny");
    if fs::write("/proc/self/gid_map", format!("{gid} {gid} 1\n")).is_err() {
        fail("could not map the current group into a private namespace");
    }
    if fs::write("/proc/self/uid_map", format!("{uid} {uid} 1\n")).is_err() {
        fail("could not map the current user into a private namespace");
    }
    match unsafe { fork() } {
        -1 => fail("could not fork a private namespace supervisor"),
        0 => {
            // The namespace dies with its PID 1, so tying that PID 1 to this
            // relay is what makes a killed supervisor leave nothing behind.
            unsafe { prctl(PR_SET_PDEATHSIG, SIGKILL as CULong, 0, 0, 0) };
            Role::Namespace
        }
        child => Role::Relay(child),
    }
}

// ------------------------------------------------------------------- signals

struct Tree {
    namespace_mode: bool,
    process_group: CInt,
    own_pid: CInt,
}

impl Tree {
    /// Every process currently reparented to this supervisor. The process
    /// group is not the containment boundary it looks like: a descendant that
    /// calls setsid() leaves the group and a group-scoped kill never reaches
    /// it. The subreaper contract does hold -- an orphan is reparented here --
    /// so /proc names it as a child of this process.
    fn adopted(&self) -> Vec<CInt> {
        let mut children = Vec::new();
        let Ok(entries) = fs::read_dir("/proc") else {
            return children;
        };
        for entry in entries.flatten() {
            let Ok(pid) = entry.file_name().to_string_lossy().parse::<CInt>() else {
                continue;
            };
            if pid != self.own_pid && parent_of(pid) == Some(self.own_pid) {
                children.push(pid);
            }
        }
        children
    }

    fn signal(&self, sig: CInt) {
        if self.namespace_mode {
            // PID -1 addresses every signalable process in this private
            // namespace except this PID 1 supervisor.
            unsafe { kill(-1, sig) };
            return;
        }
        unsafe { kill(-self.process_group, sig) };
        for pid in self.adopted() {
            unsafe { kill(pid, sig) };
        }
    }
}

fn parent_of(pid: CInt) -> Option<CInt> {
    let status = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    status
        .lines()
        .find_map(|line| line.strip_prefix("PPid:"))
        .and_then(|value| value.trim().parse().ok())
}

fn decode_status(raw: CInt) -> CInt {
    let signal = raw & 0x7f;
    if signal == 0 {
        (raw >> 8) & 0xff
    } else {
        // Report a signalled child the way a shell and the incumbent Racket
        // supervisor do.
        128 + signal
    }
}

/// Reap everything reapable without blocking, recording `target`'s status the
/// first time it is seen. Returns whether any child is still alive.
fn reap(target: CInt, outcome: &mut Option<CInt>) -> bool {
    loop {
        let mut raw: CInt = 0;
        let reaped = unsafe { waitpid(-1, &mut raw, WNOHANG) };
        if reaped > 0 {
            if reaped == target && outcome.is_none() {
                *outcome = Some(decode_status(raw));
            }
            continue;
        }
        if reaped == 0 {
            return true;
        }
        if errno() == EINTR {
            continue;
        }
        return false;
    }
}

/// Block until one of the supervised signals arrives or `limit` elapses; the
/// supervisor never spins. Returns the signal number, None on expiry, or
/// WAIT_INTERRUPTED when an unsupervised signal cut the wait short -- the
/// caller retries that against the shrinking remaining time.
fn wait_for_signal(set: &SigSet, limit: Duration) -> Option<CInt> {
    let timeout = TimeSpec {
        tv_sec: limit.as_secs() as i64,
        tv_nsec: limit.subsec_nanos() as i64,
    };
    let mut info = SigInfo { bytes: [0; 128] };
    let result = unsafe { sigtimedwait(set, &mut info, &timeout) };
    if result >= 0 {
        return Some(result);
    }
    match errno() {
        EAGAIN => None,
        EINTR => Some(WAIT_INTERRUPTED),
        code => fail(&format!("sigtimedwait failed with errno {code}")),
    }
}

// --------------------------------------------------------------- supervision

/// SIGTERM the tree, give it exactly the kill grace to disappear, then SIGKILL
/// and keep sweeping: a descendant becomes visible as ours only once its own
/// parent dies, so each round kills what the previous round orphaned into this
/// process.
fn shutdown_tree(
    tree: &Tree,
    set: &SigSet,
    grace: Duration,
    target: CInt,
    outcome: &mut Option<CInt>,
) {
    // Reap before signalling: on the ordinary path the tree is already gone,
    // and the process-group sweep costs a full /proc walk it need not pay.
    if !reap(target, outcome) {
        return;
    }
    tree.signal(SIGTERM);
    let started = Instant::now();
    loop {
        if !reap(target, outcome) {
            return;
        }
        match grace.checked_sub(started.elapsed()) {
            Some(remaining) if !remaining.is_zero() => {
                wait_for_signal(set, remaining);
            }
            _ => break,
        }
    }
    tree.signal(SIGKILL);
    let mut quiet_rounds = 0;
    while quiet_rounds < 100 {
        let before = *outcome;
        let reaped_any = reap(target, outcome);
        if !reaped_any {
            return;
        }
        tree.signal(SIGKILL);
        quiet_rounds = if before == *outcome {
            quiet_rounds + 1
        } else {
            0
        };
        wait_for_signal(set, Duration::from_millis(10));
    }
    fail("descendants remained after SIGKILL");
}

fn supervise(
    namespace_mode: bool,
    executable: PathBuf,
    arguments: Vec<OsString>,
    deadline: Duration,
    grace: Duration,
    label: String,
    receipt: Option<String>,
) -> ! {
    if !namespace_mode && unsafe { prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) } != 0 {
        fail("could not become a child subreaper for process-group fallback");
    }
    let set = supervised_signals();

    let mut command = Command::new(&executable);
    command
        .args(&arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .process_group(0);
    unsafe {
        // The blocked set is inherited across exec, and a build phase that
        // cannot receive SIGTERM cannot be bounded. Restore an empty mask in
        // the child; sigprocmask is async-signal-safe.
        command.pre_exec(|| {
            let empty = empty_sigset();
            sigprocmask(SIG_SETMASK, &empty, std::ptr::null_mut());
            Ok(())
        });
    }
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => fail(&format!("could not start {}: {error}", executable.display())),
    };
    let target = child.id() as CInt;
    // waitpid(-1) below reaps this pid directly; std must never wait on it too.
    std::mem::forget(child);

    let tree = Tree {
        namespace_mode,
        process_group: target,
        own_pid: unsafe { getpid() },
    };

    let started = Instant::now();
    let mut outcome: Option<CInt> = None;
    let mut timed_out = false;
    let mut interrupted: Option<CInt> = None;
    loop {
        let alive = reap(target, &mut outcome);
        if outcome.is_some() || !alive {
            break;
        }
        let remaining = match deadline.checked_sub(started.elapsed()) {
            Some(remaining) if !remaining.is_zero() => remaining,
            _ => {
                timed_out = true;
                break;
            }
        };
        match wait_for_signal(&set, remaining) {
            None => {
                timed_out = true;
                break;
            }
            Some(SIGCHLD) | Some(WAIT_INTERRUPTED) => continue,
            Some(signal) => {
                // Forward what this supervisor was told to do to the tree it
                // owns, rather than dying and orphaning it.
                interrupted = Some(signal);
                break;
            }
        }
    }

    shutdown_tree(&tree, &set, grace, target, &mut outcome);

    let status = if timed_out {
        124
    } else if let Some(signal) = interrupted {
        128 + signal
    } else {
        outcome.unwrap_or(2)
    };
    if let Some(path) = receipt {
        let kind = if timed_out { "timeout" } else { "exit" };
        if fs::write(&path, format!("subtree-reaped-v0 {kind} status={status}\n")).is_err() {
            fail(&format!("could not write the completion receipt: {path}"));
        }
    }
    eprintln!(
        "beagle supervisor: {label} {} status={status}",
        if timed_out { "TIMEOUT" } else { "END" }
    );
    unsafe { _exit(status) }
}

/// Wait for the namespace's PID 1 and wear its status, forwarding any signal
/// this relay receives so the tree is shut down on its own terms rather than
/// losing its supervisor.
fn relay(pid: CInt) -> ! {
    let set = supervised_signals();
    loop {
        let mut raw: CInt = 0;
        let reaped = unsafe { waitpid(pid, &mut raw, WNOHANG) };
        if reaped == pid {
            unsafe { _exit(decode_status(raw)) }
        }
        if reaped < 0 && errno() != EINTR {
            unsafe { _exit(2) }
        }
        // Hour-long waits, not polls: PID 1's death raises SIGCHLD here.
        match wait_for_signal(&set, Duration::from_secs(3600)) {
            Some(signal) if signal > 0 && signal != SIGCHLD => {
                unsafe { kill(pid, signal) };
            }
            _ => {}
        }
    }
}

fn main() {
    let arguments: Vec<OsString> = env::args_os().skip(1).collect();
    if arguments.len() < 4 || arguments[2] != OsStr::new("--") {
        fail("expected SECONDS KILL-GRACE -- COMMAND [ARG ...]");
    }
    let seconds = positive_seconds(&arguments[0], "deadline");
    let grace = positive_seconds(&arguments[1], "kill grace");
    let (scale, scale_text) = deadline_scale();

    // A setup failure must not leave a prior invocation's successful outcome
    // looking current to the caller.
    let receipt = env::var("BEAGLE_BOUNDED_COMPLETION_RECEIPT")
        .ok()
        .filter(|path| !path.is_empty());
    if let Some(path) = &receipt {
        let _ = fs::remove_file(path);
    }

    let Some(executable) = resolve_executable(&arguments[3]) else {
        fail(&format!(
            "command is unavailable: {}",
            arguments[3].to_string_lossy()
        ));
    };
    let label = executable
        .file_name()
        .unwrap_or(executable.as_os_str())
        .to_string_lossy()
        .into_owned();
    let rest: Vec<OsString> = arguments[4..].to_vec();

    // A deadline is a claim that the work TERMINATES, not a claim about how
    // many seconds it deserves, and the second reading breaks when the same
    // work runs on a quarter of the cores. The default is 1, so an unset scale
    // leaves this log line byte-identical, and a scaled run says it is scaled.
    let effective = Duration::from_secs_f64(seconds as f64 * scale);
    let scaled = if scale == 1.0 {
        String::new()
    } else {
        format!(
            " scale={scale_text} effective-deadline={}s",
            seconds as f64 * scale
        )
    };

    // Blocked before the fork so the relay and PID 1 both inherit it; the
    // supervised command clears it again in pre_exec.
    let set = supervised_signals();
    unsafe { sigprocmask(SIG_BLOCK, &set, std::ptr::null_mut()) };

    let role = enter_pid_namespace();
    if let Role::Relay(pid) = role {
        relay(pid);
    }
    eprintln!("beagle supervisor: {label} START deadline={seconds}s{scaled} kill-grace={grace}s");
    supervise(
        matches!(role, Role::Namespace),
        executable,
        rest,
        effective,
        Duration::from_secs(grace),
        label,
        receipt,
    );
}
