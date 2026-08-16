#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "process-fifo shim fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
}

static jmp_buf trap_target;
static uint32_t trapped_code = UINT32_C(0);

static void capture_trap(uint32_t code) {
  trapped_code = code;
  longjmp(trap_target, 1);
}

#if defined(__wasi__)

int main(void) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  int64_t descriptor = INT64_C(3);
  native_vec descriptors = {
      &descriptor, INT64_C(1), INT64_C(1), NULL};
  void *out = (void *)(uintptr_t)UINT64_C(1);

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  if (native_host_process_fifo_create_v0(&capability, UINT64_C(0)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI fifo create", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_process_fifo_open_read_v0(&capability, UINT64_C(0)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI fifo reader", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_process_fifo_write_deadline_v0(
          &capability, UINT64_C(0), UINT64_C(0), INT64_C(1)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI fifo writer", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_process_poll_readable_v0(
          &capability, &descriptors, INT64_C(1)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI descriptor poll", 0, -((int64_t)ENOTSUP));
  }
  if ((native_host_process_read_line_deadline_v0(
           &arena, &capability, INT64_C(3), INT64_C(8), INT64_C(1), &out) !=
       ENOTSUP) ||
      (out != NULL)) {
    fail("WASI deadline read", 0, ENOTSUP);
  }
  if (native_host_process_current_pid_v0(&capability) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI current pid", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_process_signal_v0(
          &capability, INT64_C(1), INT64_C(15)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI signal", 0, -((int64_t)ENOTSUP));
  }
  if (native_host_process_wait_not_alive_v0(
          &capability, INT64_C(1), INT64_C(1)) !=
      -((int64_t)ENOTSUP)) {
    fail("WASI wait not alive", 0, -((int64_t)ENOTSUP));
  }
  native_set_trap_reporter(capture_trap);
  if (setjmp(trap_target) == 0) {
    (void)native_host_process_alive_v0(&capability, INT64_C(1));
    fail("WASI liveness did not trap", 0, 1);
  }
  if (trapped_code != NATIVE_TRAP_IO) {
    fail("WASI liveness trap", trapped_code, NATIVE_TRAP_IO);
  }
  native_arena_destroy(&arena);
  (void)puts("process-fifo WASI fixture: ok");
  return 0;
}

#else

#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>

static volatile sig_atomic_t interruptions = 0;

static void interrupted(int signal_number) {
  (void)signal_number;
  interruptions += 1;
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

static int64_t poll_values(native_capability *capability,
                           int64_t *values, int64_t count,
                           int64_t timeout_ms) {
  native_vec descriptors = {values, count, count, NULL};
  return native_host_process_poll_readable_v0(
      capability, &descriptors, timeout_ms);
}

static int64_t monotonic_milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    fail("monotonic clock", errno, 0);
  }
  return (int64_t)now.tv_sec * INT64_C(1000) +
         (int64_t)now.tv_nsec / INT64_C(1000000);
}

static void arm_timer(int first_microseconds, int interval_microseconds) {
  struct itimerval timer;
  memset(&timer, 0, sizeof timer);
  timer.it_value.tv_sec = first_microseconds / 1000000;
  timer.it_value.tv_usec = first_microseconds % 1000000;
  timer.it_interval.tv_sec = interval_microseconds / 1000000;
  timer.it_interval.tv_usec = interval_microseconds % 1000000;
  if (setitimer(ITIMER_REAL, &timer, NULL) != 0) {
    fail("set interval timer", errno, 0);
  }
}

static void require_close(native_capability *capability, int64_t descriptor,
                          const char *detail) {
  int64_t status = native_host_process_close_v0(capability, descriptor);
  if (status != INT64_C(0)) {
    fail(detail, status, 0);
  }
}

static void require_line(native_arena *arena, native_capability *capability,
                         int64_t descriptor, const char *expected,
                         bool expected_eof, const char *detail) {
  void *out = NULL;
  native_host_process_line_v0 *line;
  size_t expected_length = strlen(expected);
  int32_t status = native_host_process_read_line_deadline_v0(
      arena, capability, descriptor, INT64_C(64), INT64_C(100), &out);
  if ((status != 0) || (out == NULL)) {
    fail(detail, status, 0);
  }
  line = (native_host_process_line_v0 *)out;
  if ((native_text_length(line->line_text) != (uint64_t)expected_length) ||
      (memcmp(native_text_bytes(line->line_text), expected,
              expected_length) != 0) ||
      (line->eof != expected_eof)) {
    fail(detail, (int64_t)native_text_length(line->line_text),
         (int64_t)expected_length);
  }
}

