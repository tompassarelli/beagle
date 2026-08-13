#ifndef NATIVE_PARALLEL_H
#define NATIVE_PARALLEL_H

#include "native_shim.h"

#include <stdbool.h>
#include <stdint.h>

#define NATIVE_PARALLEL_MAX_WORKERS INT32_C(64)

typedef struct native_parallel_runtime native_parallel_runtime;

typedef enum native_parallel_boundary_v0 {
  NATIVE_PARALLEL_BOUNDARY_BOUNDED_V0 = 1,
  NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0 = 2
} native_parallel_boundary_v0;

typedef enum native_parallel_outcome_v0 {
  NATIVE_PARALLEL_OK_V0 = 0,
  NATIVE_PARALLEL_CANCELLED_V0 = 1,
  NATIVE_PARALLEL_INVALID_V0 = 2,
  NATIVE_PARALLEL_WORKER_FAILED_V0 = 3,
  NATIVE_PARALLEL_RUNTIME_FAILED_V0 = 4
} native_parallel_outcome_v0;

typedef struct native_parallel_report_v0 {
  native_parallel_outcome_v0 outcome;
  int32_t configured_workers;
  int64_t logical_partitions;
  int64_t completed_partitions;
  int64_t failing_partition;
  uint64_t generation;
} native_parallel_report_v0;

/* The callback is always a statically generated adapter. `next` is the
   transaction-private shadow buffer; the capability still records the exact
   public destination identity and checks every access interval. */
typedef int32_t (*native_parallel_f64_tile_fn_v0)(
    const native_buffer *current, native_buffer *next, int64_t partition_id,
    int64_t write_lo, int64_t write_hi,
    const native_capability *capability, void *context);

native_parallel_runtime *native_parallel_runtime_create(int32_t workers);
void native_parallel_runtime_destroy(native_parallel_runtime *runtime);
/* Reserve all transaction scratch and job metadata before a timestep loop.
   Dispatches within these bounds perform no allocation. */
bool native_parallel_runtime_reserve(native_parallel_runtime *runtime,
                                     int64_t max_elements,
                                     int64_t max_partitions);
bool native_parallel_runtime_cancel_next(native_parallel_runtime *runtime);

native_parallel_report_v0 native_parallel_tiled_step_f64_v0(
    native_parallel_runtime *runtime, const native_buffer *current,
    native_buffer *next, const native_capability *owner, int64_t tile_width,
    int64_t left_halo, int64_t right_halo,
    native_parallel_boundary_v0 boundary, native_parallel_f64_tile_fn_v0 kernel,
    void *context);

native_parallel_report_v0 native_parallel_f64_buffer_sum_v0(
    native_parallel_runtime *runtime, const native_buffer *source,
    const native_capability *owner, int64_t tile_width, double *result);

bool native_parallel_configure_default_workers(int32_t workers);
native_parallel_report_v0 native_parallel_tiled_step_f64_default_v0(
    const native_buffer *current, native_buffer *next,
    const native_capability *owner, int64_t tile_width, int64_t left_halo,
    int64_t right_halo, native_parallel_boundary_v0 boundary,
    native_parallel_f64_tile_fn_v0 kernel, void *context);
native_parallel_report_v0 native_parallel_f64_buffer_sum_default_v0(
    const native_buffer *source, const native_capability *owner,
    int64_t tile_width, double *result);

extern uint64_t native_parallel_workers_started;
extern uint64_t native_parallel_workers_joined;
extern uint64_t native_parallel_live_workers;
extern uint64_t native_parallel_scratch_allocations;
extern uint64_t native_parallel_scratch_frees;

/* Deterministic validation seam: -1 disables injection; n makes worker n and
   all later worker creations fail. It is not consulted after pool creation. */
void native_parallel_test_fail_create_after(int32_t successful_creations);

#endif /* NATIVE_PARALLEL_H */
