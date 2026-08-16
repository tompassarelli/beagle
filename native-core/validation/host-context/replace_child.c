#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char input[64];
  ssize_t amount;
  const char *environment = getenv("BEAGLE_EXEC_ENV");

  if ((argc != 2) || (environment == NULL)) {
    return 64;
  }
  amount = read(STDIN_FILENO, input, sizeof(input) - (size_t)1U);
  if (amount < (ssize_t)0) {
    return (errno == 0) ? 65 : 66;
  }
  input[amount] = '\0';
  if (printf("pid=%lld;arg=%s;env=%s;stdin=%s",
             (long long)getpid(), argv[1], environment, input) < 0) {
    return 67;
  }
  if (fputs("stderr-ok\n", stderr) == EOF) {
    return 68;
  }
  return 0;
}
