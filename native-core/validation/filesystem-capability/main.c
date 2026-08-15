#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(const char *detail) {
  fprintf(stderr, "filesystem-capability fixture: %s\n", detail);
  exit(1);
}

static uint64_t text(native_arena *arena, const char *value) {
  size_t length = strlen(value);
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != (size_t)0U) {
    memcpy(destination, value, length);
  }
  return result;
}

static void path_join(char *out, size_t size, const char *directory,
                      const char *name) {
  int amount = snprintf(out, size, "%s/%s", directory, name);
  if ((amount < 0) || ((size_t)amount >= size)) {
    fail("path overflow");
  }
}

static void require_status(int32_t actual, int32_t expected,
                           const char *detail) {
  if (actual != expected) {
    fprintf(stderr,
            "filesystem-capability fixture: %s: got %d expected %d\n",
            detail, actual, expected);
    exit(1);
  }
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  char a_path[4096];
  char b_path[4096];
  char link_path[4096];
  char invalid_path[4096];
  uint64_t a_text;
  uint64_t b_text;
  uint64_t link_text;
  uint64_t invalid_text;
  uint64_t contents = UINT64_C(0);
  native_vec *entries = NULL;
  int64_t kind = INT64_C(0);
  int descriptor;
  const uint8_t invalid[] = {UINT8_C(0xc3), UINT8_C(0x28)};

  if (argc != 2) {
    fail("expected scratch directory");
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    fail("arena");
  }
  path_join(a_path, sizeof a_path, argv[1], "a.txt");
  path_join(b_path, sizeof b_path, argv[1], "b.txt");
  path_join(link_path, sizeof link_path, argv[1], "link.txt");
  path_join(invalid_path, sizeof invalid_path, argv[1], "invalid.txt");
  a_text = text(&arena, a_path);
  b_text = text(&arena, b_path);
  link_text = text(&arena, link_path);
  invalid_text = text(&arena, invalid_path);

  require_status(native_host_filesystem_write_text_atomic_v0(
                     &capability, b_text, text(&arena, "bravo\n")),
                 0, "write b");
  require_status(native_host_filesystem_write_text_atomic_v0(
                     &capability, a_text, text(&arena, "alpha\n")),
                 0, "write a");
  if (symlink("a.txt", link_path) != 0) {
    fail("symlink");
  }
  descriptor = open(invalid_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                    (mode_t)0644);
  if ((descriptor < 0) ||
      (write(descriptor, invalid, sizeof invalid) != (ssize_t)sizeof invalid) ||
      (close(descriptor) != 0)) {
    fail("invalid UTF-8 fixture");
  }

  require_status(native_host_filesystem_path_kind_v0(&capability, a_text, &kind),
                 0, "regular path kind");
  if (kind != INT64_C(1)) {
    fail("regular path kind value");
  }
  require_status(
      native_host_filesystem_path_kind_v0(&capability, link_text, &kind), 0,
      "symlink path kind");
  if (kind != INT64_C(3)) {
    fail("symlink path kind value");
  }
  require_status(native_host_filesystem_read_text_bounded_v0(
                     &arena, &capability, a_text, INT64_C(5), &contents),
                 EFBIG, "read bound");
  require_status(native_host_filesystem_read_text_bounded_v0(
                     &arena, &capability, invalid_text, INT64_C(16), &contents),
                 EILSEQ, "invalid UTF-8");
  require_status(native_host_filesystem_read_text_bounded_v0(
                     &arena, &capability, a_text, INT64_C(16), &contents),
                 0, "read a");
  if ((native_text_length(contents) != UINT64_C(6)) ||
      (memcmp(native_text_bytes(contents), "alpha\n", (size_t)6U) != 0)) {
    fail("read contents");
  }
  require_status(native_host_filesystem_list_directory_bounded_v0(
                     &arena, &capability, text(&arena, argv[1]), INT64_C(3),
                     &entries),
                 EOVERFLOW, "directory bound");
  require_status(native_host_filesystem_list_directory_bounded_v0(
                     &arena, &capability, text(&arena, argv[1]), INT64_C(4),
                     &entries),
                 0, "directory listing");
  if ((native_vec_length(entries) != INT64_C(4)) ||
      (native_text_compare(*(const uint64_t *)native_vec_at(
                               entries, INT64_C(0), INT64_C(8)),
                           text(&arena, "a.txt")) != INT64_C(0)) ||
      (native_text_compare(*(const uint64_t *)native_vec_at(
                               entries, INT64_C(1), INT64_C(8)),
                           text(&arena, "b.txt")) != INT64_C(0)) ||
      (native_text_compare(*(const uint64_t *)native_vec_at(
                               entries, INT64_C(2), INT64_C(8)),
                           text(&arena, "invalid.txt")) != INT64_C(0)) ||
      (native_text_compare(*(const uint64_t *)native_vec_at(
                               entries, INT64_C(3), INT64_C(8)),
                           text(&arena, "link.txt")) != INT64_C(0))) {
    fail("directory order");
  }

  native_arena_destroy(&arena);
  puts("filesystem capability fixture: ok");
  return 0;
}
