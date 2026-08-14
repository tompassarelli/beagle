#include "module_0.h"

#ifndef SIMD_COPY_FN
#error "drive.sh must name the generated copy function"
#endif
#ifndef SIMD_ADD_FN
#error "drive.sh must name the generated add function"
#endif
#ifndef SIMD_REFUSED_FN
#error "drive.sh must name the generated refused function"
#endif

static void set_f64(const native_arena *arena, native_buffer *buffer,
                    const native_capability *capability, int64_t index,
                    double value) {
  native_buffer_set(arena, buffer, capability, index, &value, INT64_C(8),
                    (size_t)8U);
}

static double get_f64(const native_arena *arena, const native_buffer *buffer,
                      const native_capability *capability, int64_t index) {
  return *(const double *)native_buffer_at(arena, buffer, capability, index,
                                           INT64_C(8), (size_t)8U);
}

static native_buffer *new_f64(native_arena *arena,
                              const native_capability *capability,
                              int64_t length) {
  return native_buffer_new(arena, capability, length, INT64_C(8), (size_t)8U);
}

int main(void) {
  native_arena arena;
  native_capability capability = {.token = UINT64_C(1)};
  native_buffer *left;
  native_buffer *right;
  native_buffer *destination;
  native_buffer *short_left;
  native_buffer *short_right;
  native_buffer *short_destination;
  const double *left_view = NULL;
  const double *right_view = NULL;
  double *destination_view = NULL;
  const double left_values[5] = {1.0, 2.0, 3.0, 4.0, 5.0};
  const double right_values[5] = {10.0, 20.0, 30.0, 40.0, 50.0};
  const double reverse_values[5] = {5.0, 4.0, 3.0, 2.0, 1.0};
  int64_t index;

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  left = new_f64(&arena, &capability, INT64_C(5));
  right = new_f64(&arena, &capability, INT64_C(5));
  destination = new_f64(&arena, &capability, INT64_C(5));
  if (left == NULL || right == NULL || destination == NULL) {
    return 2;
  }
  for (index = INT64_C(0); index < INT64_C(5); ++index) {
    set_f64(&arena, left, &capability, index, left_values[index]);
    set_f64(&arena, right, &capability, index, right_values[index]);
    set_f64(&arena, destination, &capability, index, -1.0);
  }

  if (!native_buffer_simd_f64_output_view(
          &arena, destination, &capability, INT64_C(0), INT64_C(5),
          &destination_view) ||
      !native_buffer_simd_f64_input_view(
          &arena, left, &capability, INT64_C(0), INT64_C(5), false,
          &left_view) ||
      !native_buffer_simd_f64_alias_safe(destination_view, left_view,
                                         INT64_C(0), INT64_C(5))) {
    return 3;
  }
  if (SIMD_COPY_FN(&arena, &capability, left, destination) != 1.0) {
    return 4;
  }
  for (index = INT64_C(0); index < INT64_C(5); ++index) {
    if (get_f64(&arena, destination, &capability, index) !=
        left_values[index]) {
      return 5;
    }
    set_f64(&arena, destination, &capability, index, -1.0);
  }

  if (!native_buffer_simd_f64_output_view(
          &arena, destination, &capability, INT64_C(0), INT64_C(5),
          &destination_view) ||
      !native_buffer_simd_f64_input_view(
          &arena, left, &capability, INT64_C(0), INT64_C(5), true,
          &left_view) ||
      !native_buffer_simd_f64_input_view(
          &arena, right, &capability, INT64_C(0), INT64_C(5), true,
          &right_view) ||
      !native_buffer_simd_f64_alias_safe(destination_view, left_view,
                                         INT64_C(0), INT64_C(5)) ||
      !native_buffer_simd_f64_alias_safe(destination_view, right_view,
                                         INT64_C(0), INT64_C(5))) {
    return 6;
  }
  if (SIMD_ADD_FN(&arena, &capability, left, right, destination) != 11.0) {
    return 7;
  }
  for (index = INT64_C(0); index < INT64_C(5); ++index) {
    if (get_f64(&arena, destination, &capability, index) !=
        left_values[index] + right_values[index]) {
      return 8;
    }
  }

  if (SIMD_REFUSED_FN(&arena, &capability, left, destination) != 5.0) {
    return 9;
  }
  for (index = INT64_C(0); index < INT64_C(5); ++index) {
    if (get_f64(&arena, destination, &capability, index) !=
        reverse_values[index]) {
      return 10;
    }
  }

  short_left = new_f64(&arena, &capability, INT64_C(3));
  short_right = new_f64(&arena, &capability, INT64_C(3));
  short_destination = new_f64(&arena, &capability, INT64_C(3));
  if (short_left == NULL || short_right == NULL || short_destination == NULL) {
    return 11;
  }
  for (index = INT64_C(0); index < INT64_C(3); ++index) {
    set_f64(&arena, short_left, &capability, index, (double)(index + 1));
    set_f64(&arena, short_right, &capability, index,
            (double)((index + 1) * INT64_C(2)));
  }
  if (SIMD_ADD_FN(&arena, &capability, short_left, short_right,
                  short_destination) != 3.0) {
    return 12;
  }
  for (index = INT64_C(0); index < INT64_C(3); ++index) {
    if (get_f64(&arena, short_destination, &capability, index) !=
        (double)((index + 1) * INT64_C(3))) {
      return 13;
    }
  }

  native_arena_destroy(&arena);
  return 0;
}
