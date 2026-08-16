#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700

#include "native_shim.h"

#include <errno.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if !defined(__wasi__)
#include <fcntl.h>
#include <sys/wait.h>
#endif

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "host-context shim fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
}

static void require_text(uint64_t actual, const char *expected,
                         const char *detail) {
  size_t length = strlen(expected);
  if ((native_text_length(actual) != (uint64_t)length) ||
      (memcmp(native_text_bytes(actual), expected, length) != 0)) {
    fail(detail, (int64_t)native_text_length(actual), (int64_t)length);
  }
}

#if defined(__wasi__)

static jmp_buf trap_target;
static uint32_t trapped_code = UINT32_C(0);

static void capture_trap(uint32_t code) {
  trapped_code = code;
  longjmp(trap_target, 1);
}

int main(void) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  native_vec argv = {NULL, INT64_C(0), INT64_C(0), NULL};
  uint64_t hostname = UINT64_C(1);

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  if (native_host_process_exec_replace_v0(&capability, &argv) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI exec refusal", 0, -((int64_t)ENOTSUP));
  }
  if ((native_host_system_hostname_v0(
           &arena, &capability, &hostname) != ENOTSUP) ||
      (hostname != UINT64_C(0))) {
    fail("WASI hostname refusal", 0, ENOTSUP);
  }
  require_text(native_host_system_platform_v0(&capability),
               "wasi", "WASI platform");
  if (native_host_terminal_stdout_tty_v0(&capability)) {
    fail("WASI stdout tty", 1, 0);
  }
  native_set_trap_reporter(capture_trap);
  if (setjmp(trap_target) == 0) {
    (void)native_host_system_platform_v0(NULL);
    fail("WASI invalid platform did not trap", 0, 1);
  }
  if (trapped_code != NATIVE_TRAP_INVALID_ARGUMENT) {
    fail("WASI invalid platform trap", trapped_code,
         NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_arena_destroy(&arena);
  (void)puts("host-context WASI fixture: ok");
  return 0;
}

#else

static uint64_t text(native_arena *arena, const char *source) {
  size_t length = strlen(source);
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != (size_t)0U) {
    memcpy(destination, source, length);
  }
  return result;
}

static native_vec *text_vector(native_arena *arena, const uint64_t *values,
                               int64_t count) {
  native_vec *result = native_vec_new(arena, count, INT64_C(8), INT64_C(8));
  int64_t index;
  for (index = INT64_C(0); index < count; ++index) {
    result = native_vec_push(arena, result, &values[index], INT64_C(8),
                             (size_t)8U);
  }
  return result;
}

static size_t read_all(int descriptor, char *buffer, size_t capacity) {
  size_t length = (size_t)0U;
  while (length + (size_t)1U < capacity) {
    ssize_t amount = read(descriptor, buffer + length,
                          capacity - length - (size_t)1U);
    if (amount > (ssize_t)0) {
      length += (size_t)amount;
    } else if (amount == (ssize_t)0) {
      break;
    } else if (errno != EINTR) {
      fail("read inherited stream", errno, 0);
    }
  }
  buffer[length] = '\0';
  return length;
}

static void write_all(int descriptor, const char *bytes, size_t length) {
  size_t offset = (size_t)0U;
  while (offset < length) {
    ssize_t amount = write(descriptor, bytes + offset, length - offset);
    if (amount > (ssize_t)0) {
      offset += (size_t)amount;
    } else if ((amount < (ssize_t)0) && (errno == EINTR)) {
      continue;
    } else {
      fail("write inherited stdin", errno, 0);
    }
  }
}

