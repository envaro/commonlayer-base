/*
 * Tests for cl-probe: parser unit tests and loopback integration tests for each
 * probe mode, plus end-to-end checks of the built binary's exit codes.
 *
 * usage: test_cl_probe <path-to-cl-probe>
 * SPDX-License-Identifier: Apache-2.0
 */
#define _POSIX_C_SOURCE 200809L

#include "cl_probe.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures, checks;

#define CHECK(cond)                                                                    \
	do {                                                                           \
		checks++;                                                              \
		if (!(cond)) {                                                         \
			failures++;                                                    \
			fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
		}                                                                      \
	} while (0)

static void test_parse_url(void)
{
	struct cl_url u;
	const char *err;

	CHECK(cl_parse_url("http://127.0.0.1:8080/healthz", &u, &err) == 0);
	CHECK(strcmp(u.host, "127.0.0.1") == 0 && strcmp(u.port, "8080") == 0 &&
	      strcmp(u.path, "/healthz") == 0);
	CHECK(cl_parse_url("http://localhost", &u, &err) == 0);
	CHECK(strcmp(u.host, "localhost") == 0 && strcmp(u.port, "80") == 0 && strcmp(u.path, "/") == 0);
	CHECK(cl_parse_url("http://[::1]:9000/a?b=c", &u, &err) == 0);
	CHECK(strcmp(u.host, "::1") == 0 && strcmp(u.port, "9000") == 0 && strcmp(u.path, "/a?b=c") == 0);
	CHECK(cl_parse_url("http://[::1]/x", &u, &err) == 0 && strcmp(u.port, "80") == 0);
	CHECK(cl_parse_url("http://host/p@q", &u, &err) == 0);

	CHECK(cl_parse_url("https://localhost/", &u, &err) != 0);
	CHECK(cl_parse_url("ftp://localhost/", &u, &err) != 0);
	CHECK(cl_parse_url("http://", &u, &err) != 0);
	CHECK(cl_parse_url("http://:80/", &u, &err) != 0);
	CHECK(cl_parse_url("http://host:0/", &u, &err) != 0);
	CHECK(cl_parse_url("http://host:65536/", &u, &err) != 0);
	CHECK(cl_parse_url("http://host:12x/", &u, &err) != 0);
	CHECK(cl_parse_url("http://host:/", &u, &err) != 0);
	CHECK(cl_parse_url("http://[::1/", &u, &err) != 0);
	CHECK(cl_parse_url("http://user:pw@host/", &u, &err) != 0);
	CHECK(cl_parse_url("http://host/a b", &u, &err) != 0);
	CHECK(cl_parse_url("http://host/a\r\nX: y", &u, &err) != 0);
	CHECK(cl_parse_url(NULL, &u, &err) != 0);

	char longurl[CL_PROBE_PATH_MAX + 64];
	strcpy(longurl, "http://h/");
	memset(longurl + 9, 'a', CL_PROBE_PATH_MAX);
	longurl[9 + CL_PROBE_PATH_MAX] = '\0';
	CHECK(cl_parse_url(longurl, &u, &err) != 0);
}

