// SPDX-License-Identifier: MIT OR Apache-2.0
#define _GNU_SOURCE

#include "server_host.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

enum {
  DEFAULT_PORT = 7977,
  INHERITED_LISTEN_FD = 3,
  LISTEN_BACKLOG = 128,
  /* INVARIANT: the app-level admission cap must sit well BELOW every task or
     thread limit the supervisor imposes -- systemd TasksMax, cgroup pids.max,
     RLIMIT_NPROC. One worker thread is created per admitted client, so a cap
     equal to the task limit means the cgroup refuses the thread before this
     graceful refusal path can ever engage. That is exactly how the coordinator
     wedged on 2026-08-09: MAX_ACTIVE_CLIENTS was 128 and the unit's TasksMax
     was 128, so the first over-cap connection produced a fatal pthread_create
     EAGAIN instead of a polite refusal. 64 leaves headroom for the acceptor,
     the supervisor's own tasks, and transient over-subscription under a unit
     sized for 128 tasks. BEAGLE_STORE_MAX_ACTIVE_CLIENTS -- or the deployment's
     existing BEAGLE_STORE_CONNECTION_WORKERS -- moves it deliberately; keep any
     configured value below the unit's TasksMax. */
  DEFAULT_MAX_ACTIVE_CLIENTS = 64,
  MIN_ACTIVE_CLIENTS = 1,
  MAX_ACTIVE_CLIENTS_CEILING = 4096,
  /* No worker may block on a peer forever: a stalled read or write must
     release its slot, its arena, and its thread instead of parking the socket
     in CLOSE_WAIT for the life of the process. 0 disables the bound. */
  DEFAULT_CLIENT_IO_TIMEOUT_MS = 15000,
  MAX_CLIENT_IO_TIMEOUT_MS = 3600000,
  ACCEPT_POLL_MILLISECONDS = 100,
  /* Keeps the acceptor from spinning accept->create->fail while the process is
     at its thread ceiling. */
  ACCEPT_PRESSURE_BACKOFF_MILLISECONDS = 10,
  /* Compaction is the only thing that hands a generation chain's arenas back
     to the allocator, and it used to ride only on a request -- so a server
     that stopped being written to parked on whatever peak its last write left
     and held it indefinitely. The acceptor's own poll timeout is already an
     exact quiet clock, and the client table already says whether anything is
     in flight; this many consecutive empty polls with no live client is the
     trigger. Long enough that a burst's inter-arrival gaps do not pay for a
     replay, short enough that a genuinely idle server settles in seconds. */
  IDLE_COMPACT_QUIET_POLLS = 20,
  /* A generation chain's arena chunks double as they grow, so the ones that
     hold the fold are large -- and a large chunk that came off the main heap
     can only be returned if nothing above it is live. Under a write soak the
     compacted generation ends up interleaved with the freed chain, and the
     process keeps ~190 MB it no longer uses. Placing chunks at or above this
     size in their own mappings makes free() a munmap, so the chain leaves
     when it is dropped rather than when the heap top happens to clear.
     glibc's own starting threshold; pinning it also stops the dynamic
     adjustment from raising it back out of the arena's range. */
  ARENA_MMAP_THRESHOLD_BYTES = 131072
};

typedef enum server_bind {
  SERVER_BIND_LOOPBACK,
  SERVER_BIND_IPV4_LOOPBACK,
  SERVER_BIND_ANY
} server_bind;

typedef struct server_config {
  uint16_t port;
  const char *log_path;
  const char *space_id;
  server_bind bind;
  const char *bind_text;
  uint64_t memory_budget_bytes;
  size_t max_active_clients;
  long client_io_timeout_ms;
} server_config;

typedef struct writer_authority {
  int fd;
  char *canonical_log_path;
  char *lock_path;
} writer_authority;

typedef struct server_context server_context;

typedef struct client_job {
  int fd;
  server_context *server;
  struct client_job *next;
} client_job;

struct server_context {
  store_server_store *store;
  pthread_mutex_t dispatch_mutex;
  pthread_mutex_t clients_mutex;
  pthread_cond_t clients_idle;
  pthread_attr_t worker_attributes;
  client_job *clients;
  size_t client_count;
  size_t max_active_clients;
  bool fatal;
};

/* Refusals arrive in storms, and one line per refused connection is itself a
   denial of service against the journal. */
typedef struct report_throttle {
  time_t last_report_seconds;
  unsigned long suppressed;
  bool reported;
} report_throttle;

static volatile sig_atomic_t stop_requested = 0;

static void report_throttled(report_throttle *state, const char *message) {
  struct timespec now;
  time_t seconds = 0;

  if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
    seconds = now.tv_sec;
  }
  if (state->reported && seconds - state->last_report_seconds < (time_t)1) {
    state->suppressed += 1uL;
    return;
  }
  if (state->suppressed != 0uL) {
    fprintf(stderr, "beagle-store-server-native: %s (%lu more suppressed)\n", message,
            state->suppressed);
  } else {
    fprintf(stderr, "beagle-store-server-native: %s\n", message);
  }
  state->suppressed = 0uL;
  state->last_report_seconds = seconds;
  state->reported = true;
}

static void accept_pressure_backoff(void) {
  struct timespec delay;

  delay.tv_sec = 0;
  delay.tv_nsec = (long)ACCEPT_PRESSURE_BACKOFF_MILLISECONDS * 1000000L;
  (void)nanosleep(&delay, NULL);
}

