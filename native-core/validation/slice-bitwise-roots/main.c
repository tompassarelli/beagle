#include "module_0.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#ifndef C17_FN
#error "C17_FN must name the generated codec-word function"
#endif

extern int64_t native_m1_fn_0(int64_t value, int64_t distance,
                              int64_t first_mask, int64_t second_mask);

int main(int argc, char **argv) {
  FILE *input;
  int64_t value;
  int64_t distance;
  int64_t first_mask;
  int64_t second_mask;

  if (argc != 2) {
    return 2;
  }
  input = fopen(argv[1], "r");
  if (input == NULL) {
    return 3;
  }
  while (fscanf(input,
                "%" SCNd64 "\t%" SCNd64 "\t%" SCNd64 "\t%" SCNd64,
                &value, &distance, &first_mask, &second_mask) == 4) {
    int64_t c17 = C17_FN(value, distance, first_mask, second_mask);
    int64_t qbe = native_m1_fn_0(value, distance, first_mask, second_mask);
    if (c17 != qbe) {
      fclose(input);
      return 4;
    }
    if (printf("%" PRId64 "\n", c17) < 0) {
      fclose(input);
      return 5;
    }
  }
  if (ferror(input) != 0) {
    fclose(input);
    return 6;
  }
  fclose(input);
  return 0;
}
