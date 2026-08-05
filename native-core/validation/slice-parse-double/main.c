#include "function_map.h"
#include "module_0.h"

#include <errno.h>
#include <fenv.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { LINE_CAPACITY = 16384, TEXT_CAPACITY = 8192 };

static int hex_digit(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

static int decode_hex(const char *text, uint8_t *bytes, size_t *length) {
  size_t text_length = strlen(text);
  size_t position;

  if ((text_length % 2u) != 0u || (text_length / 2u) > TEXT_CAPACITY) {
    return 0;
  }
  for (position = 0u; position < text_length; position += 2u) {
    int high = hex_digit(text[position]);
    int low = hex_digit(text[position + 1u]);
    if (high < 0 || low < 0) {
      return 0;
    }
    bytes[position / 2u] = (uint8_t)((high << 4) | low);
  }
  *length = text_length / 2u;
  return 1;
}

static int set_rounding_mode(const char *name) {
  int mode;

  if (strcmp(name, "nearest") == 0) {
    mode = FE_TONEAREST;
  } else if (strcmp(name, "upward") == 0) {
    mode = FE_UPWARD;
  } else if (strcmp(name, "downward") == 0) {
    mode = FE_DOWNWARD;
  } else if (strcmp(name, "towardzero") == 0) {
    mode = FE_TOWARDZERO;
  } else {
    fprintf(stderr, "unknown rounding mode: %s\n", name);
    return 0;
  }
  if (fesetround(mode) != 0) {
    fprintf(stderr, "rounding mode is unavailable: %s\n", name);
    return 0;
  }
  return 1;
}

static int parse_fields(char *line, char **case_id, char **input_hex,
                        char **expected_present, char **expected_bits) {
  char *first = strchr(line, '\t');
  char *second;
  char *third;

  if (first == NULL) {
    return 0;
  }
  *first = '\0';
  second = strchr(first + 1, '\t');
  if (second == NULL) {
    return 0;
  }
  *second = '\0';
  third = strchr(second + 1, '\t');
  if (third == NULL || strchr(third + 1, '\t') != NULL) {
    return 0;
  }
  *third = '\0';
  *case_id = line;
  *input_hex = first + 1;
  *expected_present = second + 1;
  *expected_bits = third + 1;
  return 1;
}

int main(int argc, char **argv) {
  FILE *corpus;
  char line[LINE_CAPACITY];
  size_t line_number = 0u;

  if (argc != 3) {
    fprintf(stderr, "usage: probe CORPUS ROUNDING-MODE\n");
    return 2;
  }
  if (!set_rounding_mode(argv[2])) {
    return 3;
  }
  corpus = fopen(argv[1], "rb");
  if (corpus == NULL) {
    fprintf(stderr, "cannot open corpus: %s\n", strerror(errno));
    return 4;
  }

  while (fgets(line, sizeof line, corpus) != NULL) {
    char *case_id;
    char *input_hex;
    char *expected_present_text;
    char *expected_bits_text;
    char *parse_end;
    uint8_t input[TEXT_CAPACITY];
    uint8_t storage[TEXT_CAPACITY + 1024u];
    uint8_t *text_bytes = NULL;
    size_t input_length = 0u;
    native_arena arena;
    uint64_t text;
    uint64_t expected_bits;
    uint64_t actual_bits;
    int expected_present;
    int actual_present;
    size_t line_length;

    line_number += 1u;
    line_length = strlen(line);
    if (line_length == 0u || line[line_length - 1u] != '\n') {
      fprintf(stderr, "unterminated or oversized corpus line: %zu\n", line_number);
      fclose(corpus);
      return 5;
    }
    line[line_length - 1u] = '\0';
    if (!parse_fields(line, &case_id, &input_hex, &expected_present_text,
                      &expected_bits_text)) {
      fprintf(stderr, "malformed corpus line: %zu\n", line_number);
      fclose(corpus);
      return 6;
    }
    if (!decode_hex(input_hex, input, &input_length)) {
      fprintf(stderr, "invalid input hex for case: %s\n", case_id);
      fclose(corpus);
      return 7;
    }
    if (strcmp(expected_present_text, "0") == 0) {
      expected_present = 0;
    } else if (strcmp(expected_present_text, "1") == 0) {
      expected_present = 1;
    } else {
      fprintf(stderr, "invalid presence field for case: %s\n", case_id);
      fclose(corpus);
      return 8;
    }
    errno = 0;
    parse_end = NULL;
    expected_bits = strtoull(expected_bits_text, &parse_end, 16);
    if (errno != 0 || parse_end == expected_bits_text || *parse_end != '\0') {
      fprintf(stderr, "invalid bit field for case: %s\n", case_id);
      fclose(corpus);
      return 9;
    }

    native_arena_init(&arena, storage, sizeof storage);
    text = native_text_alloc(&arena, (uint64_t)input_length, &text_bytes);
    if (input_length > 0u) {
      memcpy(text_bytes, input, input_length);
    }
    actual_present = PARSED_FN(text) ? 1 : 0;
    actual_bits = (uint64_t)PARSED_BITS_FN(text);
    if (actual_present != expected_present || actual_bits != expected_bits) {
      fprintf(stderr,
              "%s: expected present=%d bits=%016" PRIx64
              ", got present=%d bits=%016" PRIx64 "\n",
              case_id, expected_present, expected_bits, actual_present,
              actual_bits);
      fclose(corpus);
      return 10;
    }
    printf("%s\t%d\t%016" PRIx64 "\n", case_id, actual_present,
           actual_bits);
  }
  if (ferror(corpus)) {
    fprintf(stderr, "failed while reading corpus\n");
    fclose(corpus);
    return 11;
  }
  fclose(corpus);
  return 0;
}