/* A minimal sd_notify(3): the service-manager contract is one AF_UNIX datagram
   to $NOTIFY_SOCKET, so the host speaks it directly rather than taking a
   libsystemd link dependency this tree does not otherwise have. Outside
   systemd NOTIFY_SOCKET is unset and every call is a no-op. */
static void notify_service_manager(const char *state) {
  const char *socket_path = getenv("NOTIFY_SOCKET");
  struct sockaddr_un address;
  size_t path_length;
  size_t address_length;
  int fd;

  if (socket_path == NULL || socket_path[0] == '\0') {
    return;
  }
  if (socket_path[0] != '/' && socket_path[0] != '@') {
    fprintf(stderr,
            "beagle-store-server-native: ignoring unsupported NOTIFY_SOCKET=%s\n",
            socket_path);
    return;
  }
  path_length = strlen(socket_path);
  if (path_length >= sizeof(address.sun_path)) {
    fputs("beagle-store-server-native: NOTIFY_SOCKET path is too long\n", stderr);
    return;
  }
  fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot open the notify socket: %s\n",
            strerror(errno));
    return;
  }
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, socket_path, path_length);
  address_length = offsetof(struct sockaddr_un, sun_path) + path_length;
  if (socket_path[0] == '@') {
    /* Abstract namespace: a leading NUL, and no terminator in the length. */
    address.sun_path[0] = '\0';
  } else {
    address_length += 1u;
  }
  if (sendto(fd, state, strlen(state), MSG_NOSIGNAL,
             (const struct sockaddr *)&address,
             (socklen_t)address_length) < 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot notify the service manager: %s\n",
            strerror(errno));
  }
  (void)close(fd);
}

static void print_usage(void) {
  fputs("usage: beagle-store-server-native [serve] [port] [log] [space-id]\n",
        stderr);
}

static bool nonempty(const char *value) {
  return value != NULL && value[0] != '\0';
}

static int parse_port(const char *text, uint16_t *port_out) {
  char *end = NULL;
  long value;

  errno = 0;
  value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value < 1 || value > 65535) {
    fprintf(stderr, "beagle-store-server-native: invalid port: %s\n", text);
    return -1;
  }
  *port_out = (uint16_t)value;
  return 0;
}

static int parse_env_bounded(const char *name, long minimum, long maximum,
                             long fallback, long *value_out) {
  const char *text = getenv(name);
  char *end = NULL;
  long value;

  if (!nonempty(text)) {
    *value_out = fallback;
    return 0;
  }
  errno = 0;
  value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value < minimum ||
      value > maximum) {
    fprintf(stderr,
            "beagle-store-server-native: %s must be an integer in [%ld, %ld], got %s\n",
            name, minimum, maximum, text);
    return -1;
  }
  *value_out = value;
  return 0;
}

/* BEAGLE_STORE_CONNECTION_WORKERS is what deployed units already set; honoring it here
   is the whole point -- the accept path ignored it before 2026-08-09.
   BEAGLE_STORE_MAX_ACTIVE_CLIENTS names the same bound unambiguously and wins. */
static int parse_admission(server_config *config) {
  const char *cap_variable = nonempty(getenv("BEAGLE_STORE_MAX_ACTIVE_CLIENTS"))
                                 ? "BEAGLE_STORE_MAX_ACTIVE_CLIENTS"
                                 : "BEAGLE_STORE_CONNECTION_WORKERS";
  long cap;
  long timeout_ms;

  if (parse_env_bounded(cap_variable, MIN_ACTIVE_CLIENTS,
                        MAX_ACTIVE_CLIENTS_CEILING,
                        DEFAULT_MAX_ACTIVE_CLIENTS, &cap) != 0) {
    return -1;
  }
  if (parse_env_bounded("BEAGLE_STORE_CLIENT_IO_TIMEOUT_MS", 0,
                        MAX_CLIENT_IO_TIMEOUT_MS, DEFAULT_CLIENT_IO_TIMEOUT_MS,
                        &timeout_ms) != 0) {
    return -1;
  }
  config->max_active_clients = (size_t)cap;
  config->client_io_timeout_ms = timeout_ms;
  return 0;
}

static int parse_bind(server_config *config) {
  const char *bind = getenv("BEAGLE_STORE_BIND");

  if (!nonempty(bind) || strcmp(bind, "loopback") == 0) {
    config->bind = SERVER_BIND_LOOPBACK;
    config->bind_text = "127.0.0.1";
    return 0;
  }
  if (strcmp(bind, "127.0.0.1") == 0) {
    config->bind = SERVER_BIND_IPV4_LOOPBACK;
    config->bind_text = "127.0.0.1";
    return 0;
  }
  if (strcmp(bind, "0.0.0.0") == 0) {
    config->bind = SERVER_BIND_ANY;
    config->bind_text = "0.0.0.0";
    return 0;
  }
  fprintf(stderr,
          "beagle-store-server-native: BEAGLE_STORE_BIND=%s is unsupported; expected "
          "loopback, 127.0.0.1, or 0.0.0.0\n",
          bind);
  return -1;
}

