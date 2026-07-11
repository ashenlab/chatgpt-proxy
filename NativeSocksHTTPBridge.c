#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define HEADER_LIMIT 32768
#define BUFFER_SIZE 65536

static const char *upstream_host;
static const char *upstream_port;
static const char *upstream_username;
static const char *upstream_password;
static bool debug_enabled;
static volatile sig_atomic_t should_stop;

static void debug_log(const char *format, ...) {
  if (!debug_enabled) return;
  va_list args;
  va_start(args, format);
  fputs("[bridge] ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

static void close_fd(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

static bool send_all(int fd, const void *data, size_t length) {
  const uint8_t *cursor = data;
  while (length > 0) {
    ssize_t sent = send(fd, cursor, length, 0);
    if (sent > 0) {
      cursor += sent;
      length -= (size_t)sent;
      continue;
    }
    if (sent < 0 && errno == EINTR) continue;
    return false;
  }
  return true;
}

static bool receive_exact(int fd, void *data, size_t length) {
  uint8_t *cursor = data;
  while (length > 0) {
    ssize_t received = recv(fd, cursor, length, 0);
    if (received > 0) {
      cursor += received;
      length -= (size_t)received;
      continue;
    }
    if (received < 0 && errno == EINTR) continue;
    return false;
  }
  return true;
}

static void write_http_error(int fd, int status, const char *message) {
  char response[256];
  int length = snprintf(response, sizeof(response),
                        "HTTP/1.1 %d %s\r\nConnection: close\r\n\r\n",
                        status, message);
  if (length > 0) send_all(fd, response, (size_t)length);
}

static int connect_tcp(const char *host, const char *port) {
  struct addrinfo hints = {0};
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;

  struct addrinfo *results = NULL;
  int lookup = getaddrinfo(host, port, &hints, &results);
  if (lookup != 0) {
    debug_log("cannot resolve upstream SOCKS host: %s", gai_strerror(lookup));
    return -1;
  }

  int fd = -1;
  for (struct addrinfo *result = results; result != NULL; result = result->ai_next) {
    fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, result->ai_addr, result->ai_addrlen) == 0) break;
    debug_log("upstream socket error: %s", strerror(errno));
    close_fd(&fd);
  }
  freeaddrinfo(results);
  return fd;
}

static bool socks_connect(int fd, const char *target_host, uint16_t target_port) {
  size_t username_length = strlen(upstream_username);
  size_t password_length = strlen(upstream_password);
  bool needs_auth = username_length > 0 || password_length > 0;
  uint8_t greeting[] = {0x05, 0x01, needs_auth ? 0x02 : 0x00};
  uint8_t method_reply[2];

  if (!send_all(fd, greeting, sizeof(greeting)) ||
      !receive_exact(fd, method_reply, sizeof(method_reply)) || method_reply[0] != 0x05) {
    debug_log("SOCKS method negotiation failed");
    return false;
  }

  if (method_reply[1] == 0x02) {
    if (username_length > 255 || password_length > 255) {
      debug_log("SOCKS username or password is too long");
      return false;
    }
    uint8_t auth_request[513];
    size_t auth_length = 0;
    auth_request[auth_length++] = 0x01;
    auth_request[auth_length++] = (uint8_t)username_length;
    memcpy(auth_request + auth_length, upstream_username, username_length);
    auth_length += username_length;
    auth_request[auth_length++] = (uint8_t)password_length;
    memcpy(auth_request + auth_length, upstream_password, password_length);
    auth_length += password_length;
    uint8_t auth_reply[2];
    if (!send_all(fd, auth_request, auth_length) ||
        !receive_exact(fd, auth_reply, sizeof(auth_reply)) || auth_reply[1] != 0x00) {
      debug_log("SOCKS username/password authentication failed");
      return false;
    }
  } else if (method_reply[1] != 0x00) {
    debug_log("SOCKS authentication method is unsupported: %u", method_reply[1]);
    return false;
  }

  size_t host_length = strlen(target_host);
  if (host_length == 0 || host_length > 255) {
    debug_log("invalid CONNECT host");
    return false;
  }
  uint8_t request[262];
  size_t request_length = 0;
  request[request_length++] = 0x05;
  request[request_length++] = 0x01;
  request[request_length++] = 0x00;
  request[request_length++] = 0x03;
  request[request_length++] = (uint8_t)host_length;
  memcpy(request + request_length, target_host, host_length);
  request_length += host_length;
  request[request_length++] = (uint8_t)(target_port >> 8);
  request[request_length++] = (uint8_t)(target_port & 0xff);

  uint8_t response[4];
  if (!send_all(fd, request, request_length) ||
      !receive_exact(fd, response, sizeof(response))) {
    debug_log("SOCKS CONNECT did not return a complete response");
    return false;
  }
  if (response[0] != 0x05 || response[1] != 0x00) {
    debug_log("SOCKS CONNECT failed with reply code %u", response[1]);
    return false;
  }

  size_t address_length = 0;
  if (response[3] == 0x01) {
    address_length = 4;
  } else if (response[3] == 0x04) {
    address_length = 16;
  } else if (response[3] == 0x03) {
    uint8_t domain_length;
    if (!receive_exact(fd, &domain_length, sizeof(domain_length))) return false;
    address_length = domain_length;
  } else {
    debug_log("SOCKS CONNECT returned an unknown address type");
    return false;
  }
  uint8_t discard[257];
  return receive_exact(fd, discard, address_length + 2);
}

static bool parse_connect_request(const uint8_t *buffer, size_t length,
                                  char **host, uint16_t *port, size_t *header_length) {
  const char *text = (const char *)buffer;
  const char *end = NULL;
  for (size_t index = 3; index < length; index++) {
    if (memcmp(text + index - 3, "\r\n\r\n", 4) == 0) {
      end = text + index + 1;
      break;
    }
  }
  if (end == NULL) return false;
  *header_length = (size_t)(end - text);

  const char *line_end = memchr(text, '\r', *header_length);
  if (line_end == NULL) return false;
  size_t line_length = (size_t)(line_end - text);
  char *line = strndup(text, line_length);
  if (line == NULL) return false;

  char method[16] = {0};
  char authority[1024] = {0};
  int fields = sscanf(line, "%15s %1023s", method, authority);
  free(line);
  if (fields != 2 || strcmp(method, "CONNECT") != 0) return false;

  char *target_host = NULL;
  char *port_text = NULL;
  if (authority[0] == '[') {
    char *closing = strchr(authority, ']');
    if (closing == NULL || closing[1] != ':') return false;
    *closing = '\0';
    target_host = strdup(authority + 1);
    port_text = closing + 2;
  } else {
    char *separator = strrchr(authority, ':');
    if (separator == NULL) return false;
    *separator = '\0';
    target_host = strdup(authority);
    port_text = separator + 1;
  }
  if (target_host == NULL || target_host[0] == '\0') {
    free(target_host);
    return false;
  }
  char *port_end = NULL;
  unsigned long parsed_port = strtoul(port_text, &port_end, 10);
  if (port_end == NULL || *port_end != '\0' || parsed_port == 0 || parsed_port > 65535) {
    free(target_host);
    return false;
  }
  *host = target_host;
  *port = (uint16_t)parsed_port;
  return true;
}

static void relay(int client_fd, int upstream_fd) {
  uint8_t buffer[BUFFER_SIZE];
  bool client_open = true;
  bool upstream_open = true;
  while (client_open || upstream_open) {
    struct pollfd fds[2] = {
      {.fd = client_fd, .events = client_open ? POLLIN : 0},
      {.fd = upstream_fd, .events = upstream_open ? POLLIN : 0},
    };
    int ready = poll(fds, 2, -1);
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) break;
    for (int index = 0; index < 2; index++) {
      if (!(fds[index].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      int source = fds[index].fd;
      int target = index == 0 ? upstream_fd : client_fd;
      ssize_t received = recv(source, buffer, sizeof(buffer), 0);
      if (received > 0) {
        if (!send_all(target, buffer, (size_t)received)) {
          client_open = false;
          upstream_open = false;
          break;
        }
      } else {
        shutdown(target, SHUT_WR);
        if (index == 0) client_open = false;
        else upstream_open = false;
      }
    }
  }
}

static void *handle_client(void *argument) {
  int client_fd = *(int *)argument;
  free(argument);
  uint8_t request[HEADER_LIMIT];
  size_t used = 0;
  char *target_host = NULL;
  uint16_t target_port = 0;
  size_t header_length = 0;

  while (used < sizeof(request)) {
    ssize_t received = recv(client_fd, request + used, sizeof(request) - used, 0);
    if (received <= 0) goto finish;
    used += (size_t)received;
    if (parse_connect_request(request, used, &target_host, &target_port, &header_length)) break;
    if (used >= 4 && memmem(request, used, "\r\n\r\n", 4) != NULL) {
      write_http_error(client_fd, 400, "Bad Request");
      goto finish;
    }
  }
  if (target_host == NULL) {
    write_http_error(client_fd, 400, "Bad Request");
    goto finish;
  }

  debug_log("CONNECT %s:%u via %s:%s", target_host, target_port, upstream_host, upstream_port);
  int upstream_fd = connect_tcp(upstream_host, upstream_port);
  if (upstream_fd < 0 || !socks_connect(upstream_fd, target_host, target_port)) {
    write_http_error(client_fd, 502, "Bad Gateway");
    close_fd(&upstream_fd);
    goto finish;
  }
  debug_log("SOCKS connected %s:%u", target_host, target_port);
  const char established[] = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: chatgpt-proxy\r\n\r\n";
  if (!send_all(client_fd, established, sizeof(established) - 1)) {
    close_fd(&upstream_fd);
    goto finish;
  }
  if (used > header_length && !send_all(upstream_fd, request + header_length, used - header_length)) {
    close_fd(&upstream_fd);
    goto finish;
  }
  relay(client_fd, upstream_fd);
  close_fd(&upstream_fd);

finish:
  free(target_host);
  close_fd(&client_fd);
  return NULL;
}

static int create_listener(const char *host, const char *port) {
  struct addrinfo hints = {0};
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  hints.ai_flags = AI_NUMERICHOST;
  struct addrinfo *results = NULL;
  if (getaddrinfo(host, port, &hints, &results) != 0) return -1;

  int fd = -1;
  for (struct addrinfo *result = results; result != NULL; result = result->ai_next) {
    fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (fd < 0) continue;
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    if (bind(fd, result->ai_addr, result->ai_addrlen) == 0 && listen(fd, 32) == 0) break;
    close_fd(&fd);
  }
  freeaddrinfo(results);
  return fd;
}

static void signal_handler(int signal_number) {
  (void)signal_number;
  should_stop = 1;
}

int main(void) {
  const char *listen_host = getenv("BRIDGE_LISTEN_HOST");
  const char *listen_port = getenv("BRIDGE_LISTEN_PORT");
  upstream_host = getenv("UPSTREAM_SOCKS_HOST");
  upstream_port = getenv("UPSTREAM_SOCKS_PORT");
  upstream_username = getenv("UPSTREAM_SOCKS_USERNAME");
  upstream_password = getenv("UPSTREAM_SOCKS_PASSWORD");
  debug_enabled = getenv("BRIDGE_DEBUG") != NULL && strcmp(getenv("BRIDGE_DEBUG"), "1") == 0;

  if (listen_host == NULL || listen_port == NULL || upstream_host == NULL || upstream_port == NULL) {
    fputs("[bridge] missing required bridge environment\n", stderr);
    return 2;
  }
  if (upstream_username == NULL) upstream_username = "";
  if (upstream_password == NULL) upstream_password = "";
  if (strcmp(listen_host, "localhost") == 0) listen_host = "127.0.0.1";

  int listener_fd = create_listener(listen_host, listen_port);
  if (listener_fd < 0) {
    fprintf(stderr, "[bridge] listen failed: %s\n", strerror(errno));
    return 1;
  }

  signal(SIGTERM, signal_handler);
  signal(SIGINT, signal_handler);
  signal(SIGPIPE, SIG_IGN);
  pid_t parent_pid = getppid();
  while (!should_stop) {
    struct pollfd listener = {.fd = listener_fd, .events = POLLIN};
    int ready = poll(&listener, 1, 1000);
    if (kill(parent_pid, 0) != 0 && errno == ESRCH) break;
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) continue;
    int client_fd = accept(listener_fd, NULL, NULL);
    if (client_fd < 0) continue;
    int *client_argument = malloc(sizeof(*client_argument));
    if (client_argument == NULL) {
      close(client_fd);
      continue;
    }
    *client_argument = client_fd;
    pthread_t thread;
    if (pthread_create(&thread, NULL, handle_client, client_argument) == 0) {
      pthread_detach(thread);
    } else {
      free(client_argument);
      close(client_fd);
    }
  }
  close(listener_fd);
  return 0;
}
