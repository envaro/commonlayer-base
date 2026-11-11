/*
 * cl-probe - minimal health probe for CommonLayer images.
 *
 *   cl-probe [-t seconds] http <url> [expected-status]
 *   cl-probe [-t seconds] tcp <host> <port>
 *   cl-probe file <path>
 *
 * Replaces curl/wget in container health checks. Plain HTTP only (health
 * endpoints listen on loopback); no redirects are followed; nothing is written
 * to disk. Exit status: 0 healthy, 1 unhealthy, 2 usage error.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#define _POSIX_C_SOURCE 200809L

#include "cl_probe.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define CL_PROBE_VERSION "1.0.0"
#define DEFAULT_TIMEOUT_S 5
#define RESPONSE_PEEK 512

static void usage(FILE *f)
{
	fputs("usage: cl-probe [-t seconds] http <url> [expected-status]\n"
	      "       cl-probe [-t seconds] tcp <host> <port>\n"
	      "       cl-probe file <path>\n"
	      "expected-status: exact code (default 200) or a class such as 2xx\n"
	      "exit status: 0 healthy, 1 unhealthy, 2 usage error\n",
	      f);
}

int cl_parse_port(const char *s)
{
	long v = 0;
	if (s == NULL || *s == '\0' || strlen(s) > 5)
		return -1;
	for (const char *p = s; *p; p++) {
		if (*p < '0' || *p > '9')
			return -1;
		v = v * 10 + (*p - '0');
	}
	if (v < 1 || v > 65535)
		return -1;
	return (int)v;
}

int cl_parse_timeout(const char *s)
{
	long v = 0;
	if (s == NULL || *s == '\0' || strlen(s) > 4)
		return -1;
	for (const char *p = s; *p; p++) {
		if (*p < '0' || *p > '9')
			return -1;
		v = v * 10 + (*p - '0');
	}
	if (v < 1 || v > 3600)
		return -1;
	return (int)v;
}

static int copy_bounded(char *dst, size_t cap, const char *src, size_t n)
{
	if (n >= cap)
		return -1;
	memcpy(dst, src, n);
	dst[n] = '\0';
	return 0;
}

int cl_parse_url(const char *url, struct cl_url *out, const char **err)
{
	static const char scheme[] = "http://";
	const char *p, *host_end, *port_start = NULL, *path_start;
	const char *dummy;

	if (err == NULL)
		err = &dummy;
	memset(out, 0, sizeof(*out));
	if (url == NULL) {
		*err = "missing url";
		return -1;
	}
	if (strncmp(url, "https://", 8) == 0) {
		*err = "https is not supported; probe a plain-HTTP loopback listener";
		return -1;
	}
	if (strncmp(url, scheme, sizeof(scheme) - 1) != 0) {
		*err = "url must start with http://";
		return -1;
	}
	p = url + sizeof(scheme) - 1;
	for (const char *c = p; *c; c++) {
		if ((unsigned char)*c <= 0x20 || *c == 0x7f) {
			*err = "url contains whitespace or control characters";
			return -1;
		}
	}
	if (strchr(p, '@') != NULL && (strchr(p, '/') == NULL || strchr(p, '@') < strchr(p, '/'))) {
		*err = "credentials in url are not supported";
		return -1;
	}

	if (*p == '[') {
		host_end = strchr(p, ']');
		if (host_end == NULL) {
			*err = "unterminated IPv6 literal";
			return -1;
		}
		if (copy_bounded(out->host, sizeof(out->host), p + 1, (size_t)(host_end - p - 1)) != 0 ||
		    out->host[0] == '\0') {
			*err = "invalid host";
			return -1;
		}
		p = host_end + 1;
		if (*p == ':')
			port_start = p + 1;
		else if (*p != '\0' && *p != '/') {
			*err = "invalid character after IPv6 literal";
			return -1;
		}
	} else {
		size_t n = strcspn(p, ":/");
		if (n == 0 || copy_bounded(out->host, sizeof(out->host), p, n) != 0) {
			*err = "invalid host";
			return -1;
		}
		p += n;
		if (*p == ':')
			port_start = p + 1;
	}

	path_start = strchr(port_start ? port_start : p, '/');
	if (port_start != NULL) {
		size_t n = path_start ? (size_t)(path_start - port_start) : strlen(port_start);
		char buf[CL_PROBE_PORT_MAX];
		if (copy_bounded(buf, sizeof(buf), port_start, n) != 0 || cl_parse_port(buf) < 0) {
			*err = "invalid port";
			return -1;
		}
		memcpy(out->port, buf, n + 1);
	} else {
		memcpy(out->port, "80", 3);
	}

	if (path_start == NULL) {
		memcpy(out->path, "/", 2);
	} else if (copy_bounded(out->path, sizeof(out->path), path_start, strlen(path_start)) != 0) {
		*err = "path too long";
		return -1;
	}
	return 0;
}

int cl_parse_status_match(const char *s, struct cl_status_match *out)
{
	if (s == NULL || strlen(s) != 3)
		return -1;
	if (s[0] >= '1' && s[0] <= '5' && s[1] == 'x' && s[2] == 'x') {
		out->code = s[0] - '0';
		out->is_class = 1;
		return 0;
	}
	for (int i = 0; i < 3; i++)
		if (s[i] < '0' || s[i] > '9')
			return -1;
	out->code = (s[0] - '0') * 100 + (s[1] - '0') * 10 + (s[2] - '0');
	out->is_class = 0;
	if (out->code < 100 || out->code > 599)
		return -1;
	return 0;
}

int cl_status_matches(const struct cl_status_match *m, int code)
{
	if (m->is_class)
		return code / 100 == m->code;
	return code == m->code;
}

int cl_parse_status_line(const char *buf, size_t len)
{
	/* "HTTP/1.x SP DDD" followed by SP, CR or LF (reason phrase optional). */
	if (len < 12 || memcmp(buf, "HTTP/1.", 7) != 0)
		return -1;
	if (buf[7] != '0' && buf[7] != '1')
		return -1;
	if (buf[8] != ' ')
		return -1;
	for (int i = 9; i < 12; i++)
		if (buf[i] < '0' || buf[i] > '9')
			return -1;
	if (len > 12 && buf[12] != ' ' && buf[12] != '\r' && buf[12] != '\n')
		return -1;
	int code = (buf[9] - '0') * 100 + (buf[10] - '0') * 10 + (buf[11] - '0');
	if (code < 100 || code > 599)
		return -1;
	return code;
}