static int load_config(int argc, char **argv, server_config *config) {
  int index = 1;
  const char *port_text;
  const char *log_path;
  const char *space_id;
  const char *budget_text;

  if (index < argc && strcmp(argv[index], "serve") == 0) {
    index += 1;
  }
  if (argc - index > 3) {
    print_usage();
    return -1;
  }

  port_text = index < argc && nonempty(argv[index])
                  ? argv[index]
                  : getenv("BEAGLE_STORE_SERVER_PORT");
  if (!nonempty(port_text)) {
    config->port = DEFAULT_PORT;
  } else {
    if (parse_port(port_text, &config->port) != 0) {
      return -1;
    }
  }

  log_path = index + 1 < argc && nonempty(argv[index + 1])
                 ? argv[index + 1]
                 : getenv("BEAGLE_STORE_LOG");
  config->log_path = nonempty(log_path) ? log_path : "coordination.log";

  space_id = index + 2 < argc && nonempty(argv[index + 2])
                 ? argv[index + 2]
                 : getenv("BEAGLE_STORE_SPACE_ID");
  config->space_id = nonempty(space_id) ? space_id : NULL;

  budget_text = getenv("BEAGLE_STORE_MEMORY_BUDGET_BYTES");
  config->memory_budget_bytes = UINT64_C(0);
  if (nonempty(budget_text)) {
    char *end = NULL;
    unsigned long long parsed;

    errno = 0;
    parsed = strtoull(budget_text, &end, 10);
    if (errno != 0 || end == budget_text || *end != '\0') {
      fprintf(stderr,
              "beagle-store-server-native: BEAGLE_STORE_MEMORY_BUDGET_BYTES is not a byte "
              "count\n");
      return -1;
    }
    config->memory_budget_bytes = (uint64_t)parsed;
  }
  if (parse_admission(config) != 0) {
    return -1;
  }
  return parse_bind(config);
}

static int reject_unsupported_environment(void) {
  static const char *const tls_variables[] = {
      "BEAGLE_STORE_TLS_KEYSTORE", "BEAGLE_STORE_TLS_TRUSTSTORE", "BEAGLE_STORE_TLS_PASS",
      "BEAGLE_STORE_TLS_PASS_FILE"};
  const char *role = getenv("BEAGLE_STORE_SERVER_ROLE");
  size_t index;

  for (index = 0; index < sizeof(tls_variables) / sizeof(tls_variables[0]);
       index += 1) {
    if (nonempty(getenv(tls_variables[index]))) {
      fprintf(stderr,
              "beagle-store-server-native: %s is unsupported by the deployed native "
              "host; refusing plaintext fallback\n",
              tls_variables[index]);
      return -1;
    }
  }
  if (nonempty(role) && strcmp(role, "active") != 0) {
    fprintf(stderr,
            "beagle-store-server-native: BEAGLE_STORE_SERVER_ROLE=%s is unsupported; this host "
            "requires active writer authority\n",
            role);
    return -1;
  }
  return 0;
}

static void handle_stop_signal(int signal_number) {
  (void)signal_number;
  stop_requested = 1;
}

static int install_signal_handlers(void) {
  struct sigaction action;

  memset(&action, 0, sizeof(action));
  action.sa_handler = handle_stop_signal;
  if (sigemptyset(&action.sa_mask) != 0 ||
      sigaction(SIGINT, &action, NULL) != 0 ||
      sigaction(SIGTERM, &action, NULL) != 0 || signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
    fprintf(stderr, "beagle-store-server-native: cannot install signal handlers: %s\n",
            strerror(errno));
    return -1;
  }
  return 0;
}

static void release_writer_authority(writer_authority *authority) {
  if (authority->fd >= 0) {
    (void)close(authority->fd);
  }
  free(authority->canonical_log_path);
  free(authority->lock_path);
  authority->fd = -1;
  authority->canonical_log_path = NULL;
  authority->lock_path = NULL;
}

static int ensure_regular_log(const char *path) {
  struct stat status;
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0666);

  if (fd < 0) {
    fprintf(stderr, "beagle-store-server-native: cannot open log %s: %s\n", path,
            strerror(errno));
    return -1;
  }
  if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode)) {
    fprintf(stderr, "beagle-store-server-native: log is not a regular file: %s\n", path);
    (void)close(fd);
    return -1;
  }
  if (close(fd) != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot close log %s: %s\n", path,
            strerror(errno));
    return -1;
  }
  return 0;
}

