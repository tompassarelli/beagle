#include "module_0.h"

#define ARENA_BYTES ((size_t)262144)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(1) };

static int64_t int_at(const native_vec *values, int64_t index) {
  return *(const int64_t *)native_vec_at(values, index, INT64_C(8));
}

static uint64_t text_value(native_arena *arena, const char *value) {
  uint8_t *bytes;
  size_t length = strlen(value);
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &bytes);
  if (length > 0U) {
    memcpy(bytes, value, length);
  }
  return handle;
}

static native_vec *int_values(native_arena *arena) {
  native_vec *values = native_vec_new(arena, INT64_C(3), INT64_C(8), (size_t)8);
  int64_t three = INT64_C(3);
  int64_t one = INT64_C(1);
  int64_t two = INT64_C(2);
  values = native_vec_push(arena, values, &three, INT64_C(8), (size_t)8);
  values = native_vec_push(arena, values, &one, INT64_C(8), (size_t)8);
  return native_vec_push(arena, values, &two, INT64_C(8), (size_t)8);
}

int main(int argc, char **argv) {
  native_arena arena;
  native_vec *values;
  native_vec *empty;
  native_vec *selected;
  native_vec *sorted;
  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  if (argc > 1) {
    empty = native_vec_new(&arena, INT64_C(0), INT64_C(8), (size_t)8);
    if (strcmp(argv[1], "first") == 0) {
      (void)native_m0_fn_0(empty);
    } else if (strcmp(argv[1], "last") == 0) {
      (void)native_m0_fn_1(empty);
    } else {
      (void)native_m0_fn_2(empty);
    }
    return 99;
  }

  values = int_values(&arena);
  if ((native_m0_fn_0(values) != INT64_C(3)) ||
      (native_m0_fn_1(values) != INT64_C(2)) ||
      (native_m0_fn_2(values) != INT64_C(2))) {
    return 1;
  }

  selected = native_m0_fn_3(&arena, &capability, INT64_C(-4), values);
  if (native_vec_length(selected) != INT64_C(0)) {
    return 2;
  }
  selected = native_m0_fn_3(&arena, &capability, INT64_C(99), values);
  if ((native_vec_length(selected) != INT64_C(3)) ||
      (int_at(selected, INT64_C(0)) != INT64_C(3)) ||
      (int_at(selected, INT64_C(2)) != INT64_C(2))) {
    return 3;
  }
  selected = native_m0_fn_4(&arena, &capability, INT64_C(-4), values);
  if ((native_vec_length(selected) != INT64_C(3)) ||
      (int_at(selected, INT64_C(0)) != INT64_C(3))) {
    return 4;
  }
  selected = native_m0_fn_4(&arena, &capability, INT64_C(99), values);
  if (native_vec_length(selected) != INT64_C(0)) {
    return 5;
  }
  selected = native_m0_fn_4(&arena, &capability, INT64_C(1), values);
  if ((native_vec_length(selected) != INT64_C(2)) ||
      (int_at(selected, INT64_C(0)) != INT64_C(1)) ||
      (int_at(selected, INT64_C(1)) != INT64_C(2))) {
    return 6;
  }

  sorted = native_m0_fn_5(&arena, &capability, values);
  if ((native_vec_length(sorted) != INT64_C(3)) ||
      (int_at(sorted, INT64_C(0)) != INT64_C(1)) ||
      (int_at(sorted, INT64_C(1)) != INT64_C(2)) ||
      (int_at(sorted, INT64_C(2)) != INT64_C(3)) ||
      (int_at(values, INT64_C(0)) != INT64_C(3))) {
    return 7;
  }

  {
    uint64_t beta_first = text_value(&arena, "beta");
    uint64_t alpha = text_value(&arena, "alpha");
    uint64_t beta_second = text_value(&arena, "beta");
    native_vec *texts =
        native_vec_new(&arena, INT64_C(3), INT64_C(8), (size_t)8);
    texts = native_vec_push(&arena, texts, &beta_first, INT64_C(8), (size_t)8);
    texts = native_vec_push(&arena, texts, &alpha, INT64_C(8), (size_t)8);
    texts = native_vec_push(&arena, texts, &beta_second, INT64_C(8), (size_t)8);
    sorted = native_m0_fn_6(&arena, &capability, texts);
    if ((*(const uint64_t *)native_vec_at(sorted, INT64_C(0), INT64_C(8)) !=
         alpha) ||
        (*(const uint64_t *)native_vec_at(sorted, INT64_C(1), INT64_C(8)) !=
         beta_first) ||
        (*(const uint64_t *)native_vec_at(sorted, INT64_C(2), INT64_C(8)) !=
         beta_second)) {
      return 8;
    }
  }

  return 0;
}
