#define _POSIX_C_SOURCE 200809L

#include "native_parallel.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef enum native_parallel_job_kind {
  NATIVE_PARALLEL_JOB_NONE = 0,
  NATIVE_PARALLEL_JOB_STEP = 1,
  NATIVE_PARALLEL_JOB_SUM = 2
} native_parallel_job_kind;

typedef struct native_parallel_worker_arg {
  struct native_parallel_runtime *runtime;
  int32_t worker_id;
} native_parallel_worker_arg;

struct native_parallel_runtime {
  int32_t workers;
  int32_t thread_count;
  pthread_t threads[NATIVE_PARALLEL_MAX_WORKERS];
  native_parallel_worker_arg worker_args[NATIVE_PARALLEL_MAX_WORKERS];
  pthread_mutex_t mutex;
  pthread_cond_t start;
  pthread_cond_t done;
  bool mutex_ready;
  bool start_ready;
  bool done_ready;
  bool shutdown;
  bool active;
  bool cancel_next;
  bool stop_claims;
  uint64_t generation;
  int64_t partition_count;
  int64_t next_partition;
  int64_t claimed;
  int64_t completed;
  int64_t lowest_failure;
  native_parallel_job_kind job_kind;
  const native_arena *arena;
  const native_buffer *current;
  native_buffer *next;
  native_buffer *shadow;
  const native_capability *owner;
  int64_t tile_width;
  int64_t left_halo;
  int64_t right_halo;
  native_parallel_boundary_v0 boundary;
  native_parallel_f64_tile_fn_v0 kernel;
  void *context;
  double *partials;
  int32_t *statuses;
  uint8_t *coverage;
  double *shadow_elements;
  int64_t element_capacity;
  int64_t partition_capacity;
};

uint64_t native_parallel_workers_started = UINT64_C(0);
uint64_t native_parallel_workers_joined = UINT64_C(0);
uint64_t native_parallel_live_workers = UINT64_C(0);
uint64_t native_parallel_scratch_allocations = UINT64_C(0);
uint64_t native_parallel_scratch_frees = UINT64_C(0);

static _Atomic int32_t native_parallel_create_failure_after = -1;

static native_parallel_report_v0 native_parallel_report(
    native_parallel_outcome_v0 outcome, int32_t workers, int64_t partitions,
    int64_t completed, int64_t failure, uint64_t generation) {
  native_parallel_report_v0 report;
  report.outcome = outcome;
  report.configured_workers = workers;
  report.logical_partitions = partitions;
  report.completed_partitions = completed;
  report.failing_partition = failure;
  report.generation = generation;
  return report;
}

static bool native_parallel_valid_workers(int32_t workers) {
  return workers >= INT32_C(1) && workers <= NATIVE_PARALLEL_MAX_WORKERS;
}

static bool native_parallel_add_clamped(int64_t value, int64_t amount,
                                        int64_t limit, int64_t *result) {
  if (amount < INT64_C(0) || value < INT64_C(0) || value > limit) {
    return false;
  }
  if (amount > limit - value) {
    *result = limit;
  } else {
    *result = value + amount;
  }
  return true;
}

static bool native_parallel_partition_count(int64_t length, int64_t width,
                                            int64_t *count) {
  if (length < INT64_C(0) || width <= INT64_C(0)) {
    return false;
  }
  *count = length == INT64_C(0)
               ? INT64_C(0)
               : INT64_C(1) + (length - INT64_C(1)) / width;
  return true;
}

static bool native_parallel_storage_range(const native_buffer *buffer,
                                          uintptr_t *lo, uintptr_t *hi) {
  uint64_t bytes;
  if (buffer == NULL || buffer->length < INT64_C(0) ||
      buffer->stride <= INT64_C(0)) {
    return false;
  }
  if ((uint64_t)buffer->length > UINT64_MAX / (uint64_t)buffer->stride) {
    return false;
  }
  bytes = (uint64_t)buffer->length * (uint64_t)buffer->stride;
  *lo = (uintptr_t)buffer->elements;
  if (bytes > (uint64_t)(UINTPTR_MAX - *lo)) {
    return false;
  }
  *hi = *lo + (uintptr_t)bytes;
  return bytes == UINT64_C(0) || buffer->elements != NULL;
}