static long long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int remaining_ms(long long deadline)
{
	long long r = deadline - now_ms();
	if (r <= 0)
		return 0;
	return r > 3600000 ? 3600000 : (int)r;
}

static int wait_fd(int fd, short events, long long deadline)
{
	struct pollfd pfd = {.fd = fd, .events = events};
	for (;;) {
		int ms = remaining_ms(deadline);
		if (ms == 0)
			return -1;
		int r = poll(&pfd, 1, ms);
		if (r > 0)
			return 0;
		if (r == 0)
			return -1;
		if (errno != EINTR)
			return -1;
	}
}

/* Connect to host:port before the deadline. Returns a blocking-mode-agnostic
 * non-blocking socket, or -1 with a message on stderr. */
static int connect_with_deadline(const char *host, const char *port, long long deadline)
{
	struct addrinfo hints, *res = NULL, *ai;
	int fd = -1, rc;

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	rc = getaddrinfo(host, port, &hints, &res);
	if (rc != 0) {
		fprintf(stderr, "cl-probe: cannot resolve %s: %s\n", host, gai_strerror(rc));
		return -1;
	}
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (fd < 0)
			continue;
		int flags = fcntl(fd, F_GETFL, 0);
		if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
			close(fd);
			fd = -1;
			continue;
		}
		rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
		if (rc == 0)
			break;
		if (errno == EINPROGRESS && wait_fd(fd, POLLOUT, deadline) == 0) {
			int soerr = 0;
			socklen_t sl = sizeof(soerr);
			if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) == 0 && soerr == 0)
				break;
			errno = soerr;
		}
		close(fd);
		fd = -1;
	}
	freeaddrinfo(res);
	if (fd < 0)
		fprintf(stderr, "cl-probe: cannot connect to %s port %s: %s\n", host, port,
			remaining_ms(deadline) == 0 ? "timed out" : strerror(errno));
	return fd;
}

int cl_probe_tcp(const char *host, const char *port, int timeout_s)
{
	long long deadline = now_ms() + (long long)timeout_s * 1000;
	int fd = connect_with_deadline(host, port, deadline);
	if (fd < 0)
		return CL_PROBE_FAIL;
	close(fd);
	return CL_PROBE_OK;
}

static int send_all(int fd, const char *buf, size_t len, long long deadline)
{
	while (len > 0) {
		ssize_t n = send(fd, buf, len, MSG_NOSIGNAL);
		if (n > 0) {
			buf += n;
			len -= (size_t)n;
			continue;
		}
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_fd(fd, POLLOUT, deadline) == 0)
			continue;
		return -1;
	}
	return 0;
}

