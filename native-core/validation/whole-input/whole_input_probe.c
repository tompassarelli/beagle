#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(const char *detail) {
  fprintf(stderr, "whole-input: %s\n", detail);
  exit(1);
}

static uint64_t text(native_arena *arena, const uint8_t *bytes, size_t length) {
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if ((length != (size_t)0U) && (destination != NULL)) {
    memcpy(destination, bytes, length);
  }
  return result;
}

static uint64_t path_text(native_arena *arena, const char *path) {
  return text(arena, (const uint8_t *)path, strlen(path));
}

static void write_file(const char *path, const uint8_t *bytes, size_t length) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, (mode_t)0600);
  if ((fd < 0) || (write(fd, bytes, length) != (ssize_t)length) ||
      (close(fd) != 0)) {
    fail("write fixture");
  }
}

static void replace_stdin(const uint8_t *bytes, size_t length) {
  int descriptors[2];
  if (pipe(descriptors) != 0) {
    fail("pipe");
  }
  if ((write(descriptors[1], bytes, length) != (ssize_t)length) ||
      (close(descriptors[1]) != 0) || (dup2(descriptors[0], STDIN_FILENO) < 0) ||
      (close(descriptors[0]) != 0)) {
    fail("replace stdin");
  }
}

static void require_text(uint64_t actual, const uint8_t *expected,
                         size_t length, const char *detail) {
  if ((native_text_length(actual) != (uint64_t)length) ||
      ((length != (size_t)0U) &&
       (memcmp(native_text_bytes(actual), expected, length) != 0))) {
    fail(detail);
  }
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  char empty_path[4096];
  char unicode_path[4096];
  char overflow_path[4096];
  uint64_t empty;
  uint64_t unicode;
  const uint8_t cat[] = {UINT8_C(0xe7), UINT8_C(0x8c), UINT8_C(0xab)};
  const uint8_t overflow[] = {'a', 'b', 'c', 'd'};

  if ((argc != 2) && (argc != 3)) {
    fail("expected scratch directory and optional overflow mode");
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    fail("arena");
  }
  if ((snprintf(empty_path, sizeof empty_path, "%s/empty.txt", argv[1]) < 0) ||
      (snprintf(unicode_path, sizeof unicode_path, "%s/unicode.txt", argv[1]) < 0) ||
      (snprintf(overflow_path, sizeof overflow_path, "%s/overflow.txt", argv[1]) < 0)) {
    fail("path");
  }
  write_file(empty_path, NULL, (size_t)0U);
  write_file(unicode_path, cat, sizeof cat);
  write_file(overflow_path, overflow, sizeof overflow);
  if ((argc == 3) && (strcmp(argv[2], "overflow") == 0)) {
    (void)native_host_filesystem_read_text_bounded_or_die_v0(
        &arena, &capability, path_text(&arena, overflow_path), INT64_C(3));
    fail("overflow returned");
  }
  empty = native_host_filesystem_read_text_bounded_or_die_v0(
      &arena, &capability, path_text(&arena, empty_path), INT64_C(1));
  require_text(empty, (const uint8_t *)"", (size_t)0U, "empty file");
  unicode = native_host_filesystem_read_text_bounded_or_die_v0(
      &arena, &capability, path_text(&arena, unicode_path), INT64_C(16));
  require_text(unicode, cat, sizeof cat, "non-ASCII file");
  replace_stdin(cat, sizeof cat);
  require_text(native_host_stdin_read_text_bounded_or_die_v0(
                   &arena, &capability, INT64_C(16)),
               cat, sizeof cat, "non-ASCII stdin");
  replace_stdin(NULL, (size_t)0U);
  require_text(native_host_stdin_read_text_bounded_or_die_v0(
                   &arena, &capability, INT64_C(16)),
               (const uint8_t *)"", (size_t)0U, "EOF stdin");
  puts("whole-input fixture: EOF empty non-ASCII PASS");
  native_arena_destroy(&arena);
  return 0;
}