static bool native_parallel_buffers_disjoint(const native_buffer *left,
                                             const native_buffer *right) {
  uintptr_t left_lo;
  uintptr_t left_hi;
  uintptr_t right_lo;
  uintptr_t right_hi;
  return left != right && native_parallel_storage_range(left, &left_lo, &left_hi) &&
         native_parallel_storage_range(right, &right_lo, &right_hi) &&
         (left_hi <= right_lo || right_hi <= left_lo);
}

static native_parallel_access_v0 native_parallel_partition_access(
    native_parallel_runtime *runtime, int64_t partition, int64_t lo,
    int64_t hi) {
  native_parallel_access_v0 access;
  int64_t length = runtime->current->length;
  memset(&access, 0, sizeof(access));
  access.current = runtime->current;
  access.next = runtime->next;
  access.shadow = runtime->shadow;
  access.generation = runtime->generation;
  access.partition_id = partition;
  access.write_lo = lo;
  access.write_hi = hi;
  access.write_coverage = runtime->coverage;
  access.permissions = NATIVE_PARALLEL_PERMISSION_READ_CURRENT |
                       NATIVE_PARALLEL_PERMISSION_WRITE_NEXT;
  if (runtime->boundary == NATIVE_PARALLEL_BOUNDARY_BOUNDED_V0 ||
      length == INT64_C(0)) {
    access.read_lo_0 =
        runtime->left_halo > lo ? INT64_C(0) : lo - runtime->left_halo;
    (void)native_parallel_add_clamped(hi, runtime->right_halo, length,
                                      &access.read_hi_0);
  } else {
    int64_t span_lo = lo - runtime->left_halo;
    int64_t span_hi;
    (void)native_parallel_add_clamped(hi, runtime->right_halo, INT64_MAX,
                                      &span_hi);
    if (runtime->left_halo >= length || runtime->right_halo >= length ||
        runtime->left_halo + runtime->right_halo >= length - (hi - lo)) {
      access.read_lo_0 = INT64_C(0);
      access.read_hi_0 = length;
    } else if (span_lo < INT64_C(0)) {
      access.read_lo_0 = INT64_C(0);
      access.read_hi_0 = span_hi;
      access.read_lo_1 = length + span_lo;
      access.read_hi_1 = length;
    } else if (span_hi > length) {
      access.read_lo_0 = span_lo;
      access.read_hi_0 = length;
      access.read_lo_1 = INT64_C(0);
      access.read_hi_1 = span_hi - length;
    } else {
      access.read_lo_0 = span_lo;
      access.read_hi_0 = span_hi;
    }
  }
  return access;
}

static int32_t native_parallel_execute_partition(
    native_parallel_runtime *runtime, int64_t partition) {
  int64_t lo;
  int64_t hi;
  native_parallel_access_v0 access;
  if (partition > INT64_MAX / runtime->tile_width) {
    return EOVERFLOW;
  }
  lo = partition * runtime->tile_width;
  hi = runtime->current->length - lo < runtime->tile_width
           ? runtime->current->length
           : lo + runtime->tile_width;
  access = native_parallel_partition_access(runtime, partition, lo, hi);
  native_parallel_access_current = &access;
  if (runtime->job_kind == NATIVE_PARALLEL_JOB_STEP) {
    int32_t status = runtime->kernel(
        runtime->arena, runtime->current, runtime->next, partition, lo, hi,
        runtime->owner, runtime->context);
    native_parallel_access_current = NULL;
    return status;
  }
  {
    double partial = 0.0;
    int64_t index;
    access.permissions = NATIVE_PARALLEL_PERMISSION_READ_CURRENT;
    access.read_lo_0 = lo;
    access.read_hi_0 = hi;
    access.read_lo_1 = INT64_C(0);
    access.read_hi_1 = INT64_C(0);
    for (index = lo; index < hi; ++index) {
      partial += *(const double *)native_buffer_at(
          runtime->arena, runtime->current, runtime->owner, index, INT64_C(8),
          _Alignof(double));
    }
    runtime->partials[partition] = partial;
  }
  native_parallel_access_current = NULL;
  return 0;
}

