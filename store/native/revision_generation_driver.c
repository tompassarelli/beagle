/* Native ownership driver for store.revision-generation. The generated Beagle
   function hydrates into a caller-owned arena; this host owns publication,
   swapping exactly one complete arena and destroying the rejected or replaced
   generation. */
#include "module_0.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#ifndef BEAGLE_STORE_BASELINE_REVISION
#error "BEAGLE_STORE_BASELINE_REVISION must name the pinned Beagle Store revision"
#endif

typedef native_m0_type_4 revision_set;
typedef native_m0_type_5 revision_generation;
typedef native_m0_type_10 optional_generation;

typedef struct generation_slot {
  native_arena arena;
  revision_generation *generation;
  bool live;
} generation_slot;

typedef struct churn_metrics {
  uint64_t store_epoch_count;
  uint64_t bytes_allocated;
  uint64_t bytes_reclaimed;
  uint64_t promotion_count;
  uint64_t promotion_bytes;
  uint64_t peak_rss;
  uint64_t steady_state_rss;
  uint64_t steady_arena_bytes;
} churn_metrics;

static const native_capability capability = {UINT64_C(1)};

static uint64_t text_from_bytes(native_arena *arena, const char *bytes,
                                size_t length) {
  uint8_t *destination = NULL;
  uint64_t handle =
      native_text_alloc(arena, (uint64_t)length, &destination);
  if ((length > (size_t)0U) && (destination == NULL)) {
    fprintf(stderr, "revision generation: text allocation failed\n");
    exit(2);
  }
  if (length > (size_t)0U) {
    memcpy(destination, bytes, length);
  }
  return handle;
}

static uint64_t text_from_cstr(native_arena *arena, const char *text) {
  return text_from_bytes(arena, text, strlen(text));
}

static revision_set make_revisions(native_arena *arena, const char *source,
                                   const char *program, const char *state) {
  revision_set result;
  result.field_0 = text_from_cstr(arena, source);
  result.field_1 = text_from_cstr(arena, program);
  result.field_2 = text_from_cstr(arena, state);
  return result;
}

static bool text_equals(uint64_t handle, const char *expected) {
  size_t length = strlen(expected);
  return native_text_length(handle) == (uint64_t)length &&
         memcmp(native_text_bytes(handle), expected, length) == 0;
}

static bool generation_matches(const revision_generation *generation,
                               const char *source, const char *program,
                               const char *state, const char *payload,
                               size_t payload_length) {
  return generation != NULL &&
         text_equals(generation->field_0.field_0, source) &&
         text_equals(generation->field_0.field_1, program) &&
         text_equals(generation->field_0.field_2, state) &&
         native_text_length(generation->field_1) ==
             (uint64_t)payload_length &&
         memcmp(native_text_bytes(generation->field_1), payload,
                payload_length) == 0;
}

static revision_generation *hydrate_into_arena(
    native_arena *arena, const char *expected_source,
    const char *expected_program, const char *expected_state,
    const char *actual_source, const char *actual_program,
    const char *actual_state, const char *payload, size_t payload_length) {
  revision_set expected = make_revisions(
      arena, expected_source, expected_program, expected_state);
  revision_set actual =
      make_revisions(arena, actual_source, actual_program, actual_state);
  uint64_t payload_handle = text_from_bytes(arena, payload, payload_length);
  optional_generation result =
      native_m0_fn_7(arena, &capability, expected, actual, payload_handle);

  if (result.tag == INT64_C(1)) {
    return NULL;
  }
  if ((result.tag != INT64_C(0)) || (result.payload.variant_0 == NULL)) {
    fprintf(stderr, "revision generation: invalid optional generation ABI\n");
    exit(2);
  }
  return (revision_generation *)result.payload.variant_0;
}

static bool stage_generation(
    generation_slot *staged, const char *expected_source,
    const char *expected_program, const char *expected_state,
    const char *actual_source, const char *actual_program,
    const char *actual_state, const char *payload, size_t payload_length) {
  memset(staged, 0, sizeof(*staged));
  if (!native_arena_init_growable(&staged->arena, (size_t)0U)) {
    return false;
  }
  staged->live = true;
  staged->generation = hydrate_into_arena(
      &staged->arena, expected_source, expected_program, expected_state,
      actual_source, actual_program, actual_state, payload, payload_length);
  if (staged->generation == NULL) {
    native_arena_destroy(&staged->arena);
    staged->live = false;
    return false;
  }
  return true;
}

