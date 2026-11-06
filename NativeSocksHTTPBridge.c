#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
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
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define HEADER_LIMIT 32768
#define BUFFER_SIZE 65536
#define DEFAULT_HANDSHAKE_TIMEOUT_SECONDS 15
#define DEFAULT_MAX_CONNECTIONS 128

static const char *upstream_host;
static const char *upstream_port;
static const char *upstream_username;
static const char *upstream_password;
static const char *upstream_type;
static bool debug_enabled;
static volatile sig_atomic_t should_stop;
static unsigned int handshake_timeout_seconds = DEFAULT_HANDSHAKE_TIMEOUT_SECONDS;
static unsigned int max_connections = DEFAULT_MAX_CONNECTIONS;
static unsigned int active_connections;
static pthread_mutex_t connection_mutex = PTHREAD_MUTEX_INITIALIZER;

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

static unsigned int positive_env_value(const char *name, unsigned int fallback,
                                       unsigned int maximum) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0') return fallback;
  char *end = NULL;
  errno = 0;
  unsigned long parsed = strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed == 0 || parsed > maximum) {
    return fallback;
  }
  return (unsigned int)parsed;
}

static void set_socket_timeout(int fd, unsigned int seconds) {
  struct timeval timeout = {
    .tv_sec = (time_t)seconds,
    .tv_usec = 0,
  };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static void clear_socket_timeout(int fd) {
  struct timeval timeout = {0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static bool reserve_connection(void) {
  bool reserved = false;
  pthread_mutex_lock(&connection_mutex);
  if (active_connections < max_connections) {
    active_connections++;
    reserved = true;
  }
  pthread_mutex_unlock(&connection_mutex);
  return reserved;
}

static void release_connection(void) {
  pthread_mutex_lock(&connection_mutex);
  if (active_connections > 0) active_connections--;
  pthread_mutex_unlock(&connection_mutex);
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
    int original_flags = fcntl(fd, F_GETFL, 0);
    if (original_flags < 0 || fcntl(fd, F_SETFL, original_flags | O_NONBLOCK) < 0) {
      close_fd(&fd);
      continue;
    }

    int connection_status = connect(fd, result->ai_addr, result->ai_addrlen);
    if (connection_status < 0 && errno == EINPROGRESS) {
      struct pollfd pending = {.fd = fd, .events = POLLOUT};
      int ready = poll(&pending, 1, (int)handshake_timeout_seconds * 1000);
      if (ready > 0 && (pending.revents & (POLLOUT | POLLERR | POLLHUP))) {
        socklen_t error_length = sizeof(connection_status);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &connection_status, &error_length) != 0) {
          connection_status = errno;
        }
      } else {
        connection_status = ready == 0 ? ETIMEDOUT : errno;
      }
    } else if (connection_status < 0) {
      connection_status = errno;
    }

    if (fcntl(fd, F_SETFL, original_flags) < 0) {
      connection_status = errno;
    }
    if (connection_status == 0) {
      set_socket_timeout(fd, handshake_timeout_seconds);
      break;
    }
    errno = connection_status;
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

static char *base64_encode(const uint8_t *input, size_t length) {
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t output_length = 4 * ((length + 2) / 3);
  char *output = malloc(output_length + 1);
  if (output == NULL) return NULL;

  size_t input_index = 0;
  size_t output_index = 0;
  while (input_index < length) {
    uint32_t first = input[input_index++];
    uint32_t second = input_index < length ? input[input_index++] : 0;
    uint32_t third = input_index < length ? input[input_index++] : 0;
    uint32_t value = (first << 16) | (second << 8) | third;
    output[output_index++] = alphabet[(value >> 18) & 0x3f];
    output[output_index++] = alphabet[(value >> 12) & 0x3f];
    output[output_index++] = alphabet[(value >> 6) & 0x3f];
    output[output_index++] = alphabet[value & 0x3f];
  }
  if (length % 3 == 1) {
    output[output_length - 2] = '=';
    output[output_length - 1] = '=';
  } else if (length % 3 == 2) {
    output[output_length - 1] = '=';
  }
  output[output_length] = '\0';
  return output;
}

static bool http_proxy_connect(int fd, const char *target_host, uint16_t target_port) {
  bool needs_auth = upstream_username[0] != '\0' || upstream_password[0] != '\0';
  size_t credentials_length = strlen(upstream_username) + strlen(upstream_password) + 1;
  char *credentials = NULL;
  char *encoded_credentials = NULL;
  if (needs_auth) {
    credentials = malloc(credentials_length + 1);
    if (credentials == NULL) return false;
    snprintf(credentials, credentials_length + 1, "%s:%s", upstream_username, upstream_password);
    encoded_credentials = base64_encode((const uint8_t *)credentials, credentials_length);
    free(credentials);
    if (encoded_credentials == NULL) return false;
  }

  bool ipv6_target = strchr(target_host, ':') != NULL;
  size_t request_capacity = strlen(target_host) * 2 +
      (encoded_credentials == NULL ? 0 : strlen(encoded_credentials)) + 256;
  char *request = malloc(request_capacity);
  if (request == NULL) {
    free(encoded_credentials);
    return false;
  }
  const char *authorization_prefix = needs_auth ? "Proxy-Authorization: Basic " : "";
  const char *authorization_value = needs_auth ? encoded_credentials : "";
  const char *authorization_suffix = needs_auth ? "\r\n" : "";
  int request_length = snprintf(
      request, request_capacity,
      ipv6_target
          ? "CONNECT [%s]:%u HTTP/1.1\r\nHost: [%s]:%u\r\n%s%s%sProxy-Connection: Keep-Alive\r\n\r\n"
          : "CONNECT %s:%u HTTP/1.1\r\nHost: %s:%u\r\n%s%s%sProxy-Connection: Keep-Alive\r\n\r\n",
      target_host, target_port, target_host, target_port,
      authorization_prefix, authorization_value, authorization_suffix);
  free(encoded_credentials);
  if (request_length < 0 || (size_t)request_length >= request_capacity ||
      !send_all(fd, request, (size_t)request_length)) {
    free(request);
    debug_log("HTTP proxy CONNECT request failed");
    return false;
  }
  free(request);

  char response[HEADER_LIMIT + 1];
  size_t used = 0;
  while (used < HEADER_LIMIT) {
    ssize_t received = recv(fd, response + used, 1, 0);
    if (received < 0 && errno == EINTR) continue;
    if (received <= 0) {
      debug_log("HTTP proxy closed during CONNECT response");
      return false;
    }
    used++;
    if (used >= 4 && memcmp(response + used - 4, "\r\n\r\n", 4) == 0) break;
  }
  if (used < 4 || memcmp(response + used - 4, "\r\n\r\n", 4) != 0) {
    debug_log("HTTP proxy CONNECT response header is too large");
    return false;
  }
  response[used] = '\0';
  int major = 0;
  int minor = 0;
  int status = 0;
  if (sscanf(response, "HTTP/%d.%d %d", &major, &minor, &status) != 3 ||
      status < 200 || status >= 300) {
    debug_log("HTTP proxy CONNECT failed with status %d", status);
    return false;
  }
  return true;
}

static bool http_proxy_forward_request(int fd, const uint8_t *request,
                                       size_t header_length) {
  bool needs_auth = upstream_username[0] != '\0' || upstream_password[0] != '\0';
  if (!needs_auth) return send_all(fd, request, header_length);
  if (header_length < 4) return false;

  size_t credentials_length = strlen(upstream_username) + strlen(upstream_password) + 1;
  char *credentials = malloc(credentials_length + 1);
  if (credentials == NULL) return false;
  snprintf(credentials, credentials_length + 1, "%s:%s", upstream_username, upstream_password);
  char *encoded_credentials = base64_encode((const uint8_t *)credentials, credentials_length);
  free(credentials);
  if (encoded_credentials == NULL) return false;

  size_t header_prefix_length = header_length - 2;
  size_t authorization_capacity = strlen(encoded_credentials) + 128;
  char *authorization = malloc(authorization_capacity);
  if (authorization == NULL) {
    free(encoded_credentials);
    return false;
  }
  int authorization_length = snprintf(
      authorization, authorization_capacity,
      "Proxy-Authorization: Basic %s\r\nProxy-Connection: close\r\nConnection: close\r\n\r\n",
      encoded_credentials);
  free(encoded_credentials);
  bool success = authorization_length > 0 &&
      (size_t)authorization_length < authorization_capacity &&
      send_all(fd, request, header_prefix_length) &&
      send_all(fd, authorization, (size_t)authorization_length);
  free(authorization);
  return success;
}

static bool upstream_connect(int fd, const char *target_host, uint16_t target_port) {
  if (strcmp(upstream_type, "http") == 0) {
    return http_proxy_connect(fd, target_host, target_port);
  }
  return socks_connect(fd, target_host, target_port);
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
  set_socket_timeout(client_fd, handshake_timeout_seconds);
  uint8_t request[HEADER_LIMIT];
  size_t used = 0;
  char *target_host = NULL;
  uint16_t target_port = 0;
  size_t header_length = 0;
  bool forward_http_request = false;

  while (used < sizeof(request)) {
    ssize_t received = recv(client_fd, request + used, sizeof(request) - used, 0);
    if (received <= 0) goto finish;
    used += (size_t)received;
    if (parse_connect_request(request, used, &target_host, &target_port, &header_length)) break;
    void *header_end = used >= 4 ? memmem(request, used, "\r\n\r\n", 4) : NULL;
    if (header_end != NULL && strcmp(upstream_type, "http") == 0) {
      header_length = (size_t)((uint8_t *)header_end - request) + 4;
      forward_http_request = true;
      break;
    }
    if (header_end != NULL) {
      write_http_error(client_fd, 400, "Bad Request");
      goto finish;
    }
  }
  if (target_host == NULL && !forward_http_request) {
    write_http_error(client_fd, 400, "Bad Request");
    goto finish;
  }

  if (forward_http_request) {
    debug_log("forwarding HTTP request via %s:%s", upstream_host, upstream_port);
    int upstream_fd = connect_tcp(upstream_host, upstream_port);
    if (upstream_fd < 0 ||
        !http_proxy_forward_request(upstream_fd, request, header_length) ||
        (used > header_length &&
         !send_all(upstream_fd, request + header_length, used - header_length))) {
      write_http_error(client_fd, 502, "Bad Gateway");
      close_fd(&upstream_fd);
      goto finish;
    }
    clear_socket_timeout(client_fd);
    clear_socket_timeout(upstream_fd);
    relay(client_fd, upstream_fd);
    close_fd(&upstream_fd);
    goto finish;
  }

  debug_log("CONNECT %s:%u via %s %s:%s", target_host, target_port,
            upstream_type, upstream_host, upstream_port);
  int upstream_fd = connect_tcp(upstream_host, upstream_port);
  if (upstream_fd < 0 || !upstream_connect(upstream_fd, target_host, target_port)) {
    write_http_error(client_fd, 502, "Bad Gateway");
    close_fd(&upstream_fd);
    goto finish;
  }
  debug_log("upstream proxy connected %s:%u", target_host, target_port);
  const char established[] = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: chatgpt-proxy\r\n\r\n";
  if (!send_all(client_fd, established, sizeof(established) - 1)) {
    close_fd(&upstream_fd);
    goto finish;
  }
  if (used > header_length && !send_all(upstream_fd, request + header_length, used - header_length)) {
    close_fd(&upstream_fd);
    goto finish;
  }
  clear_socket_timeout(client_fd);
  clear_socket_timeout(upstream_fd);
  relay(client_fd, upstream_fd);
  close_fd(&upstream_fd);

finish:
  free(target_host);
  close_fd(&client_fd);
  release_connection();
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
  upstream_type = getenv("UPSTREAM_PROXY_TYPE");
  upstream_host = getenv("UPSTREAM_PROXY_HOST");
  upstream_port = getenv("UPSTREAM_PROXY_PORT");
  upstream_username = getenv("UPSTREAM_PROXY_USERNAME");
  upstream_password = getenv("UPSTREAM_PROXY_PASSWORD");
  if (upstream_type == NULL) upstream_type = "socks5";
  if (upstream_host == NULL) upstream_host = getenv("UPSTREAM_SOCKS_HOST");
  if (upstream_port == NULL) upstream_port = getenv("UPSTREAM_SOCKS_PORT");
  if (upstream_username == NULL) upstream_username = getenv("UPSTREAM_SOCKS_USERNAME");
  if (upstream_password == NULL) upstream_password = getenv("UPSTREAM_SOCKS_PASSWORD");
  const char *debug_value = getenv("BRIDGE_DEBUG");
  debug_enabled = debug_value != NULL && strcmp(debug_value, "1") == 0;
  handshake_timeout_seconds = positive_env_value(
      "BRIDGE_HANDSHAKE_TIMEOUT_SECONDS", DEFAULT_HANDSHAKE_TIMEOUT_SECONDS, 300);
  max_connections = positive_env_value(
      "BRIDGE_MAX_CONNECTIONS", DEFAULT_MAX_CONNECTIONS, 4096);

  if (listen_host == NULL || listen_port == NULL || upstream_host == NULL || upstream_port == NULL) {
    fputs("[bridge] missing required bridge environment\n", stderr);
    return 2;
  }
  if (upstream_username == NULL) upstream_username = "";
  if (upstream_password == NULL) upstream_password = "";
  if (strcmp(upstream_type, "socks5") != 0 && strcmp(upstream_type, "http") != 0) {
    fputs("[bridge] unsupported upstream proxy type\n", stderr);
    return 2;
  }
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
    if (!reserve_connection()) {
      set_socket_timeout(client_fd, 1);
      write_http_error(client_fd, 503, "Service Unavailable");
      close(client_fd);
      continue;
    }
    int *client_argument = malloc(sizeof(*client_argument));
    if (client_argument == NULL) {
      release_connection();
      close(client_fd);
      continue;
    }
    *client_argument = client_fd;
    pthread_t thread;
    if (pthread_create(&thread, NULL, handle_client, client_argument) == 0) {
      pthread_detach(thread);
    } else {
      free(client_argument);
      release_connection();
      close(client_fd);
    }
  }
  close(listener_fd);
  return 0;
}
