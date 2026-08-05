#include <string.h>

#ifndef FLOAT_DIVIDE_FN
#error "FLOAT_DIVIDE_FN must name the generated float division function"
#endif

extern double FLOAT_DIVIDE_FN(double left, double right);

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "zero") == 0) {
    (void)FLOAT_DIVIDE_FN(1.0, 0.0);
    return 2;
  }
  const double quotient = FLOAT_DIVIDE_FN(7.5, 2.5);
  return quotient == 3.0 ? 0 : 1;
}
