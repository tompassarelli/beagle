#define _POSIX_C_SOURCE 200809L

#include "native_parallel.h"

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef struct fixture_context {
  uint64_t failing_mask;
  bool omit_last_write;
  bool periodic_left_observed;
} fixture_context;

static void require(bool condition, const char *detail) {
  if (!condition) {
    fprintf(stderr, "parallel-runtime fixture: %s\n", detail);
    _Exit(1);
  }
}

static void delay_partition(int64_t partition) {
  struct timespec delay;
  delay.tv_sec = 0;
  delay.tv_nsec = (long)((INT64_C(4) - partition) * INT64_C(2000000));
  (void)nanosleep(&delay, NULL);
}

static int32_t step_kernel(const native_buffer *current, native_buffer *next,
                           int64_t partition, int64_t lo, int64_t hi,
                           const native_capability *capability,
                           void *opaque) {
  fixture_context *context = (fixture_context *)opaque;
  int64_t index;
  delay_partition(partition);
  if (partition == INT64_C(0)) {
    const double periodic_left =
        *(const double *)native_buffer_at(current, capability,
                                         current->length - INT64_C(1),
                                         INT64_C(8));
    context->periodic_left_observed = periodic_left == 8.0;
  }
  if ((context->failing_mask & (UINT64_C(1) << (uint64_t)partition)) != 0U) {
    return (int32_t)(partition + INT64_C(1));
  }
  for (index = lo; index < hi; ++index) {
    double value;
    if (context->omit_last_write && index + INT64_C(1) == hi) {
      continue;
    }
    value = *(const double *)native_buffer_at(current, capability, index,
                                               INT64_C(8)) + 1.0;
    native_buffer_set(next, capability, index, &value, INT64_C(8));
  }
  return 0;
}

static native_buffer buffer_of(double *elements, int64_t length,
                               uint64_t owner) {
  native_buffer buffer;
  buffer.elements = elements;
  buffer.length = length;
  buffer.stride = INT64_C(8);
  buffer.alignment = _Alignof(double);
  buffer.owner_capability_token = owner;
  return buffer;
}

