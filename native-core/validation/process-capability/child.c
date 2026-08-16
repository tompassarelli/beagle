#define _POSIX_C_SOURCE 200809L

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  const char *inherited = getenv("BEAGLE_PROCESS_FIXTURE");
  if ((argc == 2) && (strcmp(argv[1], "signal") == 0)) {
    return raise(SIGTERM) == 0 ? 99 : 98;
  }
  if ((argc == 2) && (strcmp(argv[1], "capture") == 0)) {
    char input[32];
    size_t amount = fread(input, (size_t)1U, sizeof input, stdin);
    if ((amount != (size_t)12U) ||
        (memcmp(input, "exact stdin\n", (size_t)12U) != 0) ||
        !feof(stdin)) {
      return 96;
    }
    (void)fputs("stdin=<exact stdin\\n>\n", stdout);
    (void)fputs("child-stderr=<captured>\n", stderr);
    return 19;
  }
  if ((argc == 2) && (strcmp(argv[1], "capture-large") == 0)) {
    size_t index;
    for (index = (size_t)0U; index < (size_t)8192U; ++index) {
      (void)fputc('o', stdout);
      (void)fputc('e', stderr);
    }
    return 0;
  }
  if ((argc == 2) && (strcmp(argv[1], "capture-invalid") == 0)) {
    (void)fputc(0xff, stdout);
    return 0;
  }
  if ((argc != 3) || (inherited == NULL)) {
    return 97;
  }
  (void)printf("argv[1]=<%s>\nargv[2]=<%s>\nenv=<%s>\n", argv[1], argv[2],
               inherited);
  (void)fprintf(stderr, "child-stderr=<inherited>\n");
  return 23;
}
