/* Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0 */

#ifndef OTEL_LOADER_H
#define OTEL_LOADER_H

#define OTEL_LOADER_NAME "opentelemetry_loader"
#define OTEL_LOADER_VERSION "0.1.0-dev"
#define OTEL_LOADER_AUTHOR "OpenTelemetry Authors"
#define OTEL_LOADER_URL "https://github.com/open-telemetry/opentelemetry-injector"
#define OTEL_LOADER_COPYRIGHT "Copyright (c) The OpenTelemetry Authors"

/* Overrides the artifact root that is otherwise derived from the loader's own
 * install path. Intended for tests only; in production the path is authoritative. */
#define OTEL_LOADER_ROOT_ENV "OTEL_PHP_AUTOINSTRUMENTATION_ROOT"

/* Log level, one of: debug, info, warn, error, none. Falls back to the
 * injector's own OTEL_INJECTOR_LOG_LEVEL so one setting covers both halves. */
#define OTEL_LOADER_LOG_LEVEL_ENV "OTEL_PHP_LOADER_LOG_LEVEL"
#define OTEL_INJECTOR_LOG_LEVEL_ENV "OTEL_INJECTOR_LOG_LEVEL"

typedef enum {
    OTEL_LOG_DEBUG = 0,
    OTEL_LOG_INFO = 1,
    OTEL_LOG_WARN = 2,
    OTEL_LOG_ERROR = 3,
    OTEL_LOG_NONE = 4
} otel_log_level;

typedef enum {
    OTEL_TS_UNKNOWN = 0,
    OTEL_TS_NTS = 1,
    OTEL_TS_ZTS = 2
} otel_thread_safety;

/* Everything the loader learns about the PHP that is hosting it. Populated
 * across api_no_check() and build_id_check(), consumed in startup(). */
typedef struct {
    int zend_extension_api_no; /* e.g. 420210902, as handed to api_no_check   */
    int module_api_no;         /* e.g. 20210902, the artifact directory key   */
    otel_thread_safety thread_safety;
    int debug_build;
    char build_id[256]; /* the host's ZEND_EXTENSION_BUILD_ID, verbatim */
    int api_seen;
    int build_id_seen;
} otel_host_info;

/* Where our artifacts live, derived from the loader's own path via dladdr(). */
typedef struct {
    char root[1024];      /* e.g. /usr/lib/opentelemetry/php            */
    char libc_flavor[16]; /* "glibc" | "musl", as chosen by the injector */
    int resolved;
} otel_install_info;

void otel_log(otel_log_level level, const char *fmt, ...);
otel_log_level otel_current_log_level(void);

int otel_parse_build_id(const char *build_id, otel_host_info *out);
int otel_resolve_install_info(otel_install_info *out);
int otel_module_build_id(const otel_host_info *host, char *out, size_t out_len);

/* Extensions we refuse to co-load with, because they hook the same engine
 * internals and the combination is known to be unstable. Mirrors the list
 * dd_library_loader carries, for the same reasons. */
#define OTEL_CONFLICTING_EXTENSIONS {"xdebug", "ionCube Loader", "newrelic", "blackfire", "pcov"}

#endif /* OTEL_LOADER_H */
