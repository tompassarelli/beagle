#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"
#include "module_0.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *detail) {
  fprintf(stderr, "socket-capability fixture: %s\n", detail);
  exit(1);
}

static void report_trap(uint32_t code) {
  fprintf(stderr, "socket-capability fixture: native trap %u\n", code);
}

static void require_status(int32_t actual, int32_t expected,
                           const char *detail) {
  if (actual != expected) {
    fprintf(stderr, "socket-capability fixture: %s: got %d expected %d\n",
            detail, actual, expected);
    exit(1);
  }
}

static void test_nonblocking_write_progress(
    const native_capability *capability) {
  enum { PAYLOAD_LENGTH = 262144 };
  const struct timespec reader_delay = {0, 100000000L};
  int peers[2];
  int gate[2];
  int send_buffer_bytes = 4096;
  int flags;
  uint8_t *payload = (uint8_t *)malloc((size_t)PAYLOAD_LENGTH);
  native_bytes bytes = {payload, (size_t)PAYLOAD_LENGTH};
  int64_t written = INT64_C(-1);
  pid_t child;

  if (payload == NULL) {
    fail("allocate nonblocking payload");
  }
  for (size_t index = (size_t)0U; index < (size_t)PAYLOAD_LENGTH; index += 1U) {
    payload[index] = (uint8_t)(((index * (size_t)131U) +
                                (index / (size_t)251U)) &
                               (size_t)UINT8_MAX);
  }
  if ((socketpair(AF_UNIX, SOCK_STREAM, 0, peers) == -1) ||
      (pipe(gate) == -1) ||
      (setsockopt(peers[0], SOL_SOCKET, SO_SNDBUF, &send_buffer_bytes,
                  (socklen_t)sizeof send_buffer_bytes) == -1)) {
    fail("prepare nonblocking socket pair");
  }
  flags = fcntl(peers[0], F_GETFL);
  if ((flags == -1) || (fcntl(peers[0], F_SETFL, flags | O_NONBLOCK) == -1)) {
    fail("make socket writer nonblocking");
  }

  child = fork();
  if (child == -1) {
    fail("fork nonblocking reader");
  }
  if (child == 0) {
    uint8_t *received = (uint8_t *)malloc((size_t)PAYLOAD_LENGTH);
    uint8_t signal;
    size_t offset = (size_t)0U;
    ssize_t count;
    struct timespec remaining = reader_delay;
    (void)close(peers[0]);
    (void)close(gate[1]);
    do {
      count = read(gate[0], &signal, (size_t)1U);
    } while ((count == (ssize_t)-1) && (errno == EINTR));
    if ((received == NULL) || (count != (ssize_t)1)) {
      _exit(10);
    }
    while ((nanosleep(&remaining, &remaining) == -1) && (errno == EINTR)) {
    }
    while (offset < (size_t)PAYLOAD_LENGTH) {
      count = recv(peers[1], received + offset,
                   (size_t)PAYLOAD_LENGTH - offset, 0);
      if (count <= (ssize_t)0) {
        _exit(11);
      }
      offset += (size_t)count;
    }
    if (memcmp(received, payload, (size_t)PAYLOAD_LENGTH) != 0) {
      _exit(12);
    }
    do {
      count = recv(peers[1], &signal, (size_t)1U, 0);
    } while ((count == (ssize_t)-1) && (errno == EINTR));
    if (count != (ssize_t)0) {
      _exit(13);
    }
    free(received);
    free(payload);
    (void)close(gate[0]);
    (void)close(peers[1]);
    _exit(0);
  }

  (void)close(peers[1]);
  (void)close(gate[0]);
  if (write(gate[1], "w", (size_t)1U) != (ssize_t)1) {
    fail("release nonblocking reader");
  }
  (void)close(gate[1]);
  require_status(native_host_socket_write_bounded_v0(
                     capability, (int64_t)peers[0], bytes,
                     (int64_t)PAYLOAD_LENGTH, &written),
                 NATIVE_HOST_SOCKET_OK, "nonblocking write");
  if (written != (int64_t)PAYLOAD_LENGTH) {
    fail("nonblocking write length");
  }
  if (shutdown(peers[0], SHUT_WR) == -1) {
    fail("shutdown nonblocking writer");
  }
  (void)close(peers[0]);
  {
    int child_status = 0;
    if ((waitpid(child, &child_status, 0) != child) ||
        (!WIFEXITED(child_status)) || (WEXITSTATUS(child_status) != 0)) {
      fail("nonblocking reader lifecycle");
    }
  }
  free(payload);
}

