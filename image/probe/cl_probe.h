/*
 * cl-probe - minimal health probe for CommonLayer images.
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef CL_PROBE_H
#define CL_PROBE_H

#include <stddef.h>

/* Exit codes. */
#define CL_PROBE_OK 0        /* healthy */
#define CL_PROBE_FAIL 1      /* unhealthy (connection refused, wrong status, ...) */
#define CL_PROBE_USAGE 2     /* invalid arguments */

#define CL_PROBE_HOST_MAX 256
#define CL_PROBE_PORT_MAX 8
#define CL_PROBE_PATH_MAX 2048

struct cl_url {
	char host[CL_PROBE_HOST_MAX];
	char port[CL_PROBE_PORT_MAX];
	char path[CL_PROBE_PATH_MAX];
};

/*
 * Status matcher: an exact code (e.g. 204) or a class written "2xx".
 */
struct cl_status_match {
	int code;  /* exact code, or the class digit (1..5) when is_class */
	int is_class;
};

/* Parse "http://host[:port][/path]". IPv6 literals use brackets. 0 on success. */
int cl_parse_url(const char *url, struct cl_url *out, const char **err);

/* Parse a decimal TCP port 1..65535. Returns the port or -1. */
int cl_parse_port(const char *s);

/* Parse "200" or "2xx". 0 on success. */
int cl_parse_status_match(const char *s, struct cl_status_match *out);

/* Does `code` satisfy the matcher? */
int cl_status_matches(const struct cl_status_match *m, int code);

/*
 * Parse an HTTP/1.x status line ("HTTP/1.1 200 OK"); `len` bytes of `buf`.
 * Returns the status code (100..599) or -1.
 */
int cl_parse_status_line(const char *buf, size_t len);

/* Parse a timeout in whole seconds, 1..3600. Returns seconds or -1. */
int cl_parse_timeout(const char *s);

/* The three probes. Each returns CL_PROBE_OK or CL_PROBE_FAIL and writes a
 * one-line diagnostic to stderr on failure. */
int cl_probe_http(const struct cl_url *url, const struct cl_status_match *m, int timeout_s);
int cl_probe_tcp(const char *host, const char *port, int timeout_s);
int cl_probe_file(const char *path);

/* Entry point shared by main() and the tests. */
int cl_probe_main(int argc, char **argv);

#endif