static bool native_parallel_job_done(const native_parallel_runtime *runtime) {
  if (runtime->stop_claims) {
    return runtime->completed == runtime->claimed;
  }
  return runtime->completed == runtime->partition_count;
}

static void *native_parallel_worker_main(void *opaque) {
  native_parallel_worker_arg *arg = (native_parallel_worker_arg *)opaque;
  native_parallel_runtime *runtime = arg->runtime;
  uint64_t observed = UINT64_C(0);
  (void)arg->worker_id;
  (void)pthread_mutex_lock(&runtime->mutex);
  for (;;) {
    while (!runtime->shutdown &&
           (!runtime->active || runtime->generation == observed)) {
      (void)pthread_cond_wait(&runtime->start, &runtime->mutex);
    }
    if (runtime->shutdown) {
      (void)pthread_mutex_unlock(&runtime->mutex);
      return NULL;
    }
    observed = runtime->generation;
    for (;;) {
      int64_t partition;
      int32_t status;
      if (runtime->stop_claims ||
          runtime->next_partition >= runtime->partition_count) {
        break;
      }
      partition = runtime->next_partition++;
      runtime->claimed++;
      (void)pthread_mutex_unlock(&runtime->mutex);
      status = native_parallel_execute_partition(runtime, partition);
      (void)pthread_mutex_lock(&runtime->mutex);
      runtime->statuses[partition] = status;
      runtime->completed++;
      if (status != 0) {
        runtime->stop_claims = true;
        if (runtime->lowest_failure < INT64_C(0) ||
            partition < runtime->lowest_failure) {
          runtime->lowest_failure = partition;
        }
      }
      if (native_parallel_job_done(runtime)) {
        (void)pthread_cond_signal(&runtime->done);
      }
    }
    if (native_parallel_job_done(runtime)) {
      (void)pthread_cond_signal(&runtime->done);
    }
  }
}

void native_parallel_test_fail_create_after(int32_t successful_creations) {
  atomic_store_explicit(&native_parallel_create_failure_after,
                        successful_creations, memory_order_relaxed);
}

native_parallel_runtime *native_parallel_runtime_create(int32_t workers) {
  native_parallel_runtime *runtime;
  int32_t index;
  if (!native_parallel_valid_workers(workers)) {
    return NULL;
  }
  runtime = (native_parallel_runtime *)calloc(1U, sizeof(*runtime));
  if (runtime == NULL) {
    return NULL;
  }
  runtime->workers = workers;
  runtime->lowest_failure = INT64_C(-1);
  if (pthread_mutex_init(&runtime->mutex, NULL) != 0) {
    free(runtime);
    return NULL;
  }
  runtime->mutex_ready = true;
  if (pthread_cond_init(&runtime->start, NULL) != 0) {
    native_parallel_runtime_destroy(runtime);
    return NULL;
  }
  runtime->start_ready = true;
  if (pthread_cond_init(&runtime->done, NULL) != 0) {
    native_parallel_runtime_destroy(runtime);
    return NULL;
  }
  runtime->done_ready = true;
  if (workers == INT32_C(1)) {
    return runtime;
  }
  for (index = 0; index < workers; ++index) {
    int32_t fail_after = atomic_load_explicit(
        &native_parallel_create_failure_after, memory_order_relaxed);
    runtime->worker_args[index].runtime = runtime;
    runtime->worker_args[index].worker_id = index;
    if ((fail_after >= 0 && index >= fail_after) ||
        pthread_create(&runtime->threads[index], NULL,
                       native_parallel_worker_main,
                       &runtime->worker_args[index]) != 0) {
      (void)pthread_mutex_lock(&runtime->mutex);
      runtime->shutdown = true;
      (void)pthread_cond_broadcast(&runtime->start);
      (void)pthread_mutex_unlock(&runtime->mutex);
      native_parallel_runtime_destroy(runtime);
      return NULL;
    }
    runtime->thread_count++;
    native_parallel_workers_started++;
    native_parallel_live_workers++;
  }
  return runtime;
}