static int acquire_writer_authority(const char *log_path,
                                    writer_authority *authority) {
  struct flock lock;
  struct stat status;
  size_t lock_path_size;
  int lock_fd;

  if (ensure_regular_log(log_path) != 0) {
    return -1;
  }
  authority->canonical_log_path = realpath(log_path, NULL);
  if (authority->canonical_log_path == NULL) {
    fprintf(stderr, "beagle-store-server-native: cannot canonicalize log %s: %s\n",
            log_path, strerror(errno));
    return -1;
  }

  lock_path_size = strlen(authority->canonical_log_path) +
                   sizeof(".writer-authority.lock");
  authority->lock_path = malloc(lock_path_size);
  if (authority->lock_path == NULL) {
    fputs("beagle-store-server-native: cannot allocate writer lock path\n", stderr);
    return -1;
  }
  (void)snprintf(authority->lock_path, lock_path_size, "%s.writer-authority.lock",
                 authority->canonical_log_path);

  if (lstat(authority->lock_path, &status) == 0) {
    if (S_ISLNK(status.st_mode)) {
      fprintf(stderr,
              "beagle-store-server-native: writer authority path is a symlink: %s\n",
              authority->lock_path);
      return -1;
    }
  } else if (errno != ENOENT) {
    fprintf(stderr, "beagle-store-server-native: cannot inspect writer lock %s: %s\n",
            authority->lock_path, strerror(errno));
    return -1;
  }

  lock_fd = open(authority->lock_path,
                 O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0666);
  if (lock_fd < 0) {
    fprintf(stderr, "beagle-store-server-native: cannot open writer lock %s: %s\n",
            authority->lock_path, strerror(errno));
    return -1;
  }
  if (fstat(lock_fd, &status) != 0 || !S_ISREG(status.st_mode)) {
    fprintf(stderr, "beagle-store-server-native: writer lock is not a regular file: %s\n",
            authority->lock_path);
    (void)close(lock_fd);
    return -1;
  }

  memset(&lock, 0, sizeof(lock));
  lock.l_type = F_WRLCK;
  lock.l_whence = SEEK_SET;
  // FileChannel.tryLock uses fcntl locks; flock would not fence the live JVM.
  if (fcntl(lock_fd, F_SETLK, &lock) != 0) {
    if (errno == EACCES || errno == EAGAIN) {
      fprintf(stderr,
              "beagle-store-server-native: another server holds writer authority "
              "for %s\n",
              authority->canonical_log_path);
    } else {
      fprintf(stderr, "beagle-store-server-native: cannot lock %s: %s\n",
              authority->lock_path, strerror(errno));
    }
    (void)close(lock_fd);
    return -1;
  }
  authority->fd = lock_fd;
  return 0;
}

/* True only for a freshly accepted connection that carries no request bytes at
   all and is already at end-of-file (or reset): nothing was ever asked, so
   nothing is owed. This deliberately runs BEFORE any byte is read -- a client
   that half-closes after sending still has its request queued here, so the
   peek reports data, not end-of-file, and the connection is admitted. */
static bool peer_never_asked(int fd) {
  char probe;
  ssize_t count = recv(fd, &probe, sizeof(probe), MSG_PEEK | MSG_DONTWAIT);

  if (count > 0) {
    return false;
  }
  if (count == 0) {
    return true;
  }
  return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR;
}

static int set_client_io_timeouts(int fd, long timeout_ms) {
  struct timeval timeout;

  if (timeout_ms <= 0) {
    return 0;
  }
  timeout.tv_sec = (time_t)(timeout_ms / 1000L);
  timeout.tv_usec = (suseconds_t)((timeout_ms % 1000L) * 1000L);
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) {
    return -1;
  }
  return 0;
}

static int set_close_on_exec(int fd) {
  int flags = fcntl(fd, F_GETFD);

  if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0) {
    return -1;
  }
  return 0;
}

static int parse_inherited_fd(void) {
  const char *text = getenv("BEAGLE_STORE_LISTEN_FD");
  char *end = NULL;
  long value;

  if (text == NULL) {
    return -1;
  }
  errno = 0;
  value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value != INHERITED_LISTEN_FD) {
    fprintf(stderr,
            "beagle-store-server-native: BEAGLE_STORE_LISTEN_FD must be exactly %d, got %s\n",
            INHERITED_LISTEN_FD, text);
    return -2;
  }
  return INHERITED_LISTEN_FD;
}

static int inherited_socket_port(int fd, server_bind bind_mode,
                                 uint16_t *port_out) {
  struct sockaddr_storage address;
  socklen_t address_length = sizeof(address);

  memset(&address, 0, sizeof(address));
  if (getsockname(fd, (struct sockaddr *)&address, &address_length) != 0) {
    return -1;
  }
  if (address.ss_family == AF_INET) {
    const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)&address;
    uint32_t expected =
        bind_mode == SERVER_BIND_ANY ? INADDR_ANY : INADDR_LOOPBACK;
    if (ntohl(ipv4->sin_addr.s_addr) != expected) {
      errno = EADDRNOTAVAIL;
      return -1;
    }
    *port_out = ntohs(ipv4->sin_port);
    return 0;
  }
  if (address.ss_family == AF_INET6) {
    const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)&address;
    if (bind_mode != SERVER_BIND_LOOPBACK ||
        !IN6_IS_ADDR_LOOPBACK(&ipv6->sin6_addr)) {
      errno = EADDRNOTAVAIL;
      return -1;
    }
    *port_out = ntohs(ipv6->sin6_port);
    return 0;
  }
  errno = EAFNOSUPPORT;
  return -1;
}

static int validate_inherited_socket(int fd, const server_config *config) {
  int socket_type = 0;
  int accepting = 0;
  socklen_t option_length = sizeof(socket_type);
  uint16_t actual_port = 0;

  if (fcntl(fd, F_GETFD) < 0 ||
      getsockopt(fd, SOL_SOCKET, SO_TYPE, &socket_type, &option_length) != 0 ||
      socket_type != SOCK_STREAM) {
    fprintf(stderr,
            "beagle-store-server-native: BEAGLE_STORE_LISTEN_FD=%d is not an open stream socket\n",
            fd);
    return -1;
  }
  option_length = sizeof(accepting);
  if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &option_length) != 0 ||
      accepting == 0) {
    fprintf(stderr,
            "beagle-store-server-native: BEAGLE_STORE_LISTEN_FD=%d is not a listening socket\n",
            fd);
    return -1;
  }
  if (inherited_socket_port(fd, config->bind, &actual_port) != 0) {
    fprintf(stderr,
            "beagle-store-server-native: inherited listener does not match "
            "BEAGLE_STORE_BIND=%s: %s\n",
            config->bind_text, strerror(errno));
    return -1;
  }
  if (actual_port != config->port) {
    fprintf(stderr,
            "beagle-store-server-native: inherited listener port %u does not match "
            "BEAGLE_STORE_SERVER_PORT %u\n",
            (unsigned int)actual_port, (unsigned int)config->port);
    return -1;
  }
  if (set_close_on_exec(fd) != 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot set close-on-exec on inherited listener: "
            "%s\n",
            strerror(errno));
    return -1;
  }
  return 0;
}

