#include "module_0.h"

int main(void) {
  struct text_blob {
    uint64_t length;
    uint8_t bytes[sizeof "unknown op"];
  };
  struct text_blob unknown_op = {
      .length = (uint64_t)(sizeof "unknown op" - 1U),
      .bytes = "unknown op",
  };
  uint8_t storage[4096];
  native_arena arena;
  native_m0_type_3 pair = {INT64_C(17), UINT64_C(0)};
  uint64_t keys[] = {native_m0_fn_1()};
  int64_t values[] = {INT64_C(42)};
  uint64_t version_keys[] = {UINT64_C(1)};
  native_m0_type_18 version_values[] = {{
      .tag = INT64_C(1),
      .payload = {.variant_1 = INT64_C(19)},
  }};
  native_m0_type_18 version_text_values[] = {{
      .tag = INT64_C(0),
      .payload = {
          .variant_0 = (uint64_t)(uintptr_t)&unknown_op,
      },
  }};
  uint64_t error_keys[] = {UINT64_C(2)};
  native_m0_type_16 error_values[] = {{
      .tag = INT64_C(0),
      .payload = {
          .variant_0 = (uint64_t)(uintptr_t)&unknown_op,
      },
  }};
  uint64_t reject_keys[] = {UINT64_C(3)};

  native_arena_init(&arena, storage, sizeof storage);
  uint64_t rejection_item = (uint64_t)(uintptr_t)&unknown_op;
  native_m0_type_13 rejection = native_vec_new(
      &arena, INT64_C(2), INT64_C(8), _Alignof(uint64_t));
  rejection = native_vec_push(
      &arena, rejection, &rejection_item, INT64_C(8), _Alignof(uint64_t));
  rejection = native_vec_push(
      &arena, rejection, &rejection_item, INT64_C(8), _Alignof(uint64_t));
  native_m0_type_20 reject_values[] = {{
      .tag = INT64_C(3),
      .payload = {.variant_3 = rejection},
  }};
  native_map *present = native_map_from_arrays(
      &arena, keys, values, INT64_C(1), sizeof keys[0],
      _Alignof(uint64_t), sizeof values[0],
      _Alignof(int64_t), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *missing = native_map_from_arrays(
      &arena, NULL, NULL, INT64_C(0), sizeof keys[0],
      _Alignof(uint64_t), sizeof values[0],
      _Alignof(int64_t), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *versioned = native_map_from_arrays(
      &arena, version_keys, version_values, INT64_C(1),
      sizeof version_keys[0], _Alignof(uint64_t),
      sizeof version_values[0], _Alignof(native_m0_type_18),
      NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *version_text = native_map_from_arrays(
      &arena, version_keys, version_text_values, INT64_C(1),
      sizeof version_keys[0], _Alignof(uint64_t),
      sizeof version_text_values[0], _Alignof(native_m0_type_18),
      NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *version_missing = native_map_from_arrays(
      &arena, NULL, NULL, INT64_C(0), sizeof version_keys[0],
      _Alignof(uint64_t), sizeof version_values[0],
      _Alignof(native_m0_type_18), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *optional_error = native_map_from_arrays(
      &arena, error_keys, error_values, INT64_C(1), sizeof error_keys[0],
      _Alignof(uint64_t), sizeof error_values[0],
      _Alignof(native_m0_type_16), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *optional_empty = native_map_from_arrays(
      &arena, NULL, NULL, INT64_C(0), sizeof error_keys[0],
      _Alignof(uint64_t), sizeof error_values[0],
      _Alignof(native_m0_type_16), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *rejected = native_map_from_arrays(
      &arena, reject_keys, reject_values, INT64_C(1), sizeof reject_keys[0],
      _Alignof(uint64_t), sizeof reject_values[0],
      _Alignof(native_m0_type_20), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *reject_missing = native_map_from_arrays(
      &arena, NULL, NULL, INT64_C(0), sizeof reject_keys[0],
      _Alignof(uint64_t), sizeof reject_values[0],
      _Alignof(native_m0_type_20), NATIVE_COLLECTION_EQ_KEYWORD);

  if (native_m0_fn_0(pair) != INT64_C(17)) {
    return 1;
  }
  if (!native_m0_fn_2(present) || native_m0_fn_2(missing)) {
    return 2;
  }
  if (!native_m0_fn_3(present, INT64_C(42)) ||
      native_m0_fn_3(present, INT64_C(41)) ||
      native_m0_fn_3(missing, INT64_C(42))) {
    return 3;
  }
  if (native_m0_fn_4(present) != INT64_C(42) ||
      native_m0_fn_4(missing) != INT64_C(-1) ||
      native_m0_fn_5(present) != INT64_C(42) ||
      native_m0_fn_5(missing) != INT64_C(-1)) {
    return 4;
  }
  if (native_m0_fn_6(present, INT64_C(42)) != INT64_C(42) ||
      native_m0_fn_6(present, INT64_C(41)) != INT64_C(-1) ||
      native_m0_fn_6(missing, INT64_C(42)) != INT64_C(-1)) {
    return 5;
  }
  if (native_m0_fn_7(versioned) != INT64_C(19) ||
      native_m0_fn_7(version_text) != INT64_C(-3) ||
      native_m0_fn_7(version_missing) != INT64_C(-3)) {
    return 6;
  }
  native_m0_type_14 optional_nil = native_m0_fn_8(optional_error);
  native_m0_type_14 optional_map = native_m0_fn_8(optional_empty);
  if (optional_nil.tag != INT64_C(1) ||
      optional_map.tag != INT64_C(0) ||
      optional_map.payload.variant_0 != optional_empty) {
    return 7;
  }
  if (native_m0_fn_9(rejection) != INT64_C(2) ||
      native_m0_fn_10(rejected) != INT64_C(2) ||
      native_m0_fn_10(reject_missing) != INT64_C(-1)) {
    return 8;
  }
  native_m0_type_15 other_key = native_m0_fn_11(present);
  native_m0_type_15 other_source = native_m0_fn_12(present, missing);
  if (other_key.tag != INT64_C(1) || other_source.tag != INT64_C(1)) {
    return 9;
  }
  native_m0_type_15 false_missing = native_m0_fn_13(missing);
  native_m0_type_15 false_present = native_m0_fn_13(present);
  if (false_missing.tag != INT64_C(1) ||
      false_present.tag != INT64_C(0) ||
      false_present.payload.variant_0 != INT64_C(-1)) {
    return 10;
  }
  native_m0_type_2 provider_text = (uint64_t)(uintptr_t)&unknown_op;
  native_m0_type_4 provider_pair = {provider_text};
  if (native_m0_fn_14(provider_pair) != provider_text ||
      native_m0_fn_15(provider_text) != provider_text) {
    return 11;
  }
  return 0;
}