static void require_promoted_reader(native_capability *capability,
                                    uint64_t path) {
  int control[2];
  pid_t child;
  int64_t observed = INT64_C(-1);
  int wait_status;
  ssize_t amount;

  if (pipe(control) != 0) {
    fail("promotion control pipe", errno, 0);
  }
  child = fork();
  if (child < (pid_t)0) {
    fail("promotion fork", errno, 0);
  }
  if (child == (pid_t)0) {
    int64_t reader;
    (void)close(control[0]);
    (void)close(STDIN_FILENO);
    (void)close(STDOUT_FILENO);
    (void)close(STDERR_FILENO);
    reader = native_host_process_fifo_open_read_v0(capability, path);
    amount = write(control[1], &reader, sizeof reader);
    if ((amount != (ssize_t)sizeof reader) || (reader <= INT64_C(2))) {
      _exit(91);
    }
    if (native_host_process_close_v0(capability, reader) != INT64_C(0)) {
      _exit(92);
    }
    _exit(0);
  }
  (void)close(control[1]);
  amount = read(control[0], &observed, sizeof observed);
  (void)close(control[0]);
  if ((waitpid(child, &wait_status, 0) != child) ||
      (amount != (ssize_t)sizeof observed) ||
      !WIFEXITED(wait_status) || (WEXITSTATUS(wait_status) != 0) ||
      (observed <= INT64_C(2))) {
    fail("reader descriptor promotion", observed, 3);
  }
}

static void require_creation_and_reopen(native_arena *arena,
                                        native_capability *capability,
                                        uint64_t path, const char *path_bytes,
                                        uint64_t regular_path) {
  mode_t prior_mask;
  struct stat metadata;
  int64_t reader;
  int flags;
  int descriptor_flags;
  char received[16];
  ssize_t amount;

  prior_mask = umask((mode_t)0777);
  if (native_host_process_fifo_create_v0(capability, path) != INT64_C(0)) {
    (void)umask(prior_mask);
    fail("FIFO create", errno, 0);
  }
  (void)umask(prior_mask);
  if ((stat(path_bytes, &metadata) != 0) || !S_ISFIFO(metadata.st_mode) ||
      ((metadata.st_mode & (mode_t)0777) != (mode_t)0600)) {
    fail("FIFO type/mode", (int64_t)(metadata.st_mode & (mode_t)0777),
         (int64_t)0600);
  }
  if (native_host_process_fifo_create_v0(capability, path) !=
      -((int64_t)EEXIST)) {
    fail("strict FIFO EEXIST", 0, -((int64_t)EEXIST));
  }
  if (native_host_process_fifo_open_read_v0(capability, regular_path) !=
      -((int64_t)EINVAL)) {
    fail("FIFO reader type validation", 0, -((int64_t)EINVAL));
  }
  require_promoted_reader(capability, path);

  reader = native_host_process_fifo_open_read_v0(capability, path);
  if (reader <= INT64_C(2)) {
    fail("owned FIFO reader", reader, 3);
  }
  flags = fcntl((int)reader, F_GETFL);
  descriptor_flags = fcntl((int)reader, F_GETFD);
  if ((flags < 0) || ((flags & O_NONBLOCK) == 0) ||
      (descriptor_flags < 0) || ((descriptor_flags & FD_CLOEXEC) == 0)) {
    fail("FIFO reader flags", flags, O_NONBLOCK);
  }
  if (native_host_process_fifo_write_deadline_v0(
          capability, path, text(arena, "exact"), INT64_C(100)) !=
      INT64_C(0)) {
    fail("exact FIFO write", errno, 0);
  }
  amount = read((int)reader, received, sizeof received);
  if ((amount != (ssize_t)5) || (memcmp(received, "exact", (size_t)5U) != 0)) {
    fail("exact bytes without LF", amount, 5);
  }
  amount = read((int)reader, received, sizeof received);
  if (amount != (ssize_t)0) {
    fail("writer EOF", amount, 0);
  }
  require_close(capability, reader, "first reader close");

  reader = native_host_process_fifo_open_read_v0(capability, path);
  if (native_host_process_fifo_write_deadline_v0(
          capability, path, text(arena, "again\n"), INT64_C(100)) !=
      INT64_C(0)) {
    fail("reopen writer", errno, 0);
  }
  require_line(arena, capability, reader, "again", false, "reopened line");
  require_line(arena, capability, reader, "", true, "reopened EOF");
  require_close(capability, reader, "reopened reader close");
}