static int create_listener(const server_config *config) {
  struct sockaddr_in address;
  int reuse = 1;
  int fd = socket(AF_INET, SOCK_STREAM, 0);

  if (fd < 0) {
    fprintf(stderr, "beagle-store-server-native: cannot create listener: %s\n",
            strerror(errno));
    return -1;
  }
  if (set_close_on_exec(fd) != 0 ||
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot configure listener: %s\n",
            strerror(errno));
    (void)close(fd);
    return -1;
  }

  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(config->bind == SERVER_BIND_ANY
                                      ? INADDR_ANY
                                      : INADDR_LOOPBACK);
  address.sin_port = htons(config->port);
  if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
      listen(fd, LISTEN_BACKLOG) != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot listen on %s:%u: %s\n",
            config->bind_text, (unsigned int)config->port, strerror(errno));
    (void)close(fd);
    return -1;
  }
  return fd;
}

static int open_listener(const server_config *config) {
  int inherited_fd = parse_inherited_fd();

  if (inherited_fd == -2) {
    return -1;
  }
  if (inherited_fd >= 0) {
    if (validate_inherited_socket(inherited_fd, config) != 0) {
      return -1;
    }
    return inherited_fd;
  }
  return create_listener(config);
}

static const char *hook_detail(const char *error) {
  return nonempty(error) ? error : "generated hook returned no detail";
}

static void terminate_hook_error(char *error) {
  error[BEAGLE_STORE_SERVER_ERROR_CAPACITY - 1u] = '\0';
}

static int serialized_dispatch(
    server_context *server, const store_server_request *request,
    store_server_response **response, char *error,
    size_t error_capacity) {
  int thread_status = pthread_mutex_lock(&server->dispatch_mutex);
  int hook_status;

  if (thread_status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot lock dispatch: %s\n",
            strerror(thread_status));
    return BEAGLE_STORE_SERVER_FATAL;
  }
  hook_status = store_server_store_dispatch(
      server->store, request, response, error, error_capacity);
  thread_status = pthread_mutex_unlock(&server->dispatch_mutex);
  if (thread_status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot unlock dispatch: %s\n",
            strerror(thread_status));
    return BEAGLE_STORE_SERVER_FATAL;
  }
  return hook_status;
}

static int serialized_release_response(
    server_context *server, store_server_response *response) {
  int thread_status = pthread_mutex_lock(&server->dispatch_mutex);

  if (thread_status != 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot lock response release: %s\n",
            strerror(thread_status));
    return -1;
  }
  store_server_codec_release_response(response);
  thread_status = pthread_mutex_unlock(&server->dispatch_mutex);
  if (thread_status != 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot unlock response release: %s\n",
            strerror(thread_status));
    return -1;
  }
  return 0;
}