int cl_probe_http(const struct cl_url *url, const struct cl_status_match *m, int timeout_s)
{
	long long deadline = now_ms() + (long long)timeout_s * 1000;
	char req[CL_PROBE_PATH_MAX + CL_PROBE_HOST_MAX + 256];
	char resp[RESPONSE_PEEK];
	size_t got = 0;
	int fd, n, code;
	int v6 = strchr(url->host, ':') != NULL;
	int default_port = strcmp(url->port, "80") == 0;

	n = snprintf(req, sizeof(req),
		     "GET %s HTTP/1.1\r\nHost: %s%s%s%s%s\r\nUser-Agent: cl-probe/" CL_PROBE_VERSION
		     "\r\nAccept: */*\r\nConnection: close\r\n\r\n",
		     url->path, v6 ? "[" : "", url->host, v6 ? "]" : "", default_port ? "" : ":",
		     default_port ? "" : url->port);
	if (n < 0 || (size_t)n >= sizeof(req)) {
		fprintf(stderr, "cl-probe: request too long\n");
		return CL_PROBE_FAIL;
	}
	fd = connect_with_deadline(url->host, url->port, deadline);
	if (fd < 0)
		return CL_PROBE_FAIL;
	if (send_all(fd, req, (size_t)n, deadline) != 0) {
		fprintf(stderr, "cl-probe: sending request failed\n");
		close(fd);
		return CL_PROBE_FAIL;
	}
	while (got < sizeof(resp)) {
		ssize_t r = recv(fd, resp + got, sizeof(resp) - got, 0);
		if (r > 0) {
			got += (size_t)r;
			if (memchr(resp, '\n', got) != NULL)
				break;
			continue;
		}
		if (r == 0)
			break;
		if (errno == EINTR)
			continue;
		if ((errno == EAGAIN || errno == EWOULDBLOCK) && wait_fd(fd, POLLIN, deadline) == 0)
			continue;
		break;
	}
	close(fd);
	code = cl_parse_status_line(resp, got);
	if (code < 0) {
		fprintf(stderr, "cl-probe: no valid HTTP status line received from %s\n", url->host);
		return CL_PROBE_FAIL;
	}
	if (!cl_status_matches(m, code)) {
		if (m->is_class)
			fprintf(stderr, "cl-probe: status %d, expected %dxx\n", code, m->code);
		else
			fprintf(stderr, "cl-probe: status %d, expected %d\n", code, m->code);
		return CL_PROBE_FAIL;
	}
	return CL_PROBE_OK;
}

int cl_probe_file(const char *path)
{
	struct stat st;
	if (path == NULL || *path == '\0')
		return CL_PROBE_USAGE;
	if (stat(path, &st) != 0) {
		fprintf(stderr, "cl-probe: %s: %s\n", path, strerror(errno));
		return CL_PROBE_FAIL;
	}
	return CL_PROBE_OK;
}

static void on_alarm(int sig)
{
	(void)sig;
	static const char msg[] = "cl-probe: hard timeout\n";
	ssize_t ignored = write(2, msg, sizeof(msg) - 1);
	(void)ignored;
	_exit(CL_PROBE_FAIL);
}

int cl_probe_main(int argc, char **argv)
{
	int timeout_s = DEFAULT_TIMEOUT_S;
	int i = 1;
	const char *env = getenv("CL_PROBE_TIMEOUT");

	if (env != NULL && *env != '\0') {
		timeout_s = cl_parse_timeout(env);
		if (timeout_s < 0) {
			fprintf(stderr, "cl-probe: invalid CL_PROBE_TIMEOUT\n");
			return CL_PROBE_USAGE;
		}
	}
	if (i < argc && (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0)) {
		usage(stdout);
		return CL_PROBE_OK;
	}
	if (i < argc && strcmp(argv[i], "--version") == 0) {
		puts("cl-probe " CL_PROBE_VERSION);
		return CL_PROBE_OK;
	}
	if (i + 1 < argc && strcmp(argv[i], "-t") == 0) {
		timeout_s = cl_parse_timeout(argv[i + 1]);
		if (timeout_s < 0) {
			fprintf(stderr, "cl-probe: invalid timeout '%s'\n", argv[i + 1]);
			return CL_PROBE_USAGE;
		}
		i += 2;
	}
	if (i >= argc) {
		usage(stderr);
		return CL_PROBE_USAGE;
	}

	const char *mode = argv[i++];
	int nargs = argc - i;

	if (strcmp(mode, "http") == 0 && (nargs == 1 || nargs == 2)) {
		struct cl_url url;
		struct cl_status_match m = {.code = 200, .is_class = 0};
		const char *err = NULL;
		if (cl_parse_url(argv[i], &url, &err) != 0) {
			fprintf(stderr, "cl-probe: %s\n", err);
			return CL_PROBE_USAGE;
		}
		if (nargs == 2 && cl_parse_status_match(argv[i + 1], &m) != 0) {
			fprintf(stderr, "cl-probe: invalid expected status '%s'\n", argv[i + 1]);
			return CL_PROBE_USAGE;
		}
		signal(SIGALRM, on_alarm);
		alarm((unsigned)timeout_s + 1);
		int rc = cl_probe_http(&url, &m, timeout_s);
		alarm(0);
		return rc;
	}
	if (strcmp(mode, "tcp") == 0 && nargs == 2) {
		if (argv[i][0] == '\0' || strlen(argv[i]) >= CL_PROBE_HOST_MAX || cl_parse_port(argv[i + 1]) < 0) {
			fprintf(stderr, "cl-probe: invalid host or port\n");
			return CL_PROBE_USAGE;
		}
		signal(SIGALRM, on_alarm);
		alarm((unsigned)timeout_s + 1);
		int rc = cl_probe_tcp(argv[i], argv[i + 1], timeout_s);
		alarm(0);
		return rc;
	}
	if (strcmp(mode, "file") == 0 && nargs == 1)
		return cl_probe_file(argv[i]);

	usage(stderr);
	return CL_PROBE_USAGE;
}