static void require_context(native_arena *arena,
                            native_capability *capability) {
  uint64_t actual = UINT64_C(0);
  char expected[1024];
  int32_t status;

  memset(expected, 0, sizeof expected);
  if (gethostname(expected, sizeof expected) != 0) {
    fail("system gethostname", errno, 0);
  }
  status = native_host_system_hostname_v0(arena, capability, &actual);
  if (status != 0) {
    fail("native hostname", status, 0);
  }
  require_text(actual, expected, "native hostname text");
#if defined(__linux__)
  require_text(native_host_system_platform_v0(capability),
               "linux", "native platform");
#elif defined(__APPLE__) && defined(__MACH__)
  require_text(native_host_system_platform_v0(capability),
               "darwin", "native platform");
#else
  require_text(native_host_system_platform_v0(capability),
               "unknown", "native platform");
#endif
  actual = UINT64_C(9);
  if ((native_host_system_hostname_v0(NULL, capability, &actual) != EINVAL) ||
      (actual != UINT64_C(0))) {
    fail("hostname validation", (int64_t)actual, 0);
  }
}

static void require_tty(native_capability *capability) {
  int saved_stdout;
  int redirected[2];
  int master;
  int slave;
  char *slave_name;
  bool redirected_result;
  bool closed_result;
  bool terminal_result;

  saved_stdout = dup(STDOUT_FILENO);
  if ((saved_stdout < 0) || (pipe(redirected) != 0)) {
    fail("prepare stdout fixtures", errno, 0);
  }
  if (dup2(redirected[1], STDOUT_FILENO) != STDOUT_FILENO) {
    fail("redirect stdout", errno, STDOUT_FILENO);
  }
  redirected_result = native_host_terminal_stdout_tty_v0(capability);

  master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0) {
    fail("open PTY master", errno, 0);
  }
  if (master <= STDERR_FILENO) {
    int retained_master = fcntl(master, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (retained_master < 0) {
      fail("retain PTY master above stdio", errno, 0);
    }
    (void)close(master);
    master = retained_master;
  }
  if ((grantpt(master) != 0) || (unlockpt(master) != 0)) {
    fail("prepare PTY", errno, 0);
  }
  slave_name = ptsname(master);
  if (slave_name == NULL) {
    fail("name PTY", errno, 0);
  }
  slave = open(slave_name, O_RDWR | O_NOCTTY);
  if (slave < 0) {
    fail("open PTY", errno, 0);
  }
  if (close(STDOUT_FILENO) != 0) {
    fail("close stdout", errno, 0);
  }
  closed_result = native_host_terminal_stdout_tty_v0(capability);
  if (dup2(slave, STDOUT_FILENO) != STDOUT_FILENO) {
    fail("attach PTY stdout", errno, STDOUT_FILENO);
  }
  terminal_result = native_host_terminal_stdout_tty_v0(capability);
  if (dup2(saved_stdout, STDOUT_FILENO) != STDOUT_FILENO) {
    fail("restore stdout", errno, STDOUT_FILENO);
  }
  (void)close(saved_stdout);
  (void)close(redirected[0]);
  (void)close(redirected[1]);
  (void)close(master);
  (void)close(slave);
  if (redirected_result || closed_result || !terminal_result) {
    fail("stdout TTY states",
         (redirected_result ? 4 : 0) + (closed_result ? 2 : 0) +
             (terminal_result ? 1 : 0),
         1);
  }
}

