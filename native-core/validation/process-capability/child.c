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
  if ((argc != 3) || (inherited == NULL)) {
    return 97;
  }
  (void)printf("argv[1]=<%s>\nargv[2]=<%s>\nenv=<%s>\n", argv[1], argv[2],
               inherited);
  (void)fprintf(stderr, "child-stderr=<inherited>\n");
  return 23;
}