void native_parallel_runtime_destroy(native_parallel_runtime *runtime) {
  int32_t index;
  if (runtime == NULL) {
    return;
  }
  if (runtime->mutex_ready) {
    (void)pthread_mutex_lock(&runtime->mutex);
    runtime->shutdown = true;
    if (runtime->start_ready) {
      (void)pthread_cond_broadcast(&runtime->start);
    }
    (void)pthread_mutex_unlock(&runtime->mutex);
  }
  for (index = 0; index < runtime->thread_count; ++index) {
    (void)pthread_join(runtime->threads[index], NULL);
    native_parallel_workers_joined++;
    native_parallel_live_workers--;
  }
  if (runtime->done_ready) {
    (void)pthread_cond_destroy(&runtime->done);
  }
  if (runtime->start_ready) {
    (void)pthread_cond_destroy(&runtime->start);
  }
  if (runtime->mutex_ready) {
    (void)pthread_mutex_destroy(&runtime->mutex);
  }
  free(runtime->shadow_elements);
  free(runtime->coverage);
  free(runtime->partials);
  free(runtime->statuses);
  native_parallel_scratch_frees +=
      (runtime->shadow_elements == NULL ? UINT64_C(0) : UINT64_C(1)) +
      (runtime->coverage == NULL ? UINT64_C(0) : UINT64_C(1)) +
      (runtime->partials == NULL ? UINT64_C(0) : UINT64_C(1)) +
      (runtime->statuses == NULL ? UINT64_C(0) : UINT64_C(1));
  free(runtime);
}