static int serve_client(int client_fd, server_context *server) {
  char error[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  store_server_request *request = NULL;
  store_server_response *response = NULL;
  int status;
  int release_status;

  error[0] = '\0';
  status = store_server_codec_read_request(
      client_fd, &request, error, sizeof(error));
  terminate_hook_error(error);
  if (status == BEAGLE_STORE_SERVER_PEER_CLOSED && request == NULL) {
    return 0;
  }
  if (status == BEAGLE_STORE_SERVER_CLIENT_ERROR) {
    fprintf(stderr,
            "beagle-store-server-native: store_server_codec_read_request failed "
            "(%d): %s\n",
            status, hook_detail(error));
    if (request != NULL) {
      store_server_codec_release_request(request);
    }
    return 0;
  }
  if (status != BEAGLE_STORE_SERVER_OK || request == NULL) {
    fprintf(stderr,
            "beagle-store-server-native: store_server_codec_read_request failed "
            "(%d): %s\n",
            status, hook_detail(error));
    if (request != NULL) {
      store_server_codec_release_request(request);
    }
    return -1;
  }

  /* No peer-liveness check belongs here. A Store RPC client may half-close
     (shutdown(SHUT_WR)) once its request is on the wire and then wait for the
     response -- tests/store_native_generated_adapter_smoke.sh does exactly
     that -- and at the socket layer a half-close is indistinguishable from a
     full close: both leave this end in CLOSE_WAIT with no pending error.
     Abandoning the request here would silently break every half-closing
     client. A worker that has read a complete request always dispatches it;
     what bounds the cost of a peer that has really gone is the send timeout
     on the response write, plus the admission cap. */

  error[0] = '\0';
  status = serialized_dispatch(server, request, &response, error,
                               sizeof(error));
  terminate_hook_error(error);
  store_server_codec_release_request(request);
  if (status != BEAGLE_STORE_SERVER_OK || response == NULL) {
    fprintf(stderr,
            "beagle-store-server-native: store_server_store_dispatch failed (%d): "
            "%s\n",
            status, hook_detail(error));
    if (response != NULL) {
      if (serialized_release_response(server, response) != 0) {
        return -1;
      }
    }
    return -1;
  }

  error[0] = '\0';
  status = store_server_codec_write_response(client_fd, response, error,
                                                sizeof(error));
  terminate_hook_error(error);
  release_status = serialized_release_response(server, response);
  if (release_status != 0) {
    return -1;
  }
  if (status == BEAGLE_STORE_SERVER_PEER_CLOSED) {
    return 0;
  }
  if (status == BEAGLE_STORE_SERVER_CLIENT_ERROR) {
    fprintf(stderr,
            "beagle-store-server-native: store_server_codec_write_response failed "
            "(%d): %s\n",
            status, hook_detail(error));
    return 0;
  }
  if (status != BEAGLE_STORE_SERVER_OK) {
    fprintf(stderr,
            "beagle-store-server-native: store_server_codec_write_response failed "
            "(%d): %s\n",
            status, hook_detail(error));
    return -1;
  }
  return 0;
}

static int initialize_server_context(server_context *server,
                                     store_server_store *store) {
  int status;

  memset(server, 0, sizeof(*server));
  server->store = store;
  status = pthread_mutex_init(&server->dispatch_mutex, NULL);
  if (status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot initialize dispatch lock: %s\n",
            strerror(status));
    return -1;
  }
  status = pthread_mutex_init(&server->clients_mutex, NULL);
  if (status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot initialize client lock: %s\n",
            strerror(status));
    (void)pthread_mutex_destroy(&server->dispatch_mutex);
    return -1;
  }
  status = pthread_cond_init(&server->clients_idle, NULL);
  if (status != 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot initialize client condition: %s\n",
            strerror(status));
    (void)pthread_mutex_destroy(&server->clients_mutex);
    (void)pthread_mutex_destroy(&server->dispatch_mutex);
    return -1;
  }
  status = pthread_attr_init(&server->worker_attributes);
  if (status != 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot initialize worker attributes: %s\n",
            strerror(status));
    (void)pthread_cond_destroy(&server->clients_idle);
    (void)pthread_mutex_destroy(&server->clients_mutex);
    (void)pthread_mutex_destroy(&server->dispatch_mutex);
    return -1;
  }
  status = pthread_attr_setdetachstate(&server->worker_attributes,
                                       PTHREAD_CREATE_DETACHED);
  if (status != 0) {
    fprintf(stderr,
            "beagle-store-server-native: cannot configure worker attributes: %s\n",
            strerror(status));
    (void)pthread_attr_destroy(&server->worker_attributes);
    (void)pthread_cond_destroy(&server->clients_idle);
    (void)pthread_mutex_destroy(&server->clients_mutex);
    (void)pthread_mutex_destroy(&server->dispatch_mutex);
    return -1;
  }
  /* musl defaults workers to 128 KiB; compaction replays the full log on a
     worker. */
  status = pthread_attr_setstacksize(&server->worker_attributes,
                                     (size_t)8u * 1024u * 1024u);
  if (status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot size worker stacks: %s\n",
            strerror(status));
    (void)pthread_attr_destroy(&server->worker_attributes);
    (void)pthread_cond_destroy(&server->clients_idle);
    (void)pthread_mutex_destroy(&server->clients_mutex);
    (void)pthread_mutex_destroy(&server->dispatch_mutex);
    return -1;
  }
  return 0;
}

static void destroy_server_context(server_context *server) {
  (void)pthread_attr_destroy(&server->worker_attributes);
  (void)pthread_cond_destroy(&server->clients_idle);
  (void)pthread_mutex_destroy(&server->clients_mutex);
  (void)pthread_mutex_destroy(&server->dispatch_mutex);
}

static bool server_has_fatal_failure(server_context *server) {
  bool fatal;

  (void)pthread_mutex_lock(&server->clients_mutex);
  fatal = server->fatal;
  (void)pthread_mutex_unlock(&server->clients_mutex);
  return fatal;
}

static bool server_has_live_client(server_context *server) {
  bool live;

  (void)pthread_mutex_lock(&server->clients_mutex);
  live = server->client_count != (size_t)0u;
  (void)pthread_mutex_unlock(&server->clients_mutex);
  return live;
}

/* Runs on the acceptor with no client admitted, so the dispatch mutex is taken
   uncontended and a request that arrives mid-replay waits exactly as it would
   behind any other write. */
static int compact_while_quiet(server_context *server) {
  char error[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  int compacted = 0;
  int hook_status;
  int thread_status = pthread_mutex_lock(&server->dispatch_mutex);

  if (thread_status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot lock idle compaction: %s\n",
            strerror(thread_status));
    return -1;
  }
  hook_status = store_server_store_compact_idle(server->store, &compacted,
                                               error, sizeof(error));
  thread_status = pthread_mutex_unlock(&server->dispatch_mutex);
  if (thread_status != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot unlock idle compaction: %s\n",
            strerror(thread_status));
    return -1;
  }
  if (hook_status != BEAGLE_STORE_SERVER_OK) {
    terminate_hook_error(error);
    fprintf(stderr, "beagle-store-server-native: idle compaction failed: %s\n",
            hook_detail(error));
    return -1;
  }