static void require_poll_order(native_arena *arena,
                               native_capability *capability,
                               uint64_t path) {
  int64_t reader = native_host_process_fifo_open_read_v0(capability, path);
  int descriptors[2];
  int64_t order[2];
  char byte = 'p';
  int64_t status;

  if ((reader <= INT64_C(2)) || (pipe(descriptors) != 0)) {
    fail("poll fixture setup", errno, 0);
  }
  if ((native_host_process_fifo_write_deadline_v0(
           capability, path, text(arena, "f"), INT64_C(100)) != INT64_C(0)) ||
      (write(descriptors[1], &byte, (size_t)1U) != (ssize_t)1)) {
    fail("make descriptors readable", errno, 0);
  }
  order[0] = (int64_t)descriptors[0];
  order[1] = reader;
  status = poll_values(capability, order, INT64_C(2), INT64_C(100));
  if (status != order[0]) {
    fail("ordered poll pipe first", status, order[0]);
  }
  order[0] = reader;
  order[1] = (int64_t)descriptors[0];
  status = poll_values(capability, order, INT64_C(2), INT64_C(100));
  if (status != order[0]) {
    fail("ordered poll FIFO first", status, order[0]);
  }
  (void)close(descriptors[0]);
  order[0] = (int64_t)descriptors[0];
  status = poll_values(capability, order, INT64_C(1), INT64_C(0));
  if (status != -((int64_t)EBADF)) {
    fail("poll invalid descriptor", status, -((int64_t)EBADF));
  }
  (void)close(descriptors[1]);
  require_close(capability, reader, "poll reader close");

  if (pipe(descriptors) != 0) {
    fail("poll timeout pipe", errno, 0);
  }
  order[0] = (int64_t)descriptors[0];
  status = poll_values(capability, order, INT64_C(1), INT64_C(25));
  if (status != -((int64_t)ETIMEDOUT)) {
    fail("poll timeout", status, -((int64_t)ETIMEDOUT));
  }
  (void)close(descriptors[0]);
  (void)close(descriptors[1]);
}