bool native_parallel_runtime_reserve(native_parallel_runtime *runtime,
                                     int64_t max_elements,
                                     int64_t max_partitions) {
  double *new_shadow = NULL;
  uint8_t *new_coverage = NULL;
  double *new_partials = NULL;
  int32_t *new_statuses = NULL;
  bool grow_elements;
  bool grow_partitions;
  if (runtime == NULL || max_elements < INT64_C(0) ||
      max_partitions < INT64_C(0) ||
      (uint64_t)max_elements > SIZE_MAX / sizeof(double) ||
      (uint64_t)max_elements > SIZE_MAX / sizeof(uint8_t) ||
      (uint64_t)max_partitions > SIZE_MAX / sizeof(double) ||
      (uint64_t)max_partitions > SIZE_MAX / sizeof(int32_t)) {
    return false;
  }
  (void)pthread_mutex_lock(&runtime->mutex);
  if (runtime->active) {
    (void)pthread_mutex_unlock(&runtime->mutex);
    return false;
  }
  grow_elements = max_elements > runtime->element_capacity;
  grow_partitions = max_partitions > runtime->partition_capacity;
  if (grow_elements) {
    new_shadow = (double *)malloc((size_t)max_elements * sizeof(double));
    new_coverage = (uint8_t *)malloc((size_t)max_elements * sizeof(uint8_t));
  }
  if (grow_partitions) {
    new_partials = (double *)malloc((size_t)max_partitions * sizeof(double));
    new_statuses = (int32_t *)malloc((size_t)max_partitions * sizeof(int32_t));
  }
  native_parallel_scratch_allocations +=
      (new_shadow == NULL ? UINT64_C(0) : UINT64_C(1)) +
      (new_coverage == NULL ? UINT64_C(0) : UINT64_C(1)) +
      (new_partials == NULL ? UINT64_C(0) : UINT64_C(1)) +
      (new_statuses == NULL ? UINT64_C(0) : UINT64_C(1));
  if ((grow_elements && (new_shadow == NULL || new_coverage == NULL)) ||
      (grow_partitions && (new_partials == NULL || new_statuses == NULL))) {
    free(new_shadow);
    free(new_coverage);
    free(new_partials);
    free(new_statuses);
    native_parallel_scratch_frees +=
        (new_shadow == NULL ? UINT64_C(0) : UINT64_C(1)) +
        (new_coverage == NULL ? UINT64_C(0) : UINT64_C(1)) +
        (new_partials == NULL ? UINT64_C(0) : UINT64_C(1)) +
        (new_statuses == NULL ? UINT64_C(0) : UINT64_C(1));
    (void)pthread_mutex_unlock(&runtime->mutex);
    return false;
  }
  if (grow_elements) {
    free(runtime->shadow_elements);
    free(runtime->coverage);
    native_parallel_scratch_frees +=
        (runtime->shadow_elements == NULL ? UINT64_C(0) : UINT64_C(1)) +
        (runtime->coverage == NULL ? UINT64_C(0) : UINT64_C(1));
    runtime->shadow_elements = new_shadow;
    runtime->coverage = new_coverage;
    runtime->element_capacity = max_elements;
  }
  if (grow_partitions) {
    free(runtime->partials);
    free(runtime->statuses);
    native_parallel_scratch_frees +=
        (runtime->partials == NULL ? UINT64_C(0) : UINT64_C(1)) +
        (runtime->statuses == NULL ? UINT64_C(0) : UINT64_C(1));
    runtime->partials = new_partials;
    runtime->statuses = new_statuses;
    runtime->partition_capacity = max_partitions;
  }
  (void)pthread_mutex_unlock(&runtime->mutex);
  return true;
}

bool native_parallel_runtime_cancel_next(native_parallel_runtime *runtime) {
  if (runtime == NULL) {
    return false;
  }
  (void)pthread_mutex_lock(&runtime->mutex);
  runtime->cancel_next = true;
  (void)pthread_mutex_unlock(&runtime->mutex);
  return true;
}

