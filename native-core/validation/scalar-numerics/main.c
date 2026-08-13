#include "module_0.h"

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef I64_ADD_FN
#error "I64_ADD_FN is required"
#endif
#ifndef I64_SUBTRACT_FN
#error "I64_SUBTRACT_FN is required"
#endif
#ifndef I64_MULTIPLY_FN
#error "I64_MULTIPLY_FN is required"
#endif
#ifndef I64_NEGATE_FN
#error "I64_NEGATE_FN is required"
#endif
#ifndef I64_ADD_THREE_LEFT_FN
#error "I64_ADD_THREE_LEFT_FN is required"
#endif
#ifndef I64_ADD_THREE_RIGHT_FN
#error "I64_ADD_THREE_RIGHT_FN is required"
#endif
#ifndef I64_QUOTIENT_FN
#error "I64_QUOTIENT_FN is required"
#endif
#ifndef I64_REMAINDER_FN
#error "I64_REMAINDER_FN is required"
#endif
#ifndef I64_MODULUS_FN
#error "I64_MODULUS_FN is required"
#endif
#ifndef F64_TO_BITS_FN
#error "F64_TO_BITS_FN is required"
#endif
#ifndef F64_FROM_BITS_FN
#error "F64_FROM_BITS_FN is required"
#endif
#ifndef F64_ADD_BITS_FN
#error "F64_ADD_BITS_FN is required"
#endif
#ifndef F64_SUBTRACT_BITS_FN
#error "F64_SUBTRACT_BITS_FN is required"
#endif
#ifndef F64_MULTIPLY_BITS_FN
#error "F64_MULTIPLY_BITS_FN is required"
#endif
#ifndef F64_DIVIDE_BITS_FN
#error "F64_DIVIDE_BITS_FN is required"
#endif
#ifndef F64_EQUAL_BITS_FN
#error "F64_EQUAL_BITS_FN is required"
#endif
#ifndef F64_LESS_BITS_FN
#error "F64_LESS_BITS_FN is required"
#endif
#ifndef F64_LESS_EQUAL_BITS_FN
#error "F64_LESS_EQUAL_BITS_FN is required"
#endif
#ifndef F64_ADD_LEFT_BITS_FN
#error "F64_ADD_LEFT_BITS_FN is required"
#endif
#ifndef F64_ADD_RIGHT_BITS_FN
#error "F64_ADD_RIGHT_BITS_FN is required"
#endif
#ifndef F64_MULTIPLY_THEN_ADD_BITS_FN
#error "F64_MULTIPLY_THEN_ADD_BITS_FN is required"
#endif
#ifndef F64_KERNEL_FN
#error "F64_KERNEL_FN is required"
#endif

static void report_trap(uint32_t code) {
  (void)fprintf(stderr, "trap\t%" PRIu32 "\n", code);
  (void)fflush(stderr);
}

static int64_t parse_i64(const char *text) {
  char *end = NULL;
  intmax_t value;

  errno = 0;
  value = strtoimax(text, &end, 10);
  if ((errno != 0) || (end == text) || (*end != '\0') ||
      (value < INT64_MIN) || (value > INT64_MAX)) {
    (void)fprintf(stderr, "invalid i64: %s\n", text);
    exit(64);
  }
  return (int64_t)value;
}

static int64_t parse_f64_bits(const char *text) {
  char *end = NULL;
  uintmax_t value;
  uint64_t bits;
  int64_t result;

  errno = 0;
  value = strtoumax(text, &end, 16);
  if ((errno != 0) || (end == text) || (*end != '\0') ||
      (value > UINT64_MAX) || (strlen(text) != 16U)) {
    (void)fprintf(stderr, "invalid f64 bits: %s\n", text);
    exit(64);
  }
  bits = (uint64_t)value;
  memcpy(&result, &bits, sizeof result);
  return result;
}

static double f64_from_raw_bits(const char *text) {
  int64_t signed_bits = parse_f64_bits(text);
  double result;

  memcpy(&result, &signed_bits, sizeof result);
  return result;
}

static void print_f64_bits_from_i64(int64_t value) {
  uint64_t bits;

  memcpy(&bits, &value, sizeof bits);
  (void)printf("%016" PRIx64 "\n", bits);
}

static void print_f64_bits_from_double(double value) {
  uint64_t bits;

  memcpy(&bits, &value, sizeof bits);
  (void)printf("%016" PRIx64 "\n", bits);
}

