#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void sleep_milliseconds(int64_t milliseconds) {
  struct timespec remaining;
  struct timespec interrupted;
  remaining.tv_sec = (time_t)(milliseconds / INT64_C(1000));
  remaining.tv_nsec =
      (long)((milliseconds % INT64_C(1000)) * INT64_C(1000000));
  while ((nanosleep(&remaining, &interrupted) != 0)) {
    remaining = interrupted;
  }
}

int main(int argc, char **argv) {
  if (argc != 2) {
    return 97;
  }
  if (strcmp(argv[1], "finite") == 0) {
    (void)fputs("alpha\r\nomega", stdout);
    return 23;
  }
  if (strcmp(argv[1], "long-lived") == 0) {
    for (;;) {
      static const char tick[] = "tick\n";
      if (write(STDOUT_FILENO, tick, sizeof tick - (size_t)1U) < 0) {
        return 96;
      }
      sleep_milliseconds(INT64_C(20));
    }
  }
  if (strcmp(argv[1], "bounded") == 0) {
    (void)fputs("12345\nok\n", stdout);
    return 31;
  }
  if (strcmp(argv[1], "invalid") == 0) {
    (void)fputc(0xff, stdout);
    (void)fputs("\nok\n", stdout);
    return 32;
  }
  if (strcmp(argv[1], "empty") == 0) {
    (void)fputc('\n', stdout);
    return 33;
  }
  if (strcmp(argv[1], "delayed") == 0) {
    sleep_milliseconds(INT64_C(50));
    return 34;
  }
  return 95;
}