static native_parallel_report_v0 native_parallel_run(
    native_parallel_runtime *runtime, native_parallel_job_kind kind,
    const native_arena *arena, const native_buffer *current, native_buffer *next,
    const native_capability *owner, int64_t tile_width, int64_t left_halo,
    int64_t right_halo, native_parallel_boundary_v0 boundary,
    native_parallel_f64_tile_fn_v0 kernel, void *context,
    native_buffer *shadow, int64_t partition_count) {
  int64_t partition;
  native_parallel_report_v0 report;
  (void)pthread_mutex_lock(&runtime->mutex);
  if (runtime->active) {
    (void)pthread_mutex_unlock(&runtime->mutex);
    return native_parallel_report(NATIVE_PARALLEL_RUNTIME_FAILED_V0,
                                  runtime->workers, partition_count,
                                  INT64_C(0), INT64_C(-1), runtime->generation);
  }
  runtime->generation++;
  if (runtime->cancel_next) {
    runtime->cancel_next = false;
    report = native_parallel_report(NATIVE_PARALLEL_CANCELLED_V0,
                                    runtime->workers, partition_count,
                                    INT64_C(0), INT64_C(-1),
                                    runtime->generation);
    (void)pthread_mutex_unlock(&runtime->mutex);
    return report;
  }
  runtime->active = true;
  runtime->stop_claims = false;
  runtime->partition_count = partition_count;
  runtime->next_partition = INT64_C(0);
  runtime->claimed = INT64_C(0);
  runtime->completed = INT64_C(0);
  runtime->lowest_failure = INT64_C(-1);
  runtime->job_kind = kind;
  runtime->arena = arena;
  runtime->current = current;
  runtime->next = next;
  runtime->shadow = shadow;
  runtime->owner = owner;
  runtime->tile_width = tile_width;
  runtime->left_halo = left_halo;
  runtime->right_halo = right_halo;
  runtime->boundary = boundary;
  runtime->kernel = kernel;
  runtime->context = context;
  if (partition_count == INT64_C(0)) {
    runtime->active = false;
    report = native_parallel_report(NATIVE_PARALLEL_OK_V0, runtime->workers,
                                    INT64_C(0), INT64_C(0), INT64_C(-1),
                                    runtime->generation);
    (void)pthread_mutex_unlock(&runtime->mutex);
    return report;
  }
  if (runtime->workers == INT32_C(1)) {
    (void)pthread_mutex_unlock(&runtime->mutex);
    for (partition = 0; partition < partition_count; ++partition) {
      int32_t status = native_parallel_execute_partition(runtime, partition);
      runtime->statuses[partition] = status;
      runtime->claimed++;
      runtime->completed++;
      if (status != 0) {
        runtime->lowest_failure = partition;
        runtime->stop_claims = true;
        break;
      }
    }
    (void)pthread_mutex_lock(&runtime->mutex);
  } else {
    (void)pthread_cond_broadcast(&runtime->start);
    while (!native_parallel_job_done(runtime)) {
      (void)pthread_cond_wait(&runtime->done, &runtime->mutex);
    }
  }
  report = native_parallel_report(
      runtime->lowest_failure < INT64_C(0) ? NATIVE_PARALLEL_OK_V0
                                          : NATIVE_PARALLEL_WORKER_FAILED_V0,
      runtime->workers, partition_count, runtime->completed,
      runtime->lowest_failure, runtime->generation);
  runtime->active = false;
  runtime->job_kind = NATIVE_PARALLEL_JOB_NONE;
  (void)pthread_mutex_unlock(&runtime->mutex);
  return report;
}

native_parallel_report_v0 native_parallel_tiled_step_f64_v0(
    native_parallel_runtime *runtime, const native_arena *arena,
    const native_buffer *current, native_buffer *next,
    const native_capability *owner, int64_t tile_width, int64_t left_halo,
    int64_t right_halo,
    native_parallel_boundary_v0 boundary, native_parallel_f64_tile_fn_v0 kernel,
    void *context) {
  int64_t partitions;
  size_t bytes;
  native_buffer shadow;
  native_parallel_report_v0 report;
  int64_t current_length;
  int64_t next_length;
  int64_t index;
  if (runtime == NULL || arena == NULL || current == NULL || next == NULL ||
      owner == NULL ||
      owner->token == UINT64_C(0) || kernel == NULL || left_halo < INT64_C(0) ||
      right_halo < INT64_C(0) ||
      (boundary != NATIVE_PARALLEL_BOUNDARY_BOUNDED_V0 &&
       boundary != NATIVE_PARALLEL_BOUNDARY_PERIODIC_V0) ||
      left_halo > INT64_MAX - right_halo ||
      tile_width <= INT64_C(0)) {
    return native_parallel_report(NATIVE_PARALLEL_INVALID_V0,
                                  runtime == NULL ? 0 : runtime->workers,
                                  INT64_C(0), INT64_C(0), INT64_C(-1),
                                  runtime == NULL ? UINT64_C(0)
                                                  : runtime->generation);
  }
  current_length = native_buffer_length(arena, current, owner);
  next_length = native_buffer_length(arena, next, owner);
  if (current_length != next_length || current->stride != INT64_C(8) ||
      next->stride != INT64_C(8) ||
      !native_parallel_buffers_disjoint(current, next) ||
      !native_parallel_partition_count(current_length, tile_width,
                                       &partitions) ||
      (current_length > INT64_C(0) &&
       left_halo + right_halo > INT64_MAX - tile_width)) {
    return native_parallel_report(NATIVE_PARALLEL_INVALID_V0, runtime->workers,
                                  INT64_C(0), INT64_C(0), INT64_C(-1),
                                  runtime->generation);
  }
  if ((uint64_t)current_length > SIZE_MAX / sizeof(double) ||
      (uint64_t)partitions > SIZE_MAX / sizeof(int32_t) ||
      !native_parallel_runtime_reserve(runtime, current_length, partitions)) {
    return native_parallel_report(NATIVE_PARALLEL_INVALID_V0, runtime->workers,
                                  partitions, INT64_C(0), INT64_C(-1),
                                  runtime->generation);
  }
  bytes = (size_t)current_length * sizeof(double);
  if (bytes != 0U) {
    memset(runtime->coverage, 0, (size_t)current_length * sizeof(uint8_t));
  }
  if (partitions != INT64_C(0)) {
    memset(runtime->statuses, 0, (size_t)partitions * sizeof(int32_t));
  }
  shadow = *next;
  shadow.elements = runtime->shadow_elements;
  report = native_parallel_run(
      runtime, NATIVE_PARALLEL_JOB_STEP, arena, current, next, owner, tile_width,
      left_halo, right_halo, boundary, kernel, context, &shadow, partitions);
  if (report.outcome == NATIVE_PARALLEL_OK_V0) {
    for (index = 0; index < current_length; ++index) {
      if (runtime->coverage[index] == UINT8_C(0)) {
        report.outcome = NATIVE_PARALLEL_WORKER_FAILED_V0;
        report.failing_partition = index / tile_width;
        break;
      }
    }
    if (report.outcome == NATIVE_PARALLEL_OK_V0 && bytes != 0U) {
      memcpy(next->elements, runtime->shadow_elements, bytes);
    }
  }
  return report;
}