static uint64_t double_bits(double value) {
  uint64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

static double adjacent_pair_oracle(const double *values, int64_t length,
                                   int64_t tile_width) {
  double partials[8];
  int64_t partitions =
      length == INT64_C(0)
          ? INT64_C(0)
          : INT64_C(1) + (length - INT64_C(1)) / tile_width;
  int64_t partition;
  int64_t active;
  for (partition = 0; partition < partitions; ++partition) {
    int64_t lo = partition * tile_width;
    int64_t hi = length - lo < tile_width ? length : lo + tile_width;
    int64_t index;
    double partial = 0.0;
    for (index = lo; index < hi; ++index) {
      partial += values[index];
    }
    partials[partition] = partial;
  }
  active = partitions;
  while (active > INT64_C(1)) {
    int64_t read;
    int64_t write = INT64_C(0);
    for (read = INT64_C(0); read < active; read += INT64_C(2)) {
      partials[write++] = read + INT64_C(1) < active
                              ? partials[read] + partials[read + INT64_C(1)]
                              : partials[read];
    }
    active = write;
  }
  return partitions == INT64_C(0) ? 0.0 : partials[0];
}

static void test_worker_count_and_creation_failure(void) {
  native_parallel_runtime *runtime;
  uint64_t started = native_parallel_workers_started;
  uint64_t joined = native_parallel_workers_joined;
  require(native_parallel_runtime_create(0) == NULL,
          "zero workers must be refused");
  require(native_parallel_runtime_create(65) == NULL,
          "more than 64 workers must be refused");
  runtime = native_parallel_runtime_create(1);
  require(runtime != NULL, "one-worker serial mode must exist");
  native_parallel_runtime_destroy(runtime);
  native_parallel_test_fail_create_after(2);
  require(native_parallel_runtime_create(4) == NULL,
          "injected worker creation failure must not fall back");
  require(native_parallel_workers_started - started == UINT64_C(2),
          "creation fixture must start exactly the injected prefix");
  require(native_parallel_workers_joined - joined == UINT64_C(2),
          "creation failure must reap every started worker");
  require(native_parallel_live_workers == UINT64_C(0),
          "creation failure leaked a worker");
  native_parallel_test_fail_create_after(-1);
}

static void test_step_contract(void) {
  double current_elements[8] = {1.0, 2.0, 3.0, 4.0,
                                5.0, 6.0, 7.0, 8.0};
  double next_elements[8];
  double published[8];
  native_capability owner = {UINT64_C(71)};
  native_buffer current = buffer_of(current_elements, INT64_C(8), owner.token);
  native_buffer next = buffer_of(next_elements, INT64_C(8), owner.token);
  native_parallel_runtime *runtime = native_parallel_runtime_create(4);
  native_parallel_report_v0 report;
  fixture_context context = {UINT64_C(0), false, false};
  uint64_t allocations;
  uint64_t workers_started;
  int iteration;
  int index;
  require(runtime != NULL, "four-worker pool creation failed");
  require(native_parallel_runtime_reserve(runtime, INT64_C(8), INT64_C(4)),
          "parallel scratch reservation failed");
  allocations = native_parallel_scratch_allocations;
  workers_started = native_parallel_workers_started;
  memset(next_elements, 0, sizeof(next_elements));
  report = native_parallel_tiled_step_f64_v0(
      runtime, &current, &next, &owner, INT64_C(2), INT64_C(1), INT64_C(0),
      NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0, step_kernel, &context);
  require(report.outcome == NATIVE_PARALLEL_OK_V0,
          "valid periodic step failed");
  require(context.periodic_left_observed,
          "partition zero did not read N-1 through its periodic left halo");
  for (index = 0; index < 8; ++index) {
    require(next_elements[index] == current_elements[index] + 1.0,
            "successful step published the wrong cell");
  }
  memcpy(published, next_elements, sizeof(published));
  context.failing_mask = (UINT64_C(1) << 1U) | (UINT64_C(1) << 3U);
  report = native_parallel_tiled_step_f64_v0(
      runtime, &current, &next, &owner, INT64_C(2), INT64_C(1), INT64_C(0),
      NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0, step_kernel, &context);
  require(report.outcome == NATIVE_PARALLEL_WORKER_FAILED_V0,
          "multi-failure step did not fail");
  require(report.failing_partition == INT64_C(1),
          "failure identity followed completion order instead of partition ID");
  require(memcmp(next_elements, published, sizeof(published)) == 0,
          "failed step published transaction-private writes");
  context.failing_mask = UINT64_C(0);
  context.omit_last_write = true;
  report = native_parallel_tiled_step_f64_v0(
      runtime, &current, &next, &owner, INT64_C(2), INT64_C(1), INT64_C(0),
      NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0, step_kernel, &context);
  require(report.outcome == NATIVE_PARALLEL_WORKER_FAILED_V0,
          "missing write ownership was not detected");
  require(memcmp(next_elements, published, sizeof(published)) == 0,
          "coverage failure published a partial destination");
  context.omit_last_write = false;
  require(native_parallel_runtime_cancel_next(runtime),
          "pre-launch cancellation was not accepted");
  report = native_parallel_tiled_step_f64_v0(
      runtime, &current, &next, &owner, INT64_C(2), INT64_C(1), INT64_C(0),
      NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0, step_kernel, &context);
  require(report.outcome == NATIVE_PARALLEL_CANCELLED_V0,
          "pre-launch cancellation did not stop before writes");
  require(memcmp(next_elements, published, sizeof(published)) == 0,
          "cancelled step changed the destination");
  report = native_parallel_tiled_step_f64_v0(
      runtime, &current, &current, &owner, INT64_C(2), INT64_C(1), INT64_C(0),
      NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0, step_kernel, &context);
  require(report.outcome == NATIVE_PARALLEL_INVALID_V0,
          "aliased buffers were not refused before launch");
  for (iteration = 0; iteration < 16; ++iteration) {
    report = native_parallel_tiled_step_f64_v0(
        runtime, &current, &next, &owner, INT64_C(2), INT64_C(1), INT64_C(0),
        NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0, step_kernel, &context);
    require(report.outcome == NATIVE_PARALLEL_OK_V0,
            "reserved repeated step failed");
  }
  require(native_parallel_scratch_allocations == allocations,
          "a reserved timestep allocated scratch or job metadata");
  require(native_parallel_workers_started == workers_started,
          "a timestep recreated persistent workers");
  native_parallel_runtime_destroy(runtime);
  require(native_parallel_live_workers == UINT64_C(0),
          "step fixture leaked a worker");
}

static void test_fixed_reduction(void) {
  const int32_t worker_counts[] = {1, 2, 3, 8};
  double values[5] = {1.0e16, 1.0, -1.0e16, -0.0, 3.0};
  native_capability owner = {UINT64_C(83)};
  native_buffer source = buffer_of(values, INT64_C(5), owner.token);
  uint64_t expected = double_bits(adjacent_pair_oracle(values, INT64_C(5),
                                                        INT64_C(2)));
  size_t position;
  for (position = 0; position < sizeof(worker_counts) / sizeof(worker_counts[0]);
       ++position) {
    native_parallel_runtime *runtime =
        native_parallel_runtime_create(worker_counts[position]);
    native_parallel_report_v0 report;
    double result = NAN;
    uint64_t allocations;
    require(runtime != NULL, "reduction worker pool creation failed");
    require(native_parallel_runtime_reserve(runtime, INT64_C(0), INT64_C(3)),
            "reduction scratch reservation failed");
    allocations = native_parallel_scratch_allocations;
    report = native_parallel_f64_buffer_sum_v0(
        runtime, &source, &owner, INT64_C(2), &result);
    require(report.outcome == NATIVE_PARALLEL_OK_V0,
            "fixed-tree reduction failed");
    require(double_bits(result) == expected,
            "fixed-tree reduction changed with worker count");
    require(native_parallel_scratch_allocations == allocations,
            "reserved reduction allocated per dispatch");
    native_parallel_runtime_destroy(runtime);
  }
  require(native_parallel_live_workers == UINT64_C(0),
          "reduction fixture leaked a worker");
}

int main(void) {
  test_worker_count_and_creation_failure();
  test_step_contract();
  test_fixed_reduction();
  puts("parallel-runtime PASS deterministic intervals persistent-pool fixed-tree bounded-failure");
  return 0;
}