static void test_parse_status(void)
{
	struct cl_status_match m;

	CHECK(cl_parse_status_match("200", &m) == 0 && m.code == 200 && !m.is_class);
	CHECK(cl_parse_status_match("2xx", &m) == 0 && m.code == 2 && m.is_class);
	CHECK(cl_status_matches(&m, 204) && !cl_status_matches(&m, 301));
	CHECK(cl_parse_status_match("099", &m) != 0);
	CHECK(cl_parse_status_match("600", &m) != 0);
	CHECK(cl_parse_status_match("6xx", &m) != 0);
	CHECK(cl_parse_status_match("20", &m) != 0);
	CHECK(cl_parse_status_match("2000", &m) != 0);
	CHECK(cl_parse_status_match("abc", &m) != 0);

	CHECK(cl_parse_status_line("HTTP/1.1 200 OK\r\n", 17) == 200);
	CHECK(cl_parse_status_line("HTTP/1.0 503 Service Unavailable\r\n", 34) == 503);
	CHECK(cl_parse_status_line("HTTP/1.1 204\r\n", 14) == 204);
	CHECK(cl_parse_status_line("HTTP/1.1 204", 12) == 204);
	CHECK(cl_parse_status_line("HTTP/2 200 OK\r\n", 15) == -1);
	CHECK(cl_parse_status_line("HTTP/1.1 2000 OK\r\n", 18) == -1);
	CHECK(cl_parse_status_line("HTTP/1.1 099 X\r\n", 16) == -1);
	CHECK(cl_parse_status_line("SSH-2.0-OpenSSH\r\n", 17) == -1);
	CHECK(cl_parse_status_line("HTTP/1.1 20", 11) == -1);
	CHECK(cl_parse_status_line("", 0) == -1);

	CHECK(cl_parse_port("1") == 1 && cl_parse_port("65535") == 65535);
	CHECK(cl_parse_port("0") == -1 && cl_parse_port("65536") == -1 && cl_parse_port("-1") == -1);
	CHECK(cl_parse_port("") == -1 && cl_parse_port("123456") == -1 && cl_parse_port(NULL) == -1);
	CHECK(cl_parse_timeout("5") == 5 && cl_parse_timeout("3600") == 3600);
	CHECK(cl_parse_timeout("0") == -1 && cl_parse_timeout("3601") == -1 && cl_parse_timeout("x") == -1);
}

/* A one-shot loopback server. mode: 's' = reply with `reply`, 'h' = accept and hang. */
static pid_t start_server(int *port_out, const char *reply, char mode, int connections)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;
	struct sockaddr_in sa;
	socklen_t sl = sizeof(sa);

	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0 || listen(fd, 8) != 0) {
		perror("bind/listen");
		exit(2);
	}
	getsockname(fd, (struct sockaddr *)&sa, &sl);
	*port_out = ntohs(sa.sin_port);

	pid_t pid = fork();
	if (pid == 0) {
		for (int i = 0; i < connections; i++) {
			int c = accept(fd, NULL, NULL);
			if (c < 0)
				_exit(1);
			if (mode == 'h') {
				sleep(30);
				_exit(0);
			}
			char buf[4096];
			ssize_t n = recv(c, buf, sizeof(buf) - 1, 0);
			if (n > 0) {
				buf[n] = '\0';
				/* The request must be a well-formed GET with a Host header. */
				if (strncmp(buf, "GET /", 5) != 0 || strstr(buf, "\r\nHost: ") == NULL)
					reply = "HTTP/1.1 400 Bad Request\r\n\r\n";
			}
			ssize_t w = send(c, reply, strlen(reply), 0);
			(void)w;
			close(c);
		}
		_exit(0);
	}
	close(fd);
	return pid;
}

static void stop_server(pid_t pid)
{
	kill(pid, SIGKILL);
	waitpid(pid, NULL, 0);
}

static int closed_port(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sa;
	socklen_t sl = sizeof(sa);
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	bind(fd, (struct sockaddr *)&sa, sizeof(sa));
	getsockname(fd, (struct sockaddr *)&sa, &sl);
	close(fd); /* bound but never listened: connections are refused */
	return ntohs(sa.sin_port);
}