int main(int argc, char **argv) {
  const char *operation;

  if (argc != 5) {
    (void)fprintf(stderr, "usage: scalar-probe OP ARG0 ARG1 ARG2\n");
    return 64;
  }
  native_set_trap_reporter(report_trap);
  operation = argv[1];

  if (strcmp(operation, "i64-add") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_ADD_FN(parse_i64(argv[2]), parse_i64(argv[3])));
  } else if (strcmp(operation, "i64-subtract") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_SUBTRACT_FN(parse_i64(argv[2]), parse_i64(argv[3])));
  } else if (strcmp(operation, "i64-multiply") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_MULTIPLY_FN(parse_i64(argv[2]), parse_i64(argv[3])));
  } else if (strcmp(operation, "i64-negate") == 0) {
    (void)printf("%" PRId64 "\n", I64_NEGATE_FN(parse_i64(argv[2])));
  } else if (strcmp(operation, "i64-add-three-left") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_ADD_THREE_LEFT_FN(parse_i64(argv[2]),
                                       parse_i64(argv[3]),
                                       parse_i64(argv[4])));
  } else if (strcmp(operation, "i64-add-three-right") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_ADD_THREE_RIGHT_FN(parse_i64(argv[2]),
                                        parse_i64(argv[3]),
                                        parse_i64(argv[4])));
  } else if (strcmp(operation, "i64-quotient") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_QUOTIENT_FN(parse_i64(argv[2]), parse_i64(argv[3])));
  } else if (strcmp(operation, "i64-remainder") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_REMAINDER_FN(parse_i64(argv[2]), parse_i64(argv[3])));
  } else if (strcmp(operation, "i64-modulus") == 0) {
    (void)printf("%" PRId64 "\n",
                 I64_MODULUS_FN(parse_i64(argv[2]), parse_i64(argv[3])));
  } else if (strcmp(operation, "f64-to-bits") == 0) {
    print_f64_bits_from_i64(F64_TO_BITS_FN(f64_from_raw_bits(argv[2])));
  } else if (strcmp(operation, "f64-from-bits") == 0) {
    print_f64_bits_from_double(F64_FROM_BITS_FN(parse_f64_bits(argv[2])));
  } else if (strcmp(operation, "f64-add-bits") == 0) {
    print_f64_bits_from_i64(
        F64_ADD_BITS_FN(parse_f64_bits(argv[2]), parse_f64_bits(argv[3])));
  } else if (strcmp(operation, "f64-subtract-bits") == 0) {
    print_f64_bits_from_i64(
        F64_SUBTRACT_BITS_FN(parse_f64_bits(argv[2]),
                             parse_f64_bits(argv[3])));
  } else if (strcmp(operation, "f64-multiply-bits") == 0) {
    print_f64_bits_from_i64(F64_MULTIPLY_BITS_FN(parse_f64_bits(argv[2]),
                                                 parse_f64_bits(argv[3])));
  } else if (strcmp(operation, "f64-divide-bits") == 0) {
    print_f64_bits_from_i64(
        F64_DIVIDE_BITS_FN(parse_f64_bits(argv[2]), parse_f64_bits(argv[3])));
  } else if (strcmp(operation, "f64-equal-bits") == 0) {
    (void)printf("%d\n", F64_EQUAL_BITS_FN(parse_f64_bits(argv[2]),
                                            parse_f64_bits(argv[3]))
                              ? 1
                              : 0);
  } else if (strcmp(operation, "f64-less-bits") == 0) {
    (void)printf("%d\n", F64_LESS_BITS_FN(parse_f64_bits(argv[2]),
                                           parse_f64_bits(argv[3]))
                              ? 1
                              : 0);
  } else if (strcmp(operation, "f64-less-equal-bits") == 0) {
    (void)printf("%d\n", F64_LESS_EQUAL_BITS_FN(parse_f64_bits(argv[2]),
                                                 parse_f64_bits(argv[3]))
                              ? 1
                              : 0);
  } else if (strcmp(operation, "f64-add-left-bits") == 0) {
    print_f64_bits_from_i64(F64_ADD_LEFT_BITS_FN(parse_f64_bits(argv[2]),
                                                 parse_f64_bits(argv[3]),
                                                 parse_f64_bits(argv[4])));
  } else if (strcmp(operation, "f64-add-right-bits") == 0) {
    print_f64_bits_from_i64(F64_ADD_RIGHT_BITS_FN(parse_f64_bits(argv[2]),
                                                  parse_f64_bits(argv[3]),
                                                  parse_f64_bits(argv[4])));
  } else if (strcmp(operation, "f64-multiply-then-add-bits") == 0) {
    print_f64_bits_from_i64(
        F64_MULTIPLY_THEN_ADD_BITS_FN(parse_f64_bits(argv[2]),
                                      parse_f64_bits(argv[3]),
                                      parse_f64_bits(argv[4])));
  } else if (strcmp(operation, "f64-kernel") == 0) {
    (void)printf("%.17g\n", F64_KERNEL_FN(parse_f64_bits(argv[2]),
                                           parse_f64_bits(argv[3]),
                                           parse_f64_bits(argv[4])));
  } else {
    (void)fprintf(stderr, "unknown operation: %s\n", operation);
    return 64;
  }
  return 0;
}