#if defined(__GLIBC__)
  /* Freeing the old generation chain is not the same as giving it back: its
     arena chunks are malloc'd and mostly land on the main heap rather than in
     their own mmaps, so without this the process holds the compaction's
     high-water mark -- both the new generation and the freed chain -- and an
     idle server's RSS reports the peak rather than the compacted size. Only
     the call that actually did the work pays for the heap walk. */
  if (compacted != 0) {
    (void)malloc_trim(0);
  }
#endif
  return 0;
}

static void remove_client_locked(server_context *server, client_job *job) {
  client_job **cursor = &server->clients;

  while (*cursor != NULL && *cursor != job) {
    cursor = &(*cursor)->next;
  }
  if (*cursor == job) {
    *cursor = job->next;
    server->client_count -= 1u;
  }
}

static void *serve_client_worker(void *argument) {
  client_job *job = argument;
  server_context *server = job->server;
  bool fatal = serve_client(job->fd, server) != 0;

  (void)pthread_mutex_lock(&server->clients_mutex);
  if (close(job->fd) != 0) {
    fprintf(stderr, "beagle-store-server-native: cannot close client: %s\n",
            strerror(errno));
  }
  job->fd = -1;
  if (fatal) {
    server->fatal = true;
  }
  remove_client_locked(server, job);
  (void)pthread_cond_broadcast(&server->clients_idle);
  (void)pthread_mutex_unlock(&server->clients_mutex);
  free(job);
  return NULL;
}

static bool stop_clients_and_wait(server_context *server) {
  client_job *job;
  bool fatal;

  (void)pthread_mutex_lock(&server->clients_mutex);
  for (job = server->clients; job != NULL; job = job->next) {
    if (job->fd >= 0) {
      (void)shutdown(job->fd, SHUT_RDWR);
    }
  }
  while (server->client_count != 0u) {
    (void)pthread_cond_wait(&server->clients_idle, &server->clients_mutex);
  }
  fatal = server->fatal;
  (void)pthread_mutex_unlock(&server->clients_mutex);
  return fatal;
}

static int accept_loop(int listener_fd, store_server_store *store,
                       const server_config *config) {
  server_context server;
  struct pollfd listener_poll = {.fd = listener_fd,
                                 .events = POLLIN,
                                 .revents = 0};
  report_throttle admission_report = {0, 0uL, false};
  report_throttle pressure_report = {0, 0uL, false};
  report_throttle drain_report = {0, 0uL, false};
  unsigned long quiet_polls = 0uL;
  /* Armed by activity, spent by one compaction: a store that stays quiet pays
     for exactly one replay, not one every quiet window. */
  bool idle_compaction_armed = false;
  bool failed = false;

  if (initialize_server_context(&server, store) != 0) {
    return -1;
  }
  server.max_active_clients = config->max_active_clients;
  /* READY means the store is booted, the log is replayed, and this loop is
     about to accept -- the host can ANSWER. It deliberately does not mean
     "listening": under socket activation systemd owns the listening socket
     long before this process exists, so listening carries no information. */
  notify_service_manager("READY=1\nSTATUS=serving Store RPC\n");
  while (stop_requested == 0 && !server_has_fatal_failure(&server)) {
    client_job *job;
    pthread_t worker;
    int client_fd;
    int status;

    listener_poll.revents = 0;
    status = poll(&listener_poll, 1, ACCEPT_POLL_MILLISECONDS);
    if (status < 0) {
      if (errno == EINTR) {
        continue;
      }
      fprintf(stderr, "beagle-store-server-native: listener poll failed: %s\n",
              strerror(errno));
      failed = true;
      break;
    }
    if (status == 0) {
      if (!idle_compaction_armed || server_has_live_client(&server)) {
        quiet_polls = 0uL;
        continue;
      }
      quiet_polls += 1uL;
      if (quiet_polls >= (unsigned long)IDLE_COMPACT_QUIET_POLLS) {
        quiet_polls = 0uL;
        idle_compaction_armed = false;
        if (compact_while_quiet(&server) != 0) {
          failed = true;
          break;
        }
      }
      continue;
    }
    if ((listener_poll.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      fputs("beagle-store-server-native: listener became unavailable\n", stderr);
      failed = true;
      break;
    }
    if ((listener_poll.revents & POLLIN) == 0) {
      continue;
    }
    client_fd = accept(listener_fd, NULL, NULL);

    if (client_fd < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == ECONNABORTED) {
        continue;
      }
      fprintf(stderr, "beagle-store-server-native: accept failed: %s\n",
              strerror(errno));
      failed = true;
      break;
    }
    if (stop_requested != 0 || server_has_fatal_failure(&server)) {
      (void)close(client_fd);
      break;
    }
    if (peer_never_asked(client_fd)) {
      /* The cheap drain path: a connection whose peer vanished while it sat in
         the backlog costs one close here, instead of a thread, an arena, and a
         slot held until the worker discovers the same thing. A live client
         that has not sent yet reports EAGAIN, not end-of-file, so it is
         admitted normally. */
      (void)close(client_fd);
      report_throttled(&drain_report,
                       "dropped a connection whose peer had already closed");
      continue;
    }
    if (set_close_on_exec(client_fd) != 0) {
      fprintf(stderr,
              "beagle-store-server-native: cannot set close-on-exec on client: %s\n",
              strerror(errno));
      (void)close(client_fd);
      continue;
    }
    if (set_client_io_timeouts(client_fd, config->client_io_timeout_ms) != 0) {
      fprintf(stderr,
              "beagle-store-server-native: cannot bound client socket timeouts: %s\n",
              strerror(errno));
      (void)close(client_fd);
      continue;
    }

    job = malloc(sizeof(*job));
    if (job == NULL) {
      /* Memory pressure is transient by nature; refuse this connection and
         keep accepting rather than abandon the listener. */
      report_throttled(&pressure_report,
                       "cannot allocate a client worker; refusing the "
                       "connection");
      (void)close(client_fd);
      accept_pressure_backoff();
      continue;
    }
    job->fd = client_fd;
    job->server = &server;
    (void)pthread_mutex_lock(&server.clients_mutex);
    if (server.client_count >= server.max_active_clients) {
      (void)pthread_mutex_unlock(&server.clients_mutex);
      report_throttled(&admission_report,
                       "active client limit reached; refusing the connection");
      (void)close(client_fd);
      free(job);
      continue;
    }
    job->next = server.clients;
    server.clients = job;
    server.client_count += 1u;
    status = pthread_create(&worker, &server.worker_attributes,
                            serve_client_worker, job);
    if (status != 0) {
      remove_client_locked(&server, job);
      (void)pthread_mutex_unlock(&server.clients_mutex);
      (void)close(client_fd);
      free(job);
      if (status == EAGAIN) {
        /* Transient thread-creation pressure: cgroup pids.max, RLIMIT_NPROC,
           or memory. Refusing THIS connection is right; killing the acceptor
           is not. Breaking out here is what left :7977 a zombie listener on
           2026-08-09 -- a socket that accepted and queued clients forever
           while no thread remained to serve any of them. */
        report_throttled(&pressure_report,
                         "cannot create a client worker (resource temporarily "
                         "unavailable); refusing the connection");
        accept_pressure_backoff();
        continue;
      }
      fprintf(stderr, "beagle-store-server-native: cannot create client worker: %s\n",
              strerror(status));
      failed = true;
      break;
    }
    (void)pthread_mutex_unlock(&server.clients_mutex);
    /* An admitted client is the only thing that can dirty the chain, so it is
       also the only thing that makes a later compaction worth its replay. */
    idle_compaction_armed = true;
    quiet_polls = 0uL;
  }
  notify_service_manager("STOPPING=1\nSTATUS=draining clients\n");
  if (stop_clients_and_wait(&server)) {
    failed = true;
  }
  destroy_server_context(&server);
  return failed ? -1 : 0;
}