static void require_writer_deadlines(native_arena *arena,
                                     native_capability *capability,
                                     uint64_t no_reader_path,
                                     uint64_t full_path) {
  int64_t reader;
  int keeper;
  char fill[4096];
  ssize_t amount;
  int64_t status;

  if (native_host_process_fifo_create_v0(capability, no_reader_path) !=
      INT64_C(0)) {
    fail("no-reader FIFO create", errno, 0);
  }
  status = native_host_process_fifo_write_deadline_v0(
      capability, no_reader_path, text(arena, "x"), INT64_C(25));
  if (status != -((int64_t)ETIMEDOUT)) {
    fail("no-reader deadline", status, -((int64_t)ETIMEDOUT));
  }

  if (native_host_process_fifo_create_v0(capability, full_path) !=
      INT64_C(0)) {
    fail("full FIFO create", errno, 0);
  }
  reader = native_host_process_fifo_open_read_v0(capability, full_path);
  keeper = open((const char *)native_text_bytes(full_path),
                O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if ((reader <= INT64_C(2)) || (keeper < 0)) {
    fail("full FIFO open", errno, 0);
  }
  memset(fill, 'x', sizeof fill);
  for (;;) {
    amount = write(keeper, fill, sizeof fill);
    if (amount > (ssize_t)0) {
      continue;
    }
    if ((amount < (ssize_t)0) && (errno == EINTR)) {
      continue;
    }
    if ((amount < (ssize_t)0) &&
        ((errno == EAGAIN) || (errno == EWOULDBLOCK))) {
      break;
    }
    fail("fill FIFO", errno, EAGAIN);
  }
  status = native_host_process_fifo_write_deadline_v0(
      capability, full_path, text(arena, "y"), INT64_C(25));
  if (status != -((int64_t)ETIMEDOUT)) {
    fail("full FIFO deadline", status, -((int64_t)ETIMEDOUT));
  }
  (void)close(keeper);
  require_close(capability, reader, "full FIFO reader close");
}

static void require_read_deadlines(native_arena *arena,
                                   native_capability *capability,
                                   uint64_t timeout_path,
                                   uint64_t partial_path) {
  struct sigaction action;
  int64_t reader;
  int keeper;
  void *out;
  int32_t status;
  int64_t started;
  int64_t elapsed;

  if (native_host_process_fifo_create_v0(capability, timeout_path) !=
      INT64_C(0)) {
    fail("timeout FIFO create", errno, 0);
  }
  reader = native_host_process_fifo_open_read_v0(capability, timeout_path);
  keeper = open((const char *)native_text_bytes(timeout_path),
                O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if ((reader <= INT64_C(2)) || (keeper < 0)) {
    fail("timeout FIFO open", errno, 0);
  }
  out = (void *)(uintptr_t)UINT64_C(1);
  status = native_host_process_read_line_deadline_v0(
      arena, capability, reader, INT64_C(64), INT64_C(25), &out);
  if ((status != ETIMEDOUT) || (out != NULL)) {
    fail("zero-byte deadline", status, ETIMEDOUT);
  }
  memset(&action, 0, sizeof action);
  action.sa_handler = interrupted;
  (void)sigemptyset(&action.sa_mask);
  if (sigaction(SIGALRM, &action, NULL) != 0) {
    fail("install EINTR handler", errno, 0);
  }
  interruptions = 0;
  arm_timer(2000, 2000);
  started = monotonic_milliseconds();
  out = (void *)(uintptr_t)UINT64_C(1);
  status = native_host_process_read_line_deadline_v0(
      arena, capability, reader, INT64_C(64), INT64_C(80), &out);
  elapsed = monotonic_milliseconds() - started;
  arm_timer(0, 0);
  if ((status != ETIMEDOUT) || (out != NULL) || (interruptions == 0) ||
      (elapsed < INT64_C(40)) || (elapsed > INT64_C(1000))) {
    fail("EINTR deadline preservation", elapsed, 80);
  }
  (void)close(keeper);
  require_close(capability, reader, "timeout reader close");

  if (native_host_process_fifo_create_v0(capability, partial_path) !=
      INT64_C(0)) {
    fail("partial FIFO create", errno, 0);
  }
  reader = native_host_process_fifo_open_read_v0(capability, partial_path);
  keeper = open((const char *)native_text_bytes(partial_path),
                O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if ((reader <= INT64_C(2)) || (keeper < 0) ||
      (write(keeper, "partial", (size_t)7U) != (ssize_t)7)) {
    fail("partial FIFO setup", errno, 0);
  }
  out = (void *)(uintptr_t)UINT64_C(1);
  status = native_host_process_read_line_deadline_v0(
      arena, capability, reader, INT64_C(64), INT64_C(30), &out);
  if ((status != EPROTO) || (out != NULL)) {
    fail("partial line deadline", status, EPROTO);
  }
  require_close(capability, reader, "partial reader mandatory close");
  (void)close(keeper);
  reader = native_host_process_fifo_open_read_v0(capability, partial_path);
  if (native_host_process_fifo_write_deadline_v0(
          capability, partial_path, text(arena, "whole\n"), INT64_C(100)) !=
      INT64_C(0)) {
    fail("post-partial reopen writer", errno, 0);
  }
  require_line(arena, capability, reader, "whole", false,
               "post-partial reopened line");
  require_close(capability, reader, "post-partial reopened close");
}

static void require_pid_lifecycle(native_capability *capability) {
  int64_t current = native_host_process_current_pid_v0(capability);
  pid_t child;
  int64_t status;
  int wait_status;
  struct timespec pause_time = {(time_t)0, 20000000L};

  if ((current != (int64_t)getpid()) ||
      !native_host_process_alive_v0(capability, current)) {
    fail("current PID/liveness", current, (int64_t)getpid());
  }
  if (native_host_process_alive_v0(capability, (int64_t)INT_MAX)) {
    fail("missing PID liveness", 1, 0);
  }
  trapped_code = UINT32_C(0);
  native_set_trap_reporter(capture_trap);
  if (setjmp(trap_target) == 0) {
    (void)native_host_process_alive_v0(capability, INT64_C(-1));
    fail("invalid liveness did not trap", 0, 1);
  }
  if (trapped_code != NATIVE_TRAP_INVALID_ARGUMENT) {
    fail("invalid liveness trap", trapped_code, NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if ((native_host_process_signal_v0(
           capability, INT64_C(0), (int64_t)SIGTERM) !=
       -((int64_t)EINVAL)) ||
      (native_host_process_signal_v0(
           capability, INT64_C(-1), (int64_t)SIGTERM) !=
       -((int64_t)EINVAL))) {
    fail("process-group signal refusal", 0, -((int64_t)EINVAL));
  }
  child = fork();
  if (child < (pid_t)0) {
    fail("signal child fork", errno, 0);
  }
  if (child == (pid_t)0) {
    for (;;) {
      pause();
    }
  }
  status = native_host_process_signal_v0(
      capability, (int64_t)child, (int64_t)SIGTERM);
  if (status != INT64_C(0)) {
    fail("targeted signal", status, 0);
  }
  status = native_host_process_wait_v0(capability, (int64_t)child);
  if (status != INT64_C(256) + (int64_t)SIGTERM) {
    fail("existing wait after signal", status,
         INT64_C(256) + (int64_t)SIGTERM);
  }
  if (native_host_process_wait_v0(capability, (int64_t)child) !=
      -((int64_t)ECHILD)) {
    fail("existing wait reaps once", 0, -((int64_t)ECHILD));
  }

  child = fork();
  if (child < (pid_t)0) {
    fail("non-reaping child fork", errno, 0);
  }
  if (child == (pid_t)0) {
    _exit(17);
  }
  (void)nanosleep(&pause_time, NULL);
  status = native_host_process_wait_not_alive_v0(
      capability, (int64_t)child, INT64_C(25));
  if (status != -((int64_t)ETIMEDOUT)) {
    fail("wait-not-alive preserves zombie", status,
         -((int64_t)ETIMEDOUT));
  }
  status = native_host_process_wait_v0(capability, (int64_t)child);
  if (status != INT64_C(17)) {
    fail("child wait remained available", status, 17);
  }
  status = native_host_process_wait_not_alive_v0(
      capability, (int64_t)INT_MAX, INT64_C(25));
  if (status != INT64_C(0)) {
    fail("wait missing PID", status, 0);
  }
  status = native_host_process_wait_not_alive_v0(
      capability, current, INT64_C(25));
  if (status != -((int64_t)ETIMEDOUT)) {
    fail("bounded live PID wait", status, -((int64_t)ETIMEDOUT));
  }
  if (waitpid((pid_t)-1, &wait_status, WNOHANG) > (pid_t)0) {
    fail("unexpected unreaped child", wait_status, 0);
  }
}

static void make_path(char *out, size_t capacity, const char *directory,
                      const char *leaf) {
  int amount = snprintf(out, capacity, "%s/%s", directory, leaf);
  if ((amount < 0) || ((size_t)amount >= capacity)) {
    fail("fixture path", amount, 0);
  }
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  char main_path[1024];
  char regular_path[1024];
  char no_reader_path[1024];
  char full_path[1024];
  char timeout_path[1024];
  char partial_path[1024];
  int regular;
  uint64_t main_text;
  uint64_t regular_text;
  uint64_t no_reader_text;
  uint64_t full_text;
  uint64_t timeout_text;
  uint64_t partial_text;

  if (argc != 2) {
    return 2;
  }
  if (!native_arena_init_growable(&arena, (size_t)16384U)) {
    return 3;
  }
  make_path(main_path, sizeof main_path, argv[1], "main.fifo");
  make_path(regular_path, sizeof regular_path, argv[1], "regular");
  make_path(no_reader_path, sizeof no_reader_path, argv[1], "no-reader.fifo");
  make_path(full_path, sizeof full_path, argv[1], "full.fifo");
  make_path(timeout_path, sizeof timeout_path, argv[1], "timeout.fifo");
  make_path(partial_path, sizeof partial_path, argv[1], "partial.fifo");
  regular = open(regular_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                 (mode_t)0600);
  if (regular < 0) {
    fail("regular fixture", errno, 0);
  }
  (void)close(regular);
  main_text = text(&arena, main_path);
  regular_text = text(&arena, regular_path);
  no_reader_text = text(&arena, no_reader_path);
  full_text = text(&arena, full_path);
  timeout_text = text(&arena, timeout_path);
  partial_text = text(&arena, partial_path);

  require_creation_and_reopen(
      &arena, &capability, main_text, main_path, regular_text);
  require_poll_order(&arena, &capability, main_text);
  require_writer_deadlines(
      &arena, &capability, no_reader_text, full_text);
  require_read_deadlines(
      &arena, &capability, timeout_text, partial_text);
  require_pid_lifecycle(&capability);

  (void)unlink(main_path);
  (void)unlink(regular_path);
  (void)unlink(no_reader_path);
  (void)unlink(full_path);
  (void)unlink(timeout_path);
  (void)unlink(partial_path);
  native_arena_destroy(&arena);
  (void)puts("process-fifo native fixture: ok");
  return 0;
}

#endif