int main(void) {
  native_capability capability = {UINT64_C(1)};
  uint8_t arena_storage[512];
  native_arena arena;
  struct sockaddr_in address;
  socklen_t address_size = (socklen_t)sizeof address;
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  int64_t inherited = INT64_C(-1);
  int64_t peer = INT64_C(-1);
  int64_t written = INT64_C(0);
  native_bytes received = {NULL, (size_t)0U};
  native_bytes reply = {(uint8_t *)"pong", (size_t)4U};
  pid_t child;

  native_set_trap_reporter(report_trap);

  if (listener == -1) {
    fail("socket");
  }
  memset(&address, 0, sizeof address);
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(0);
  if ((bind(listener, (const struct sockaddr *)&address, sizeof address) == -1) ||
      (listen(listener, 1) == -1)) {
    fail("bind/listen");
  }
  if ((listener != 3) && (dup2(listener, 3) == -1)) {
    fail("dup2 inherited listener");
  }
  if (listener != 3) {
    (void)close(listener);
  }
  require_status(native_host_socket_inherited_listener_v0(
                     &capability, NATIVE_HOST_SOCKET_INHERITED_FD, &inherited),
                 NATIVE_HOST_SOCKET_OK, "adopt fd 3");
  if (inherited != NATIVE_HOST_SOCKET_INHERITED_FD) {
    fail("adopted descriptor changed");
  }
  if (getsockname(3, (struct sockaddr *)&address, &address_size) == -1) {
    fail("getsockname");
  }

  child = fork();
  if (child == -1) {
    fail("fork");
  }
  if (child == 0) {
    const uint8_t expected[] = {UINT8_C(0), UINT8_C(0), UINT8_C(0), UINT8_C(4),
                                UINT8_C(112), UINT8_C(111), UINT8_C(110),
                                UINT8_C(103)};
    uint8_t response[sizeof expected];
    size_t offset = (size_t)0U;
    int client = socket(AF_INET, SOCK_STREAM, 0);
    if ((client == -1) ||
        (connect(client, (const struct sockaddr *)&address, address_size) == -1) ||
        (send(client, "ping", 4, 0) != 4)) {
      _exit(2);
    }
    while (offset < sizeof response) {
      ssize_t count = recv(client, response + offset, sizeof response - offset, 0);
      if (count <= 0) {
        _exit(3);
      }
      offset += (size_t)count;
    }
    if (memcmp(response, expected, sizeof response) != 0) {
      _exit(4);
    }
    (void)close(client);
    _exit(0);
  }

  require_status(native_host_socket_accept_v0(&capability, inherited, &peer),
                 NATIVE_HOST_SOCKET_OK, "accept");
  native_arena_init(&arena, arena_storage, sizeof arena_storage);
  require_status(native_host_socket_read_bounded_v0(
                     &arena, &capability, peer, INT64_C(16), &received),
                 NATIVE_HOST_SOCKET_OK, "read");
  if ((received.length != (size_t)4U) ||
      (memcmp(received.data, "ping", (size_t)4U) != 0)) {
    fail("read payload");
  }
  require_status(native_host_socket_write_bounded_v0(
                     &capability, peer, reply, INT64_C(3), &written),
                 EMSGSIZE, "write bound");
  if (native_m0_fn_0(&arena, &capability, (native_m0_type_2)peer) !=
      (native_m0_type_2)INT64_C(0)) {
    fail("canonical byte sink result");
  }
  {
    int child_status = 0;
    if ((waitpid(child, &child_status, 0) != child) ||
        (!WIFEXITED(child_status)) || (WEXITSTATUS(child_status) != 0)) {
      fail("client lifecycle");
    }
  }
  require_status(native_host_socket_read_bounded_v0(
                     &arena, &capability, peer, INT64_C(16), &received),
                 NATIVE_HOST_SOCKET_PEER_CLOSED, "peer closed");
  require_status(native_host_socket_close_v0(&capability, peer),
                 NATIVE_HOST_SOCKET_OK, "close peer");
  require_status(native_host_socket_close_v0(&capability, inherited),
                 NATIVE_HOST_SOCKET_OK, "close listener");
  test_nonblocking_write_progress(&capability);
  puts("socket capability fixture: ok");
  return 0;
}