native_parallel_report_v0 native_parallel_f64_buffer_sum_v0(
    native_parallel_runtime *runtime, const native_arena *arena,
    const native_buffer *source, const native_capability *owner,
    int64_t tile_width, double *result) {
  int64_t partitions;
  int64_t source_length;
  native_parallel_report_v0 report;
  int64_t active;
  if (runtime == NULL || arena == NULL || source == NULL || owner == NULL ||
      result == NULL || owner->token == UINT64_C(0) ||
      tile_width <= INT64_C(0)) {
    return native_parallel_report(NATIVE_PARALLEL_INVALID_V0,
                                  runtime == NULL ? 0 : runtime->workers,
                                  INT64_C(0), INT64_C(0), INT64_C(-1),
                                  runtime == NULL ? UINT64_C(0)
                                                  : runtime->generation);
  }
  source_length = native_buffer_length(arena, source, owner);
  if (source->stride != INT64_C(8) ||
      !native_parallel_partition_count(source_length, tile_width, &partitions) ||
      (uint64_t)partitions > SIZE_MAX / sizeof(double) ||
      (uint64_t)partitions > SIZE_MAX / sizeof(int32_t) ||
      !native_parallel_runtime_reserve(runtime, INT64_C(0), partitions)) {
    return native_parallel_report(NATIVE_PARALLEL_INVALID_V0,
                                  runtime == NULL ? 0 : runtime->workers,
                                  INT64_C(0), INT64_C(0), INT64_C(-1),
                                  runtime == NULL ? UINT64_C(0)
                                                  : runtime->generation);
  }
  if (partitions == INT64_C(0)) {
    *result = 0.0;
  } else {
    memset(runtime->statuses, 0, (size_t)partitions * sizeof(int32_t));
  }
  report = native_parallel_run(
      runtime, NATIVE_PARALLEL_JOB_SUM, arena, source, NULL, owner, tile_width,
      INT64_C(0), INT64_C(0), NATIVE_PARALLEL_BOUNDARY_BOUNDED_V0, NULL, NULL,
      NULL, partitions);
  if (report.outcome == NATIVE_PARALLEL_OK_V0 && partitions != INT64_C(0)) {
    active = partitions;
    while (active > INT64_C(1)) {
      int64_t read;
      int64_t write = INT64_C(0);
      for (read = INT64_C(0); read < active; read += INT64_C(2)) {
        if (read + INT64_C(1) < active) {
          runtime->partials[write++] =
              runtime->partials[read] + runtime->partials[read + INT64_C(1)];
        } else {
          runtime->partials[write++] = runtime->partials[read];
        }
      }
      active = write;
    }
    *result = runtime->partials[0];
  }
  return report;
}