static void require_exec(native_arena *arena, native_capability *capability,
                         const char *helper_path) {
  char *path_copy = strdup(helper_path);
  char *separator;
  const char *command;
  const char input[] = "stdin-ok\n";
  char stdout_bytes[512];
  char stderr_bytes[128];
  char expected_stdout[512];
  int stdin_pipe[2];
  int stdout_pipe[2];
  int stderr_pipe[2];
  pid_t child;
  pid_t waited;
  int wait_status;
  native_vec empty = {NULL, INT64_C(0), INT64_C(0), NULL};
  uint64_t missing_values[1];

  if (path_copy == NULL) {
    fail("copy helper path", ENOMEM, 0);
  }
  separator = strrchr(path_copy, '/');
  if (separator == NULL) {
    command = path_copy;
    if (setenv("PATH", ".", 1) != 0) {
      fail("set PATH", errno, 0);
    }
  } else {
    *separator = '\0';
    command = separator + 1;
    if (setenv("PATH", path_copy, 1) != 0) {
      fail("set PATH", errno, 0);
    }
  }
  if (setenv("BEAGLE_EXEC_ENV", "inherit-ok", 1) != 0) {
    fail("set inherited environment", errno, 0);
  }
  if ((pipe(stdin_pipe) != 0) || (pipe(stdout_pipe) != 0) ||
      (pipe(stderr_pipe) != 0)) {
    fail("prepare inherited streams", errno, 0);
  }
  child = fork();
  if (child < (pid_t)0) {
    fail("fork exec fixture", errno, 0);
  }
  if (child == (pid_t)0) {
    native_arena child_arena;
    native_capability child_capability = {UINT64_C(1)};
    uint64_t argv_values[2];
    int64_t status;
    if ((dup2(stdin_pipe[0], STDIN_FILENO) != STDIN_FILENO) ||
        (dup2(stdout_pipe[1], STDOUT_FILENO) != STDOUT_FILENO) ||
        (dup2(stderr_pipe[1], STDERR_FILENO) != STDERR_FILENO)) {
      _exit(90);
    }
    (void)close(stdin_pipe[0]);
    (void)close(stdin_pipe[1]);
    (void)close(stdout_pipe[0]);
    (void)close(stdout_pipe[1]);
    (void)close(stderr_pipe[0]);
    (void)close(stderr_pipe[1]);
    if (!native_arena_init_growable(&child_arena, (size_t)4096U)) {
      _exit(91);
    }
    argv_values[0] = text(&child_arena, command);
    argv_values[1] = text(&child_arena, "argv-ok");
    status = native_host_process_exec_replace_v0(
        &child_capability,
        text_vector(&child_arena, argv_values, INT64_C(2)));
    _exit((status < INT64_C(0)) ? 92 : 93);
  }
  (void)close(stdin_pipe[0]);
  (void)close(stdout_pipe[1]);
  (void)close(stderr_pipe[1]);
  write_all(stdin_pipe[1], input, sizeof input - (size_t)1U);
  (void)close(stdin_pipe[1]);
  (void)read_all(stdout_pipe[0], stdout_bytes, sizeof stdout_bytes);
  (void)read_all(stderr_pipe[0], stderr_bytes, sizeof stderr_bytes);
  (void)close(stdout_pipe[0]);
  (void)close(stderr_pipe[0]);
  do {
    waited = waitpid(child, &wait_status, 0);
  } while ((waited < (pid_t)0) && (errno == EINTR));
  if ((waited != child) || !WIFEXITED(wait_status) ||
      (WEXITSTATUS(wait_status) != 0)) {
    fail("exec replacement exit", wait_status, 0);
  }
  (void)snprintf(expected_stdout, sizeof expected_stdout,
                 "pid=%lld;arg=argv-ok;env=inherit-ok;stdin=stdin-ok\n",
                 (long long)child);
  if (strcmp(stdout_bytes, expected_stdout) != 0) {
    fail("exec inherited stdout/PID/argv/env/stdin",
         (int64_t)strlen(stdout_bytes), (int64_t)strlen(expected_stdout));
  }
  if (strcmp(stderr_bytes, "stderr-ok\n") != 0) {
    fail("exec inherited stderr", (int64_t)strlen(stderr_bytes), 10);
  }
  if (native_host_process_exec_replace_v0(capability, &empty) !=
      -((int64_t)EINVAL)) {
    fail("exec empty argv validation", 0, -((int64_t)EINVAL));
  }
  missing_values[0] = text(arena, "beagle-host-context-missing-v0");
  if (native_host_process_exec_replace_v0(
          capability, text_vector(arena, missing_values, INT64_C(1))) !=
      -((int64_t)ENOENT)) {
    fail("exec missing command", 0, -((int64_t)ENOENT));
  }
  free(path_copy);
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;

  if (argc != 2) {
    return 2;
  }
  if (!native_arena_init_growable(&arena, (size_t)8192U)) {
    return 3;
  }
  require_context(&arena, &capability);
  require_tty(&capability);
  require_exec(&arena, &capability, argv[1]);
  native_arena_destroy(&arena);
  (void)puts("host-context native fixture: ok");
  return 0;
}

#endif
