#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "file-lease shim fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
}

#if defined(__wasi__)

int main(void) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  int64_t descriptor = INT64_C(7);

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  /* The capability is validated before the platform verdict, exactly as
     write-text-atomic does, so a missing capability is EINVAL even here. */
  if (native_host_filesystem_lock_exclusive_v0(NULL, UINT64_C(0),
                                               &descriptor) != EINVAL) {
    fail("WASI lock without capability", 0, EINVAL);
  }
  if (native_host_filesystem_lock_exclusive_v0(&capability, UINT64_C(0),
                                               NULL) != EINVAL) {
    fail("WASI lock without out", 0, EINVAL);
  }
  if (native_host_filesystem_unlock_v0(NULL, INT64_C(7)) != EINVAL) {
    fail("WASI unlock without capability", 0, EINVAL);
  }
  if (native_host_filesystem_unlock_v0(&capability, INT64_C(2)) != EINVAL) {
    fail("WASI unlock rejects a standard descriptor", 0, EINVAL);
  }
  descriptor = INT64_C(7);
  if ((native_host_filesystem_lock_exclusive_v0(&capability, UINT64_C(0),
                                                &descriptor) != ENOTSUP) ||
      (descriptor != INT64_C(0))) {
    fail("WASI lock", descriptor, ENOTSUP);
  }
  if (native_host_filesystem_unlock_v0(&capability, INT64_C(7)) != ENOTSUP) {
    fail("WASI unlock", 0, ENOTSUP);
  }
  native_arena_destroy(&arena);
  (void)puts("file-lease WASI fixture: ok");
  return 0;
}

#else

#include <fcntl.h>
#include <limits.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>

static uint64_t text(native_arena *arena, const char *source) {
  size_t length = strlen(source);
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != (size_t)0U) {
    memcpy(destination, source, length);
  }
  return result;
}

static int64_t require_lease(native_capability *capability, uint64_t path,
                             const char *detail) {
  int64_t descriptor = INT64_C(-1);
  int32_t status =
      native_host_filesystem_lock_exclusive_v0(capability, path, &descriptor);
  if ((status != 0) || (descriptor <= (int64_t)STDERR_FILENO)) {
    fail(detail, (status != 0) ? (int64_t)status : descriptor, 0);
  }
  return descriptor;
}

static void require_release(native_capability *capability, int64_t descriptor,
                            const char *detail) {
  int32_t status = native_host_filesystem_unlock_v0(capability, descriptor);
  if (status != 0) {
    fail(detail, status, 0);
  }
}

static void require_contended(native_capability *capability, uint64_t path,
                              const char *detail) {
  int64_t descriptor = INT64_C(-1);
  int32_t status =
      native_host_filesystem_lock_exclusive_v0(capability, path, &descriptor);
  if ((status != EAGAIN) || (descriptor != INT64_C(0))) {
    fail(detail, status, EAGAIN);
  }
}

static void require_pipe(int *descriptors, const char *detail) {
  if (pipe(descriptors) != 0) {
    fail(detail, errno, 0);
  }
}

static void send_status(int descriptor, int32_t status) {
  if (write(descriptor, &status, sizeof status) != (ssize_t)sizeof status) {
    _exit(90);
  }
}

static int32_t receive_status(int descriptor, const char *detail) {
  int32_t status = 0;
  if (read(descriptor, &status, sizeof status) != (ssize_t)sizeof status) {
    fail(detail, errno, 0);
  }
  return status;
}

static void require_exit(pid_t child, const char *detail) {
  int wait_status = 0;
  if (waitpid(child, &wait_status, 0) != child) {
    fail(detail, errno, 0);
  }
  if (!WIFEXITED(wait_status)) {
    fail(detail, (int64_t)wait_status, 0);
  }
  if (WEXITSTATUS(wait_status) != 0) {
    fail(detail, (int64_t)WEXITSTATUS(wait_status), 0);
  }
}

/* Arguments and the same-process acquire/release cycle. */
static void require_argument_contract(native_capability *capability,
                                      uint64_t path, uint64_t directory) {
  int64_t descriptor = INT64_C(-1);
  int flags;

  if (native_host_filesystem_lock_exclusive_v0(NULL, path, &descriptor) !=
      EINVAL) {
    fail("lock without capability", 0, EINVAL);
  }
  if (native_host_filesystem_lock_exclusive_v0(capability, path, NULL) !=
      EINVAL) {
    fail("lock without out", 0, EINVAL);
  }
  if (native_host_filesystem_unlock_v0(NULL, INT64_C(7)) != EINVAL) {
    fail("unlock without capability", 0, EINVAL);
  }
  if ((native_host_filesystem_unlock_v0(capability, INT64_C(2)) != EINVAL) ||
      (native_host_filesystem_unlock_v0(capability, INT64_C(-1)) != EINVAL) ||
      (native_host_filesystem_unlock_v0(
           capability, (int64_t)INT_MAX + INT64_C(1)) != EINVAL)) {
    fail("unlock descriptor range", 0, EINVAL);
  }
  if (native_host_filesystem_lock_exclusive_v0(capability, directory,
                                               &descriptor) != EISDIR) {
    fail("lock a directory", descriptor, EISDIR);
  }

  descriptor = require_lease(capability, path, "first lease");
  flags = fcntl((int)descriptor, F_GETFD);
  if ((flags < 0) || ((flags & FD_CLOEXEC) == 0)) {
    fail("lease descriptor flags", flags, FD_CLOEXEC);
  }
  require_release(capability, descriptor, "first release");
  /* Re-acquiring in the same process is the release's own witness. */
  descriptor = require_lease(capability, path, "reacquire after release");
  require_release(capability, descriptor, "second release");
}

