#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "process-stream shim fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
}

#if defined(__wasi__)

int main(void) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  native_vec argv = {NULL, INT64_C(0), INT64_C(0), NULL};
  void *out = (void *)(uintptr_t)UINT64_C(1);

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  if (native_host_process_spawn_stdout_v0(
          &arena, &capability, &argv, &out) != ENOTSUP || out != NULL) {
    fail("WASI spawn refusal", 0, ENOTSUP);
  }
  out = (void *)(uintptr_t)UINT64_C(1);
  if (native_host_process_read_line_bounded_v0(
          &arena, &capability, INT64_C(3), INT64_C(16), &out) != ENOTSUP ||
      out != NULL) {
    fail("WASI read refusal", 0, ENOTSUP);
  }
  if (native_host_process_wait_v0(&capability, INT64_C(1)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI wait refusal", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_process_close_v0(&capability, INT64_C(3)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI close refusal", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_time_sleep_milliseconds_v0(&capability, INT64_C(0)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI sleep refusal", 0, -((int64_t)ENOTSUP));
  }
  native_arena_destroy(&arena);
  (void)puts("process-stream WASI refusal fixture: ok");
  return 0;
}

#else

#include <signal.h>
#include <sys/time.h>

static volatile sig_atomic_t interruptions = 0;

static void interrupted(int signal_number) {
  (void)signal_number;
  interruptions += 1;
}

static void arm_timer(int microseconds) {
  struct itimerval timer;
  memset(&timer, 0, sizeof timer);
  timer.it_value.tv_sec = microseconds / 1000000;
  timer.it_value.tv_usec = microseconds % 1000000;
  if (setitimer(ITIMER_REAL, &timer, NULL) != 0) {
    fail("arm timer", errno, 0);
  }
}

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

static void require_text(uint64_t actual, const char *expected,
                         const char *detail) {
  size_t length = strlen(expected);
  if ((native_text_length(actual) != (uint64_t)length) ||
      (memcmp(native_text_bytes(actual), expected, length) != 0)) {
    fail(detail, (int64_t)native_text_length(actual), (int64_t)length);
  }
}

static native_host_process_spawned_stdout_v0 *spawn_mode(
    native_arena *arena, native_capability *capability, const char *child,
    const char *mode) {
  uint64_t values[2] = {text(arena, child), text(arena, mode)};
  void *out = NULL;
  int32_t status = native_host_process_spawn_stdout_v0(
      arena, capability, text_vector(arena, values, INT64_C(2)), &out);
  if ((status != 0) || (out == NULL)) {
    fail("spawn mode", status, 0);
  }
  if ((((native_host_process_spawned_stdout_v0 *)out)->pid <= INT64_C(0)) ||
      (((native_host_process_spawned_stdout_v0 *)out)->stdout_fd <=
       INT64_C(2))) {
    fail("spawn ownership", 0, 1);
  }
  return (native_host_process_spawned_stdout_v0 *)out;
}

static void require_line(native_arena *arena, native_capability *capability,
                         int64_t fd, int64_t bound, const char *expected,
                         bool eof, const char *detail) {
  void *out = NULL;
  int32_t status = native_host_process_read_line_bounded_v0(
      arena, capability, fd, bound, &out);
  native_host_process_line_v0 *line;
  if ((status != 0) || (out == NULL)) {
    fail(detail, status, 0);
  }
  line = (native_host_process_line_v0 *)out;
  require_text(line->line_text, expected, detail);
  if (line->eof != eof) {
    fail(detail, line->eof ? 1 : 0, eof ? 1 : 0);
  }
}

static void require_close_wait(native_capability *capability, int64_t fd,
                               int64_t pid, int64_t expected) {
  int64_t status = native_host_process_close_v0(capability, fd);
  if (status != INT64_C(0)) {
    fail("close", status, 0);
  }
  status = native_host_process_wait_v0(capability, pid);
  if (status != expected) {
    fail("wait", status, expected);
  }
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  native_vec empty = {NULL, INT64_C(0), INT64_C(0), NULL};
  uint64_t missing_value[1];
  void *out = (void *)(uintptr_t)UINT64_C(1);
  int32_t read_status;
  int64_t status;
  native_host_process_spawned_stdout_v0 *spawned;
  struct sigaction action;

  if (argc != 2) {
    return 2;
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 3;
  }
  memset(&action, 0, sizeof action);
  action.sa_handler = interrupted;
  (void)sigemptyset(&action.sa_mask);
  if (sigaction(SIGALRM, &action, NULL) != 0) {
    return 4;
  }

  if (native_host_process_spawn_stdout_v0(
          &arena, &capability, &empty, &out) != EINVAL || out != NULL) {
    fail("empty argv", 0, EINVAL);
  }
  missing_value[0] = text(&arena, "beagle-process-stream-missing-v0");
  out = (void *)(uintptr_t)UINT64_C(1);
  if (native_host_process_spawn_stdout_v0(
          &arena, &capability,
          text_vector(&arena, missing_value, INT64_C(1)), &out) != ENOENT ||
      out != NULL) {
    fail("missing executable", 0, ENOENT);
  }
  if (native_host_process_close_v0(&capability, INT64_C(2)) !=
      -((int64_t)EINVAL)) {
    fail("stdio close refusal", 0, -((int64_t)EINVAL));
  }
  if (native_host_process_wait_v0(&capability, INT64_C(-1)) !=
      -((int64_t)EINVAL)) {
    fail("invalid pid", 0, -((int64_t)EINVAL));
  }
  out = (void *)(uintptr_t)UINT64_C(1);
  if (native_host_process_read_line_bounded_v0(
          &arena, &capability, INT64_C(2), INT64_C(16), &out) != EINVAL ||
      out != NULL) {
    fail("stdio read refusal", 0, EINVAL);
  }
  if (native_host_process_read_line_bounded_v0(
          &arena, &capability, INT64_C(3),
          NATIVE_HOST_PROCESS_MAX_LINE_BYTES + INT64_C(1), &out) != EFBIG) {
    fail("maximum line bound", 0, EFBIG);
  }
  if (native_host_time_sleep_milliseconds_v0(
          &capability, INT64_C(-1)) != -((int64_t)EINVAL)) {
    fail("negative sleep", 0, -((int64_t)EINVAL));
  }

  spawned = spawn_mode(&arena, &capability, argv[1], "finite");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(5), "alpha",
               false, "CRLF line");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(5), "omega",
               false, "final partial line");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(5), "", true,
               "EOF");
  require_close_wait(&capability, spawned->stdout_fd, spawned->pid,
                     INT64_C(23));
  status = native_host_process_wait_v0(&capability, spawned->pid);
  if (status != -((int64_t)ECHILD)) {
    fail("second wait", status, -((int64_t)ECHILD));
  }
  status = native_host_process_close_v0(&capability, spawned->stdout_fd);
  if (status != -((int64_t)EBADF)) {
    fail("second close", status, -((int64_t)EBADF));
  }

  spawned = spawn_mode(&arena, &capability, argv[1], "bounded");
  out = (void *)(uintptr_t)UINT64_C(1);
  read_status = native_host_process_read_line_bounded_v0(
      &arena, &capability, spawned->stdout_fd, INT64_C(4), &out);
  if ((read_status != EFBIG) || (out != NULL)) {
    fail("line overflow", read_status, EFBIG);
  }
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(4), "ok",
               false, "overflow drain");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(4), "", true,
               "overflow EOF");
  require_close_wait(&capability, spawned->stdout_fd, spawned->pid,
                     INT64_C(31));

  spawned = spawn_mode(&arena, &capability, argv[1], "invalid");
  out = (void *)(uintptr_t)UINT64_C(1);
  read_status = native_host_process_read_line_bounded_v0(
      &arena, &capability, spawned->stdout_fd, INT64_C(4), &out);
  if ((read_status != EILSEQ) || (out != NULL)) {
    fail("invalid UTF-8", read_status, EILSEQ);
  }
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(4), "ok",
               false, "invalid UTF-8 drain");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(4), "", true,
               "invalid UTF-8 EOF");
  require_close_wait(&capability, spawned->stdout_fd, spawned->pid,
                     INT64_C(32));

  spawned = spawn_mode(&arena, &capability, argv[1], "empty");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(0), "", false,
               "empty line");
  require_line(&arena, &capability, spawned->stdout_fd, INT64_C(0), "", true,
               "empty line EOF");
  require_close_wait(&capability, spawned->stdout_fd, spawned->pid,
                     INT64_C(33));

  interruptions = 0;
  arm_timer(5000);
  status = native_host_time_sleep_milliseconds_v0(&capability, INT64_C(20));
  if ((status != INT64_C(0)) || (interruptions == 0)) {
    fail("sleep EINTR", status, 0);
  }

  spawned = spawn_mode(&arena, &capability, argv[1], "delayed");
  status = native_host_process_close_v0(&capability, spawned->stdout_fd);
  if (status != INT64_C(0)) {
    fail("delayed close", status, 0);
  }
  interruptions = 0;
  arm_timer(5000);
  status = native_host_process_wait_v0(&capability, spawned->pid);
  if ((status != INT64_C(34)) || (interruptions == 0)) {
    fail("wait EINTR", status, 34);
  }

  native_arena_destroy(&arena);
  (void)puts("process-stream shim fixture: ok");
  return 0;
}

#endif
