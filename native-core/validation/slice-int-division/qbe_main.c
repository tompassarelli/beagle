#include <string.h>

#ifndef FLOAT_ARITHMETIC_FN
#error "FLOAT_ARITHMETIC_FN must name the generated float arithmetic function"
#endif

extern double FLOAT_ARITHMETIC_FN(double left, double right);

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "zero") == 0) {
    (void)FLOAT_ARITHMETIC_FN(1.0, 0.0);
    return 2;
  }
  return FLOAT_ARITHMETIC_FN(7.5, 2.5) == 7.5 ? 0 : 1;
}