/* The parent holds the lease before forking, so no race decides the outcome.
   The child opens the path itself: an INHERITED descriptor shares the open
   file description and re-locking it succeeds, which the child proves first so
   this case cannot pass for that wrong reason. */
static void require_contention(native_capability *capability, uint64_t path) {
  int64_t held;
  int report[2];
  pid_t child;
  int32_t observed;

  held = require_lease(capability, path, "contention parent lease");
  require_pipe(report, "contention report pipe");
  child = fork();
  if (child < (pid_t)0) {
    fail("contention fork", errno, 0);
  }
  if (child == (pid_t)0) {
    int64_t descriptor = INT64_C(-1);
    int32_t status;
    (void)close(report[0]);
    if (flock((int)held, LOCK_EX | LOCK_NB) != 0) {
      _exit(91); /* Negative control: the shared description must re-lock. */
    }
    status = native_host_filesystem_lock_exclusive_v0(capability, path,
                                                      &descriptor);
    send_status(report[1], status);
    if ((status == 0) && (descriptor > (int64_t)STDERR_FILENO)) {
      _exit(92); /* A fresh open file description must never win. */
    }
    _exit(0);
  }
  (void)close(report[1]);
  observed = receive_status(report[0], "contention report");
  (void)close(report[0]);
  require_exit(child, "contention child");
  if (observed != EAGAIN) {
    fail("contention errno", observed, EAGAIN);
  }
  require_release(capability, held, "contention parent release");
}

/* The parent releases, THEN writes the gate byte. The child's blocking read
   cannot return before that write, so its acquire strictly follows the
   release; ordering comes from the pipe, never from elapsed time. */
static void require_handoff(native_capability *capability, uint64_t path) {
  int64_t held;
  int gate[2];
  int report[2];
  pid_t child;
  int32_t observed;
  char byte = 'g';

  held = require_lease(capability, path, "handoff parent lease");
  require_pipe(gate, "handoff gate pipe");
  require_pipe(report, "handoff report pipe");
  child = fork();
  if (child < (pid_t)0) {
    fail("handoff fork", errno, 0);
  }
  if (child == (pid_t)0) {
    int64_t descriptor = INT64_C(-1);
    int32_t status;
    char received = '\0';
    (void)close(gate[1]);
    (void)close(report[0]);
    if (read(gate[0], &received, (size_t)1U) != (ssize_t)1) {
      _exit(93);
    }
    status = native_host_filesystem_lock_exclusive_v0(capability, path,
                                                      &descriptor);
    send_status(report[1], status);
    if (status == 0) {
      status = native_host_filesystem_unlock_v0(capability, descriptor);
      if (status != 0) {
        _exit(94);
      }
    }
    _exit(0);
  }
  (void)close(gate[0]);
  (void)close(report[1]);
  require_release(capability, held, "handoff parent release");
  if (write(gate[1], &byte, (size_t)1U) != (ssize_t)1) {
    fail("handoff gate write", errno, 0);
  }
  (void)close(gate[1]);
  observed = receive_status(report[0], "handoff report");
  (void)close(report[0]);
  require_exit(child, "handoff child");
  if (observed != 0) {
    fail("handoff successor acquire", observed, 0);
  }
}

/* The motivating property. The child acquires and exits WITHOUT releasing;
   waitpid's return is the happens-before edge proving the kernel tore the
   descriptor down, so the parent's next acquire is an assertion, not a poll. */
static void require_release_on_death(native_capability *capability,
                                     uint64_t path) {
  int ack[2];
  int go[2];
  pid_t child;
  int32_t observed;
  int64_t descriptor;
  char byte = 'x';

  require_pipe(ack, "death ack pipe");
  require_pipe(go, "death go pipe");
  child = fork();
  if (child < (pid_t)0) {
    fail("death fork", errno, 0);
  }
  if (child == (pid_t)0) {
    int64_t held = INT64_C(-1);
    int32_t status;
    char received = '\0';
    (void)close(ack[0]);
    (void)close(go[1]);
    status =
        native_host_filesystem_lock_exclusive_v0(capability, path, &held);
    send_status(ack[1], status);
    if (read(go[0], &received, (size_t)1U) != (ssize_t)1) {
      _exit(95);
    }
    _exit(0); /* No unlock: the kernel is the only releaser here. */
  }
  (void)close(ack[1]);
  (void)close(go[0]);
  observed = receive_status(ack[0], "death ack");
  (void)close(ack[0]);
  if (observed != 0) {
    fail("death child acquire", observed, 0);
  }
  /* The child is still blocked on go, so it demonstrably holds the lease. */
  require_contended(capability, path, "lease held by a live holder");
  if (write(go[1], &byte, (size_t)1U) != (ssize_t)1) {
    fail("death go write", errno, 0);
  }
  (void)close(go[1]);
  require_exit(child, "death child");
  descriptor = require_lease(capability, path, "acquire after holder death");
  require_release(capability, descriptor, "post-death release");
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
  char lease_path[1024];
  uint64_t lease_text;
  uint64_t directory_text;

  if (argc != 2) {
    return 2;
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 3;
  }
  make_path(lease_path, sizeof lease_path, argv[1], "lease");
  lease_text = text(&arena, lease_path);
  directory_text = text(&arena, argv[1]);

  require_argument_contract(&capability, lease_text, directory_text);
  require_contention(&capability, lease_text);
  require_handoff(&capability, lease_text);
  require_release_on_death(&capability, lease_text);

  (void)unlink(lease_path);
  native_arena_destroy(&arena);
  (void)puts("file-lease native fixture: ok");
  return 0;
}

#endif