static pthread_mutex_t native_parallel_default_mutex = PTHREAD_MUTEX_INITIALIZER;
static native_parallel_runtime *native_parallel_default_runtime = NULL;
static int32_t native_parallel_default_workers = INT32_C(1);
static bool native_parallel_default_registered = false;

static void native_parallel_destroy_default(void) {
  native_parallel_runtime *runtime;
  (void)pthread_mutex_lock(&native_parallel_default_mutex);
  runtime = native_parallel_default_runtime;
  native_parallel_default_runtime = NULL;
  (void)pthread_mutex_unlock(&native_parallel_default_mutex);
  native_parallel_runtime_destroy(runtime);
}

bool native_parallel_configure_default_workers(int32_t workers) {
  bool accepted;
  if (!native_parallel_valid_workers(workers)) {
    return false;
  }
  (void)pthread_mutex_lock(&native_parallel_default_mutex);
  accepted = native_parallel_default_runtime == NULL;
  if (accepted) {
    native_parallel_default_workers = workers;
  }
  (void)pthread_mutex_unlock(&native_parallel_default_mutex);
  return accepted;
}

static native_parallel_runtime *native_parallel_get_default(void) {
  native_parallel_runtime *runtime;
  (void)pthread_mutex_lock(&native_parallel_default_mutex);
  if (native_parallel_default_runtime == NULL) {
    native_parallel_default_runtime =
        native_parallel_runtime_create(native_parallel_default_workers);
    if (native_parallel_default_runtime != NULL &&
        !native_parallel_default_registered) {
      native_parallel_default_registered = atexit(native_parallel_destroy_default) == 0;
    }
  }
  runtime = native_parallel_default_runtime;
  (void)pthread_mutex_unlock(&native_parallel_default_mutex);
  return runtime;
}

native_parallel_report_v0 native_parallel_tiled_step_f64_default_v0(
    const native_arena *arena, const native_buffer *current,
    native_buffer *next, const native_capability *owner, int64_t tile_width,
    int64_t left_halo, int64_t right_halo, native_parallel_boundary_v0 boundary,
    native_parallel_f64_tile_fn_v0 kernel, void *context) {
  native_parallel_runtime *runtime = native_parallel_get_default();
  if (runtime == NULL) {
    return native_parallel_report(NATIVE_PARALLEL_RUNTIME_FAILED_V0, 0,
                                  INT64_C(0), INT64_C(0), INT64_C(-1),
                                  UINT64_C(0));
  }
  return native_parallel_tiled_step_f64_v0(
      runtime, arena, current, next, owner, tile_width, left_halo, right_halo,
      boundary, kernel, context);
}

native_parallel_report_v0 native_parallel_f64_buffer_sum_default_v0(
    const native_arena *arena, const native_buffer *source,
    const native_capability *owner, int64_t tile_width, double *result) {
  native_parallel_runtime *runtime = native_parallel_get_default();
  if (runtime == NULL) {
    return native_parallel_report(NATIVE_PARALLEL_RUNTIME_FAILED_V0, 0,
                                  INT64_C(0), INT64_C(0), INT64_C(-1),
                                  UINT64_C(0));
  }
  return native_parallel_f64_buffer_sum_v0(runtime, arena, source, owner,
                                           tile_width, result);
}
