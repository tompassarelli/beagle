#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "filesystem-build-ops fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
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

#if defined(__wasi__)

int main(void) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  uint64_t path = UINT64_C(0);

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  if (native_host_filesystem_create_temporary_sibling_v0(
          NULL, &capability, UINT64_C(0), &path) != EINVAL) {
    fail("WASI temporary without arena", 0, EINVAL);
  }
  if (native_host_filesystem_create_temporary_sibling_v0(
          &arena, NULL, UINT64_C(0), &path) != EINVAL) {
    fail("WASI temporary without capability", 0, EINVAL);
  }
  if (native_host_filesystem_create_temporary_sibling_v0(
          &arena, &capability, UINT64_C(0), NULL) != EINVAL) {
    fail("WASI temporary without out", 0, EINVAL);
  }
  path = UINT64_C(7);
  if ((native_host_filesystem_create_temporary_sibling_v0(
           &arena, &capability, UINT64_C(0), &path) != ENOTSUP) ||
      (path != UINT64_C(0))) {
    fail("WASI temporary refusal", (int64_t)path, ENOTSUP);
  }
  native_arena_destroy(&arena);
  (void)puts("filesystem-build-ops WASI fixture: ok");
  return 0;
}

#else

static void write_exact(const char *path, const char *contents) {
  size_t length = strlen(contents);
  int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                        (mode_t)0644);
  if ((descriptor < 0) ||
      (write(descriptor, contents, length) != (ssize_t)length) ||
      (close(descriptor) != 0)) {
    fail("write fixture", errno, 0);
  }
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  struct stat metadata;
  uint64_t temporary_text = UINT64_C(0);
  uint64_t target_text;
  uint64_t temporary_length;
  char *temporary;
  char contents[5] = {0};
  int64_t modified = INT64_C(0);
  int descriptor;
  int32_t status;

  if (argc != 2) {
    fail("expected target path", argc, 2);
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  target_text = text(&arena, argv[1]);
  status = native_host_filesystem_create_temporary_sibling_v0(
      &arena, &capability, target_text, &temporary_text);
  if (status != 0) {
    fail("create temporary sibling", status, 0);
  }
  temporary_length = native_text_length(temporary_text);
  temporary = (char *)malloc((size_t)temporary_length + (size_t)1U);
  if (temporary == NULL) {
    return 2;
  }
  memcpy(temporary, native_text_bytes(temporary_text),
         (size_t)temporary_length);
  temporary[temporary_length] = '\0';
  if ((strncmp(temporary, argv[1], strlen(argv[1])) != 0) ||
      (stat(temporary, &metadata) != 0) || !S_ISREG(metadata.st_mode) ||
      ((metadata.st_mode & (mode_t)0777) != (mode_t)0600)) {
    fail("temporary sibling shape", errno, 0);
  }

  write_exact(temporary, "new\n");
  write_exact(argv[1], "old\n");
  status = native_host_filesystem_mtime_nanoseconds_v0(
      &capability, temporary_text, &modified);
  if ((status != 0) || (modified <= INT64_C(0))) {
    fail("mtime nanoseconds", (status != 0) ? status : modified, 0);
  }
  status = native_host_filesystem_rename_file_v0(
      &capability, temporary_text, target_text);
  if (status != 0) {
    fail("atomic rename", status, 0);
  }
  descriptor = open(argv[1], O_RDONLY | O_CLOEXEC);
  if ((descriptor < 0) ||
      (read(descriptor, contents, (size_t)4U) != (ssize_t)4) ||
      (close(descriptor) != 0) || (memcmp(contents, "new\n", (size_t)4U) != 0)) {
    fail("rename replacement bytes", errno, 0);
  }
  status = native_host_filesystem_remove_file_v0(&capability, target_text);
  if (status != 0) {
    fail("remove file", status, 0);
  }
  status = native_host_filesystem_remove_file_v0(&capability, target_text);
  if (status != ENOENT) {
    fail("remove missing file", status, ENOENT);
  }
  status = native_host_filesystem_mtime_nanoseconds_v0(
      &capability, target_text, &modified);
  if (status != ENOENT) {
    fail("mtime missing file", status, ENOENT);
  }
  free(temporary);
  native_arena_destroy(&arena);
  (void)puts("filesystem-build-ops native fixture: ok");
  return 0;
}

#endif