int main(int argc, char **argv) {
  server_config config;
  writer_authority authority = {.fd = -1,
                                .canonical_log_path = NULL,
                                .lock_path = NULL};
  store_server_store *store = NULL;
  char error[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  int listener_fd = -1;
  int result = 1;
  int status;
  uint32_t generated_abi;

#if defined(__GLIBC__)
  (void)mallopt(M_MMAP_THRESHOLD, ARENA_MMAP_THRESHOLD_BYTES);
#endif
  generated_abi = store_server_generated_abi();
  if (generated_abi != BEAGLE_STORE_SERVER_GENERATED_ABI) {
    fprintf(stderr,
            "beagle-store-server-native: generated host ABI mismatch; expected %u, "
            "got %u\n",
            (unsigned int)BEAGLE_STORE_SERVER_GENERATED_ABI,
            (unsigned int)generated_abi);
    return 2;
  }
  if (load_config(argc, argv, &config) != 0 ||
      reject_unsupported_environment() != 0 || install_signal_handlers() != 0) {
    return 2;
  }
  if (acquire_writer_authority(config.log_path, &authority) != 0) {
    release_writer_authority(&authority);
    return 1;
  }

  error[0] = '\0';
  status = store_server_store_boot(authority.canonical_log_path,
                                      config.space_id,
                                      config.memory_budget_bytes, &store,
                                      error, sizeof(error));
  terminate_hook_error(error);
  if (status != BEAGLE_STORE_SERVER_OK || store == NULL) {
    fprintf(stderr,
            "beagle-store-server-native: store_server_store_boot failed (%d): %s\n",
            status, hook_detail(error));
    goto cleanup;
  }

  listener_fd = open_listener(&config);
  if (listener_fd < 0) {
    goto cleanup;
  }
  fprintf(stderr,
          "beagle-store-server-native: listening on %s:%u, log=%s, max-clients=%zu, "
          "client-io-timeout-ms=%ld\n",
          config.bind_text, (unsigned int)config.port,
          authority.canonical_log_path, config.max_active_clients,
          config.client_io_timeout_ms);
  result = accept_loop(listener_fd, store, &config) == 0 ? 0 : 1;

cleanup:
  if (listener_fd >= 0) {
    (void)close(listener_fd);
  }
  if (store != NULL) {
    error[0] = '\0';
    status = store_server_store_shutdown(store, error, sizeof(error));
    terminate_hook_error(error);
    if (status != BEAGLE_STORE_SERVER_OK) {
      fprintf(stderr,
              "beagle-store-server-native: store_server_store_shutdown failed (%d): "
              "%s\n",
              status, hook_detail(error));
      result = 1;
    }
  }
  release_writer_authority(&authority);
  return result;
}