static void test_probes(void)
{
	struct cl_url u;
	struct cl_status_match ok = {.code = 200, .is_class = 0};
	struct cl_status_match two = {.code = 2, .is_class = 1};
	char url[128], portbuf[16];
	int port;
	pid_t pid;

	pid = start_server(&port, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 's', 1);
	snprintf(url, sizeof(url), "http://127.0.0.1:%d/healthz", port);
	CHECK(cl_parse_url(url, &u, NULL) == 0);
	CHECK(cl_probe_http(&u, &ok, 3) == CL_PROBE_OK);
	stop_server(pid);

	pid = start_server(&port, "HTTP/1.1 503 Service Unavailable\r\n\r\n", 's', 1);
	snprintf(url, sizeof(url), "http://127.0.0.1:%d/", port);
	cl_parse_url(url, &u, NULL);
	CHECK(cl_probe_http(&u, &ok, 3) == CL_PROBE_FAIL);
	stop_server(pid);

	pid = start_server(&port, "HTTP/1.0 204 No Content\r\n\r\n", 's', 1);
	snprintf(url, sizeof(url), "http://localhost:%d/", port);
	cl_parse_url(url, &u, NULL);
	CHECK(cl_probe_http(&u, &two, 3) == CL_PROBE_OK);
	stop_server(pid);

	pid = start_server(&port, "garbage\r\n", 's', 1);
	snprintf(url, sizeof(url), "http://127.0.0.1:%d/", port);
	cl_parse_url(url, &u, NULL);
	CHECK(cl_probe_http(&u, &ok, 3) == CL_PROBE_FAIL);
	stop_server(pid);

	/* A server that accepts but never answers must fail within the timeout. */
	pid = start_server(&port, "", 'h', 1);
	snprintf(url, sizeof(url), "http://127.0.0.1:%d/", port);
	cl_parse_url(url, &u, NULL);
	CHECK(cl_probe_http(&u, &ok, 1) == CL_PROBE_FAIL);
	stop_server(pid);

	snprintf(url, sizeof(url), "http://127.0.0.1:%d/", closed_port());
	cl_parse_url(url, &u, NULL);
	CHECK(cl_probe_http(&u, &ok, 2) == CL_PROBE_FAIL);

	pid = start_server(&port, "x", 's', 1);
	snprintf(portbuf, sizeof(portbuf), "%d", port);
	CHECK(cl_probe_tcp("127.0.0.1", portbuf, 2) == CL_PROBE_OK);
	stop_server(pid);
	snprintf(portbuf, sizeof(portbuf), "%d", closed_port());
	CHECK(cl_probe_tcp("127.0.0.1", portbuf, 2) == CL_PROBE_FAIL);

	CHECK(cl_probe_file("/") == CL_PROBE_OK);
	CHECK(cl_probe_file("/nonexistent/cl-probe-test") == CL_PROBE_FAIL);
}

static int run_binary(const char *bin, char *const argv[])
{
	pid_t pid = fork();
	if (pid == 0) {
		int devnull = open("/dev/null", 1);
		if (devnull >= 0) {
			dup2(devnull, 1);
			dup2(devnull, 2);
		}
		execv(bin, argv);
		_exit(127);
	}
	int status = 0;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

static void test_binary(const char *bin)
{
	char url[128], portbuf[16];
	int port;
	pid_t pid;

	{
		char *a[] = {"cl-probe", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_USAGE);
	}
	{
		char *a[] = {"cl-probe", "bogus", "x", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_USAGE);
	}
	{
		char *a[] = {"cl-probe", "http", "https://localhost/", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_USAGE);
	}
	{
		char *a[] = {"cl-probe", "-t", "0", "tcp", "localhost", "1", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_USAGE);
	}
	{
		char *a[] = {"cl-probe", "--version", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_OK);
	}
	{
		char *a[] = {"cl-probe", "file", "/", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_OK);
	}
	{
		char *a[] = {"cl-probe", "file", "/does/not/exist", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_FAIL);
	}
	pid = start_server(&port, "HTTP/1.1 200 OK\r\n\r\n", 's', 1);
	snprintf(url, sizeof(url), "http://127.0.0.1:%d/", port);
	{
		char *a[] = {"cl-probe", "-t", "3", "http", url, "200", NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_OK);
	}
	stop_server(pid);
	pid = start_server(&port, "HTTP/1.1 404 Not Found\r\n\r\n", 's', 1);
	snprintf(url, sizeof(url), "http://127.0.0.1:%d/", port);
	{
		char *a[] = {"cl-probe", "http", url, NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_FAIL);
	}
	stop_server(pid);
	pid = start_server(&port, "", 'h', 1);
	snprintf(portbuf, sizeof(portbuf), "%d", port);
	{
		char *a[] = {"cl-probe", "tcp", "127.0.0.1", portbuf, NULL};
		CHECK(run_binary(bin, a) == CL_PROBE_OK);
	}
	stop_server(pid);
}

int main(int argc, char **argv)
{
	signal(SIGPIPE, SIG_IGN);
	test_parse_url();
	test_parse_status();
	test_probes();
	if (argc > 1)
		test_binary(argv[1]);
	if (failures) {
		fprintf(stderr, "cl-probe tests: %d of %d checks failed\n", failures, checks);
		return 1;
	}
	printf("cl-probe tests: %d checks passed\n", checks);
	return 0;
}