static uint64_t close_generation(generation_slot *slot) {
  uint64_t reclaimed = 0;
  if (slot->live) {
    reclaimed = (uint64_t)native_arena_reserved_bytes(&slot->arena);
    native_arena_destroy(&slot->arena);
    slot->generation = NULL;
    slot->live = false;
  }
  return reclaimed;
}

static uint64_t publish_generation(generation_slot *active,
                                   generation_slot *staged) {
  uint64_t reclaimed = close_generation(active);
  *active = *staged;
  staged->generation = NULL;
  staged->live = false;
  return reclaimed;
}

static uint64_t hash_bytes(uint64_t hash, const uint8_t *bytes,
                           size_t length) {
  size_t index;
  for (index = 0; index < length; index++) {
    hash ^= (uint64_t)bytes[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static uint64_t hash_text(uint64_t hash, uint64_t text) {
  uint64_t length = native_text_length(text);
  hash = hash_bytes(hash, (const uint8_t *)&length, sizeof(length));
  return hash_bytes(hash, native_text_bytes(text), (size_t)length);
}

static uint64_t generation_identity(const revision_generation *generation) {
  uint64_t hash = UINT64_C(1469598103934665603);
  hash = hash_text(hash, generation->field_0.field_0);
  hash = hash_text(hash, generation->field_0.field_1);
  hash = hash_text(hash, generation->field_0.field_2);
  return hash_text(hash, generation->field_1);
}

static uint64_t peak_rss_bytes(void) {
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) {
    return UINT64_C(0);
  }
  return (uint64_t)usage.ru_maxrss * UINT64_C(1024);
}

static uint64_t resident_bytes(void) {
  FILE *status = fopen("/proc/self/statm", "r");
  unsigned long total_pages = 0;
  unsigned long pages = 0;
  long page_size;
  if (status == NULL) {
    return UINT64_C(0);
  }
  if (fscanf(status, "%lu %lu", &total_pages, &pages) != 2) {
    fclose(status);
    return UINT64_C(0);
  }
  fclose(status);
  page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    return UINT64_C(0);
  }
  return (uint64_t)pages * (uint64_t)page_size;
}

static int acceptance(void) {
  static const char source_old[] =
      "1111111111111111111111111111111111111111";
  static const char program_old[] =
      "2222222222222222222222222222222222222222";
  static const char state_old[] =
      "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  static const char source_new[] =
      "3333333333333333333333333333333333333333";
  static const char program_new[] =
      "4444444444444444444444444444444444444444";
  static const char state_new[] =
      "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  static const char payload_old[] = "durable-state-old";
  static const char payload_new[] = "durable-state-new";
  generation_slot active = {0};
  generation_slot staged = {0};
  uint64_t before_restart;
  uint64_t after_restart;
  int checks = 0;

  if (!stage_generation(&active, source_old, program_old, state_old,
                        source_old, program_old, state_old, payload_old,
                        sizeof(payload_old) - 1U)) {
    fprintf(stderr, "revision generation: initial hydration failed\n");
    return 1;
  }
  checks++;
  puts("  [PASS] initial generation binds its three named revisions");

  if (stage_generation(&staged, source_old, program_old, state_old,
                       source_new, program_new, state_new, payload_new,
                       sizeof(payload_new) - 1U)) {
    fprintf(stderr, "revision generation: mismatch was accepted\n");
    close_generation(&staged);
    close_generation(&active);
    return 1;
  }
  if (!generation_matches(active.generation, source_old, program_old,
                          state_old, payload_old,
                          sizeof(payload_old) - 1U)) {
    fprintf(stderr, "revision generation: mismatch changed active bytes\n");
    close_generation(&active);
    return 1;
  }
  checks++;
  puts("  [PASS] mismatch destroys staging and leaves the old generation visible");

  if (!stage_generation(&staged, source_new, program_new, state_new,
                        source_new, program_new, state_new, payload_new,
                        sizeof(payload_new) - 1U)) {
    fprintf(stderr, "revision generation: exact hydration failed\n");
    close_generation(&active);
    return 1;
  }
  (void)publish_generation(&active, &staged);
  if (!generation_matches(active.generation, source_new, program_new,
                          state_new, payload_new,
                          sizeof(payload_new) - 1U)) {
    fprintf(stderr, "revision generation: published revisions differ\n");
    close_generation(&active);
    return 1;
  }
  checks++;
  puts("  [PASS] successful hydration exposes only its named revisions");

  before_restart = generation_identity(active.generation);
  if (!stage_generation(&staged, source_new, program_new, state_new,
                        source_new, program_new, state_new, payload_new,
                        sizeof(payload_new) - 1U)) {
    fprintf(stderr, "revision generation: restart hydration failed\n");
    close_generation(&active);
    return 1;
  }
  (void)publish_generation(&active, &staged);
  after_restart = generation_identity(active.generation);
  if (before_restart != after_restart ||
      !generation_matches(active.generation, source_new, program_new,
                          state_new, payload_new,
                          sizeof(payload_new) - 1U)) {
    fprintf(stderr, "revision generation: restart bytes or identity moved\n");
    close_generation(&active);
    return 1;
  }
  checks++;
  puts("  [PASS] restart reproduces identical generation bytes and identity");

  (void)close_generation(&active);
  checks++;
  puts("  [PASS] every active, staged, and superseded arena is closed");
  printf("revision generation native: %d/%d PASS\n", checks, checks);
  return 0;
}

static int churn(bool managed, int64_t iterations, size_t payload_length) {
  static const char source[] =
      "1111111111111111111111111111111111111111";
  static const char program[] =
      "2222222222222222222222222222222222222222";
  char state[80];
  char *payload;
  generation_slot active = {0};
  generation_slot staged = {0};
  churn_metrics metrics = {0};
  int64_t index;

  if (iterations <= 0 || payload_length == 0U) {
    return 2;
  }
  payload = malloc(payload_length);
  if (payload == NULL) {
    return 2;
  }
  memset(payload, 'g', payload_length);

  if (!managed &&
      !native_arena_init_growable(&active.arena, (size_t)0U)) {
    free(payload);
    return 2;
  }
  if (!managed) {
    active.live = true;
    metrics.store_epoch_count = UINT64_C(1);
  }

  for (index = 0; index < iterations; index++) {
    int written = snprintf(state, sizeof(state), "sha256:%064" PRIx64,
                           (uint64_t)index);
    if (written != 71) {
      close_generation(&active);
      free(payload);
      return 2;
    }
    payload[0] = (char)('a' + (index % 26));
    if (managed) {
      uint64_t staged_bytes;
      if (!stage_generation(&staged, source, program, state, source, program,
                            state, payload, payload_length)) {
        close_generation(&active);
        free(payload);
        return 1;
      }
      staged_bytes =
          (uint64_t)native_arena_reserved_bytes(&staged.arena);
      metrics.bytes_allocated += staged_bytes;
      metrics.bytes_reclaimed += publish_generation(&active, &staged);
      metrics.store_epoch_count++;
    } else {
      active.generation = hydrate_into_arena(
          &active.arena, source, program, state, source, program, state,
          payload, payload_length);
      if (active.generation == NULL) {
        close_generation(&active);
        free(payload);
        return 1;
      }
    }
    metrics.promotion_count++;
    metrics.promotion_bytes +=
        (uint64_t)(strlen(source) + strlen(program) + strlen(state) +
                   payload_length);
  }

  metrics.steady_arena_bytes =
      (uint64_t)native_arena_reserved_bytes(&active.arena);
  if (!managed) {
    metrics.bytes_allocated = metrics.steady_arena_bytes;
  }
  metrics.peak_rss = peak_rss_bytes();
  metrics.steady_state_rss = resident_bytes();

  printf("mode %s baseline-revision " BEAGLE_STORE_BASELINE_REVISION " "
         "store-epoch-count %" PRIu64 " bytes-allocated %" PRIu64
         " bytes-reclaimed %" PRIu64 " promotion-count %" PRIu64
         " promotion-bytes %" PRIu64 " peak-rss %" PRIu64
         " steady-state-rss %" PRIu64 " steady-arena-bytes %" PRIu64
         "\n",
         managed ? "managed" : "baseline", metrics.store_epoch_count,
         metrics.bytes_allocated, metrics.bytes_reclaimed,
         metrics.promotion_count, metrics.promotion_bytes, metrics.peak_rss,
         metrics.steady_state_rss, metrics.steady_arena_bytes);

  (void)close_generation(&active);
  free(payload);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "acceptance") == 0) {
    return acceptance();
  }
  if (argc == 4 && strcmp(argv[1], "baseline") == 0) {
    return churn(false, strtoll(argv[2], NULL, 10),
                 (size_t)strtoull(argv[3], NULL, 10));
  }
  if (argc == 4 && strcmp(argv[1], "managed") == 0) {
    return churn(true, strtoll(argv[2], NULL, 10),
                 (size_t)strtoull(argv[3], NULL, 10));
  }
  fprintf(stderr,
          "usage: revision-generation acceptance|baseline|managed "
          "[iterations payload-bytes]\n");
  return 2;
}
