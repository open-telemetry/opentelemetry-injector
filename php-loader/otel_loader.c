/* Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * The OpenTelemetry PHP universal loader.
 *
 * A Zend extension that can be loaded by any PHP, whatever its module API
 * version, thread-safety flavor or debug setting, and which then resolves and
 * loads the opentelemetry extension actually built for that PHP.
 *
 * It escapes the engine's version gate through the documented extension point
 * Zend/zend_extensions.c, which calls a zend_extension's
 * api_no_check()/build_id_check() callbacks *instead of* refusing to load on a
 * mismatch -- "allow extension to proclaim compatibility with any Zend
 * version". We declare a deliberately impossible version so that both
 * callbacks are always consulted, which makes the behavior identical on every
 * PHP rather than depending on which version we happened to compile against.
 *
 * Injecting a PHP app must degrade to "no instrumentation" rather than to a broken
 * application. No failure mode in this file that is allowed to abort
 * startup or take the host process down.
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "php.h"
#include "Zend/zend_extensions.h"

#include "otel_loader.h"

/* glibc 2.34 merged libdl into libc and re-versioned the dl* symbols. Linking
 * on a modern build image therefore stamps a GLIBC_2.34 requirement onto the
 * loader, which makes it refuse to load on anything older -- RHEL/UBI 8
 * (2.28), Debian bullseye (2.31) and the older PHP images among them. The
 * application still runs, because a zend_extension that fails to load is not
 * fatal, but the instrumentation is silently lost on exactly the long-lived
 * distros most likely to be running in production.
 *
 * glibc keeps the pre-2.34 symbol versions for backward compatibility, so
 * binding to those explicitly lets us build on a current, supported base image
 * and still load on old hosts. The baseline version is per-architecture: the
 * oldest version that ever existed on that ABI.
 *
 * Verified by php-loader/test-matrix.sh, which asserts the resulting binary
 * carries no GLIBC_2.34 requirement. */
#if defined(__GLIBC__) && !defined(__UCLIBC__)
#if defined(__x86_64__)
__asm__(".symver dladdr,dladdr@GLIBC_2.2.5");
__asm__(".symver dlopen,dlopen@GLIBC_2.2.5");
__asm__(".symver dlsym,dlsym@GLIBC_2.2.5");
__asm__(".symver dlclose,dlclose@GLIBC_2.2.5");
__asm__(".symver dlerror,dlerror@GLIBC_2.2.5");
#elif defined(__aarch64__)
__asm__(".symver dladdr,dladdr@GLIBC_2.17");
__asm__(".symver dlopen,dlopen@GLIBC_2.17");
__asm__(".symver dlsym,dlsym@GLIBC_2.17");
__asm__(".symver dlclose,dlclose@GLIBC_2.17");
__asm__(".symver dlerror,dlerror@GLIBC_2.17");
#endif
#endif

static otel_host_info otel_host = {0};
static otel_install_info otel_install = {0};

/* ------------------------------------------------------------------------ */
/* Logging                                                                    */
/* ------------------------------------------------------------------------ */

/* Deliberately stderr and not php_log_err/php_error_docref: the first two
 * callbacks run before the engine is in a state where those are safe. */

otel_log_level otel_current_log_level(void)
{
    static int cached = -1;
    if (cached >= 0) {
        return (otel_log_level)cached;
    }

    const char *raw = getenv(OTEL_LOADER_LOG_LEVEL_ENV);
    if (raw == NULL || raw[0] == '\0') {
        raw = getenv(OTEL_INJECTOR_LOG_LEVEL_ENV);
    }

    otel_log_level level = OTEL_LOG_WARN;
    if (raw != NULL && raw[0] != '\0') {
        if (strcasecmp(raw, "debug") == 0) {
            level = OTEL_LOG_DEBUG;
        } else if (strcasecmp(raw, "info") == 0) {
            level = OTEL_LOG_INFO;
        } else if (strcasecmp(raw, "warn") == 0 || strcasecmp(raw, "warning") == 0) {
            level = OTEL_LOG_WARN;
        } else if (strcasecmp(raw, "error") == 0) {
            level = OTEL_LOG_ERROR;
        } else if (strcasecmp(raw, "none") == 0 || strcasecmp(raw, "off") == 0) {
            level = OTEL_LOG_NONE;
        }
    }

    cached = (int)level;
    return level;
}

void otel_log(otel_log_level level, const char *fmt, ...)
{
    if (level < otel_current_log_level() || level == OTEL_LOG_NONE) {
        return;
    }

    static const char *const names[] = {"debug", "info", "warn", "error"};
    fprintf(stderr, "[otel-php-loader] [%6d] [%s] ", (int)getpid(), names[level]);

    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);

    fputc('\n', stderr);
    fflush(stderr);
}

/* ------------------------------------------------------------------------ */
/* Build id parsing                                                           */
/* ------------------------------------------------------------------------ */

/* The host hands us its ZEND_EXTENSION_BUILD_ID, whose grammar per
 * Zend/zend_build.h is:
 *
 *   "API" <ZEND_EXTENSION_API_NO> ZEND_BUILD_TS ZEND_BUILD_DEBUG
 *         ZEND_BUILD_SYSTEM ZEND_BUILD_EXTRA
 *     ZEND_BUILD_TS     = ",TS" | ",NTS"            (always present)
 *     ZEND_BUILD_DEBUG  = ",debug" | ""
 *     ZEND_BUILD_SYSTEM = "," PHP_COMPILER_ID | ""  (e.g. ",x86_64-linux-gnu")
 *     ZEND_BUILD_EXTRA  = ""                        (vendor-settable)
 *
 * The thread-safety field is NOT terminal. Anchoring on the whole string, or
 * assuming it ends after TS/NTS, fails on exactly the distro and debug builds
 * most likely to be in production -- so parse it as a prefix and ignore any
 * trailing fields we do not recognise.
 *
 * Returns 1 on success, 0 if the string does not match the grammar. */
int otel_parse_build_id(const char *build_id, otel_host_info *out)
{
    if (build_id == NULL || out == NULL) {
        return 0;
    }

    const char *p = build_id;
    if (strncmp(p, "API", 3) != 0) {
        return 0;
    }
    p += 3;

    if (*p < '0' || *p > '9') {
        return 0;
    }
    long api = 0;
    while (*p >= '0' && *p <= '9') {
        api = api * 10 + (*p - '0');
        if (api > 2147483647L) {
            return 0;
        }
        p++;
    }

    if (*p != ',') {
        return 0;
    }
    p++;

    /* ",NTS" must be tested before ",TS" would ever be ambiguous; they differ
     * in the first character, so order is not load-bearing, but the delimiter
     * check is: "TSX" must not be accepted as "TS". */
    if (strncmp(p, "NTS", 3) == 0 && (p[3] == '\0' || p[3] == ',')) {
        out->thread_safety = OTEL_TS_NTS;
        p += 3;
    } else if (strncmp(p, "TS", 2) == 0 && (p[2] == '\0' || p[2] == ',')) {
        out->thread_safety = OTEL_TS_ZTS;
        p += 2;
    } else {
        return 0;
    }

    /* Any remaining comma-separated fields are optional and mostly ignored;
     * we only care whether this is a debug build, because that changes the
     * artifact we would need. */
    out->debug_build = 0;
    while (*p == ',') {
        p++;
        const char *start = p;
        while (*p != '\0' && *p != ',') {
            p++;
        }
        size_t len = (size_t)(p - start);
        if (len == 5 && strncmp(start, "debug", 5) == 0) {
            out->debug_build = 1;
        }
    }

    out->zend_extension_api_no = (int)api;
    /* The Zend extension API number is the PHP module API number with a
     * version-era prefix: 420210902 -> 20210902. The module API number is what
     * keys the artifact directories. */
    out->module_api_no = (int)(api % 100000000L);

    snprintf(out->build_id, sizeof(out->build_id), "%s", build_id);
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Install path discovery                                                     */
/* ------------------------------------------------------------------------ */

/* The injector decides which libc flavor applies and encodes that decision in
 * *which* loader binary its generated ini points at:
 *
 *     <root>/<libc>/otel_loader.so
 *
 * Recovering the flavor from our own path therefore reuses the injector's
 * detection (src/libc.zig) instead of re-implementing it, and the two can
 * never disagree. A second, independent musl probe here would be a second
 * source of truth, which is precisely the bug we are avoiding.
 *
 * Returns 1 on success, 0 if the path is not shaped as expected. */
int otel_resolve_install_info(otel_install_info *out)
{
    if (out == NULL) {
        return 0;
    }
    out->resolved = 0;

    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr((void *)(uintptr_t)&otel_resolve_install_info, &info) == 0 ||
        info.dli_fname == NULL || info.dli_fname[0] == '\0') {
        otel_log(OTEL_LOG_ERROR, "cannot determine the loader's own path via dladdr(); standing down");
        return 0;
    }

    if (info.dli_fname[0] != '/') {
        otel_log(OTEL_LOG_ERROR,
                 "the loader was loaded from a relative path (\"%s\"); the zend_extension directive must use "
                 "an absolute path. Standing down.",
                 info.dli_fname);
        return 0;
    }

    char path[sizeof(out->root) + 64];
    if (snprintf(path, sizeof(path), "%s", info.dli_fname) >= (int)sizeof(path)) {
        otel_log(OTEL_LOG_ERROR, "the loader's own path is too long to process; standing down");
        return 0;
    }

    /* Strip "/otel_loader.so" to get <root>/<libc>. */
    char *last_slash = strrchr(path, '/');
    if (last_slash == NULL || last_slash == path) {
        otel_log(OTEL_LOG_ERROR, "unexpected loader path \"%s\"; standing down", info.dli_fname);
        return 0;
    }
    *last_slash = '\0';

    /* Split <root>/<libc> into its two halves. */
    char *flavor_slash = strrchr(path, '/');
    if (flavor_slash == NULL || flavor_slash == path) {
        otel_log(OTEL_LOG_ERROR, "unexpected loader path \"%s\"; standing down", info.dli_fname);
        return 0;
    }
    *flavor_slash = '\0';
    const char *flavor = flavor_slash + 1;

    if (strcmp(flavor, "glibc") != 0 && strcmp(flavor, "musl") != 0) {
        otel_log(OTEL_LOG_ERROR,
                 "the loader's parent directory is \"%s\", which is neither \"glibc\" nor \"musl\"; the install "
                 "layout is <root>/<libc>/otel_loader.so. Standing down rather than guessing the libc flavor.",
                 flavor);
        return 0;
    }
    snprintf(out->libc_flavor, sizeof(out->libc_flavor), "%s", flavor);

    /* The root is overridable for tests only; the libc flavor never is,
     * because it is the injector's decision and not ours to second-guess. */
    const char *root_override = getenv(OTEL_LOADER_ROOT_ENV);
    if (root_override != NULL && root_override[0] == '/') {
        snprintf(out->root, sizeof(out->root), "%s", root_override);
        otel_log(OTEL_LOG_INFO, "artifact root overridden via %s to \"%s\"", OTEL_LOADER_ROOT_ENV, out->root);
    } else {
        snprintf(out->root, sizeof(out->root), "%s", path);
    }

    out->resolved = 1;
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Artifact resolution and dispatch                                           */
/* ------------------------------------------------------------------------ */

typedef zend_module_entry *(*otel_get_module_fn)(void);

static void *otel_handle = NULL;
static char otel_autoload_path[1536] = {0};
static char otel_bootstrap_code[1792] = {0};
static char otel_module_build_id_buf[256] = {0};
static int otel_bootstrap_enabled = 0;

/* Reconstructs the host's ZEND_MODULE_BUILD_ID from its ZEND_EXTENSION_BUILD_ID.
 *
 * The two differ only in the API number they embed -- both are
 *   "API" <api no> ZEND_BUILD_TS ZEND_BUILD_DEBUG ZEND_BUILD_SYSTEM ZEND_BUILD_EXTRA
 * expanded from the same macros -- so swapping the Zend extension API number
 * for the module API number yields the module build id exactly. We need it
 * because the module build id is what a loaded extension's module entry
 * carries, and comparing the two is the check that stops us activating an
 * extension built for a different PHP.
 *
 * Returns 1 on success. */
int otel_module_build_id(const otel_host_info *host, char *out, size_t out_len)
{
    if (host == NULL || out == NULL) {
        return 0;
    }
    if (strncmp(host->build_id, "API", 3) != 0) {
        return 0;
    }
    const char *suffix = host->build_id + 3;
    while (*suffix >= '0' && *suffix <= '9') {
        suffix++;
    }
    int written = snprintf(out, out_len, "API%d%s", host->module_api_no, suffix);
    return written > 0 && (size_t)written < out_len;
}

/* Refuses to co-load with extensions that hook the same engine internals. */
static int otel_has_conflicting_extension(void)
{
    static const char *const conflicts[] = OTEL_CONFLICTING_EXTENSIONS;
    for (size_t i = 0; i < sizeof(conflicts) / sizeof(conflicts[0]); i++) {
        if (zend_get_extension(conflicts[i]) != NULL ||
            zend_hash_str_exists(&module_registry, conflicts[i], strlen(conflicts[i]))) {
            otel_log(OTEL_LOG_WARN,
                     "\"%s\" is loaded; standing down rather than co-loading with it", conflicts[i]);
            return 1;
        }
    }
    return 0;
}

/* Loads <root>/<api>/<libc>/<zts|non-zts>/opentelemetry.so and starts it.
 * Returns 1 if the extension is now active. */
static int otel_load_extension(void)
{
    const char *thread_dir = otel_host.thread_safety == OTEL_TS_ZTS ? "zts" : "non-zts";

    char variant_dir[1280];
    if (snprintf(variant_dir, sizeof(variant_dir), "%s/%d/%s/%s", otel_install.root, otel_host.module_api_no,
                 otel_install.libc_flavor, thread_dir) >= (int)sizeof(variant_dir)) {
        otel_log(OTEL_LOG_ERROR, "the artifact path is too long; standing down");
        return 0;
    }

    char extension_path[1536];
    snprintf(extension_path, sizeof(extension_path), "%s/opentelemetry.so", variant_dir);
    snprintf(otel_autoload_path, sizeof(otel_autoload_path), "%s/autoload.php", variant_dir);

    /* A PHP newer than anything we ship artifacts for lands here. It passed
     * every version check -- we simply have nothing built for it. Failing on
     * artifact lookup rather than on version recognition is deliberate: it
     * means a new PHP release loses instrumentation until the artifacts catch
     * up, instead of losing it until the loader is rebuilt. */
    if (access(extension_path, R_OK) != 0) {
        otel_log(OTEL_LOG_INFO,
                 "no OpenTelemetry artifacts for this PHP at \"%s\"; the application will run uninstrumented",
                 extension_path);
        return 0;
    }
    if (access(otel_autoload_path, R_OK) != 0) {
        otel_log(OTEL_LOG_ERROR, "\"%s\" exists but \"%s\" does not; the artifact tree is incomplete, standing down",
                 extension_path, otel_autoload_path);
        return 0;
    }

    /* The bootstrap runs through zend_eval_string, so the path is embedded in
     * PHP source. Refuse anything that could terminate the string literal
     * rather than attempting to escape it. */
    if (strchr(otel_autoload_path, '\'') != NULL || strchr(otel_autoload_path, '\\') != NULL) {
        otel_log(OTEL_LOG_ERROR, "the artifact path \"%s\" contains a quote or backslash; standing down",
                 otel_autoload_path);
        return 0;
    }
    if (snprintf(otel_bootstrap_code, sizeof(otel_bootstrap_code),
                 "try { require '%s'; } catch (\\Throwable $e) {}", otel_autoload_path) >=
        (int)sizeof(otel_bootstrap_code)) {
        otel_log(OTEL_LOG_ERROR, "the bootstrap snippet is too long; standing down");
        return 0;
    }

    if (!otel_module_build_id(&otel_host, otel_module_build_id_buf, sizeof(otel_module_build_id_buf))) {
        otel_log(OTEL_LOG_ERROR, "cannot derive the host module build id; standing down");
        return 0;
    }

    otel_handle = dlopen(extension_path, RTLD_NOW | RTLD_GLOBAL);
    if (otel_handle == NULL) {
        otel_log(OTEL_LOG_ERROR, "cannot load \"%s\": %s", extension_path, dlerror());
        return 0;
    }

    otel_get_module_fn get_module = (otel_get_module_fn)(uintptr_t)dlsym(otel_handle, "get_module");
    if (get_module == NULL) {
        otel_log(OTEL_LOG_ERROR, "\"%s\" has no get_module symbol; standing down", extension_path);
        dlclose(otel_handle);
        otel_handle = NULL;
        return 0;
    }

    zend_module_entry *module = get_module();
    if (module == NULL) {
        otel_log(OTEL_LOG_ERROR, "get_module() returned nothing; standing down");
        dlclose(otel_handle);
        otel_handle = NULL;
        return 0;
    }

    /* The engine performs these two checks in php_load_extension() when it
     * loads an `extension=` from an ini. We are bypassing that path, so if we
     * do not repeat them nothing does -- and activating an extension built
     * against a different PHP would not fail gracefully, it would corrupt the
     * engine. This is the single most important check in the loader. */
    if (module->zend_api != (unsigned int)otel_host.module_api_no) {
        otel_log(OTEL_LOG_ERROR,
                 "\"%s\" was built for module API %d but this PHP is module API %d; standing down",
                 extension_path, module->zend_api, otel_host.module_api_no);
        dlclose(otel_handle);
        otel_handle = NULL;
        return 0;
    }
    if (module->build_id == NULL || strcmp(module->build_id, otel_module_build_id_buf) != 0) {
        otel_log(OTEL_LOG_ERROR, "\"%s\" was built as \"%s\" but this PHP is \"%s\"; standing down", extension_path,
                 module->build_id ? module->build_id : "(null)", otel_module_build_id_buf);
        dlclose(otel_handle);
        otel_handle = NULL;
        return 0;
    }

    module->type = MODULE_PERSISTENT;
    module->module_number = zend_next_free_module();
    module->handle = otel_handle;

    /* zend_startup_module() rather than zend_register_module_ex(): the latter
     * gained a second parameter in PHP 8.4, so calling it from one binary that
     * must serve 8.1 through 8.5 would corrupt the stack on half of them. It
     * also would not be enough on its own -- zend_startup_modules() has
     * already run by the time a zend_extension starts up, so a merely
     * registered module would never receive its MINIT. zend_startup_module()
     * registers and starts in one call, and its signature is identical across
     * all supported versions. */
    if (zend_startup_module(module) != SUCCESS) {
        otel_log(OTEL_LOG_ERROR, "the engine refused to start \"%s\"; standing down", extension_path);
        dlclose(otel_handle);
        otel_handle = NULL;
        return 0;
    }

    otel_log(OTEL_LOG_INFO, "loaded \"%s\"", extension_path);
    return 1;
}

/* ------------------------------------------------------------------------ */
/* SDK bootstrap                                                              */
/* ------------------------------------------------------------------------ */

/* Runs the SDK's Composer autoloader at the start of every request.
 *
 * The upstream package bootstraps this with `auto_prepend_file` in its ini,
 * which is a single-valued, last-ini-wins directive: pointing it at our
 * autoload.php silently removes whatever the application had set there. Doing
 * it from a module's RINIT instead leaves auto_prepend_file untouched, so an
 * application that uses it keeps working -- that is the whole reason this
 * module exists.
 *
 * It must run after opentelemetry.so's own RINIT, so that the hook API is live
 * before the SDK registers instrumentation. Registration order in
 * module_registry determines activation order, and we register this module
 * after the dispatched one. */
static zend_result otel_bootstrap_rinit(int type, int module_number)
{
    (void)type;
    (void)module_number;

    if (!otel_bootstrap_enabled) {
        return SUCCESS;
    }

    /* Errors are contained in PHP-land rather than with zend_try/zend_catch.
     *
     * zend_try expands to EG(bailout), and EG() compiles completely
     * differently for NTS and ZTS -- a direct `executor_globals` reference
     * versus a TSRM offset lookup. A loader compiled once against NTS headers
     * that references any engine global therefore fails to load on every ZTS
     * PHP with "undefined symbol: executor_globals". Hence the rule this
     * enforces: THE LOADER MUST NOT TOUCH ENGINE GLOBALS, in any form. The
     * build asserts it; see Dockerfile.build.
     *
     * Giving up zend_try costs less than it looks. A PHP-level catch handles
     * the realistic failure -- a Throwable out of the SDK's autoloader -- and
     * a true bailout is already covered by the engine: php_request_startup()
     * wraps zend_activate_modules() in its own zend_try, so the request is
     * aborted cleanly instead of the process being taken down. */
    if (zend_eval_string(otel_bootstrap_code, NULL, "OpenTelemetry SDK bootstrap") != SUCCESS) {
        otel_log(OTEL_LOG_ERROR, "failed to bootstrap the OpenTelemetry SDK from \"%s\"; disabling it for this process",
                 otel_autoload_path);
        otel_bootstrap_enabled = 0;
    }

    return SUCCESS;
}

/* Built at runtime rather than declared statically: size, zend_api, zend_debug,
 * zts and build_id all have to describe the PHP we were loaded into, not the
 * one we were compiled against. */
static zend_module_entry otel_bootstrap_module;

static int otel_register_bootstrap_module(void)
{
    memset(&otel_bootstrap_module, 0, sizeof(otel_bootstrap_module));
    otel_bootstrap_module.size = sizeof(zend_module_entry);
    otel_bootstrap_module.zend_api = otel_host.module_api_no;
    otel_bootstrap_module.zend_debug = (unsigned char)otel_host.debug_build;
    otel_bootstrap_module.zts = (unsigned char)(otel_host.thread_safety == OTEL_TS_ZTS);
    otel_bootstrap_module.build_id = otel_module_build_id_buf;
    otel_bootstrap_module.name = "opentelemetry_bootstrap";
    otel_bootstrap_module.version = OTEL_LOADER_VERSION;
    otel_bootstrap_module.request_startup_func = otel_bootstrap_rinit;
    otel_bootstrap_module.type = MODULE_PERSISTENT;
    otel_bootstrap_module.module_number = zend_next_free_module();

    if (zend_startup_module(&otel_bootstrap_module) != SUCCESS) {
        otel_log(OTEL_LOG_ERROR, "could not register the SDK bootstrap module; standing down");
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Version gate escape                                                        */
/* ------------------------------------------------------------------------ */

/* Called by zend_load_extension_handle() when our declared API number does not
 * match the host's -- which, by construction, is always. Returning SUCCESS
 * tells the engine to load us anyway.
 *
 * This is also our only chance to learn the host's Zend extension API number,
 * so record it. */
static int otel_api_no_check(int api_no)
{
    otel_host.zend_extension_api_no = api_no;
    otel_host.module_api_no = api_no % 100000000;
    otel_host.api_seen = 1;

    otel_log(OTEL_LOG_DEBUG, "api_no_check: host zend extension API %d (module API %d)", api_no,
             otel_host.module_api_no);
    return SUCCESS;
}

/* Called next, with the host's ZEND_EXTENSION_BUILD_ID. This is where the
 * thread-safety flavor comes from; there is no other way to learn it from
 * inside a version-agnostic binary.
 *
 * Refusing here is the safest possible failure: the engine simply declines to
 * load us and the application runs uninstrumented. */
static int otel_build_id_check(const char *build_id)
{
    if (!otel_parse_build_id(build_id, &otel_host)) {
        otel_log(OTEL_LOG_ERROR, "cannot parse the host build id \"%s\"; declining to load", build_id ? build_id : "(null)");
        return FAILURE;
    }
    otel_host.build_id_seen = 1;

    otel_log(OTEL_LOG_DEBUG, "build_id_check: host build id \"%s\" -> module API %d, %s%s", build_id,
             otel_host.module_api_no, otel_host.thread_safety == OTEL_TS_ZTS ? "ZTS" : "NTS",
             otel_host.debug_build ? ", debug" : "");
    return SUCCESS;
}

/* ------------------------------------------------------------------------ */
/* Lifecycle                                                                  */
/* ------------------------------------------------------------------------ */

static int otel_loader_startup(zend_extension *extension)
{
    (void)extension;

    if (!otel_host.api_seen || !otel_host.build_id_seen) {
        /* Reachable only if a future engine stops calling one of the
         * callbacks. Any Unknown means stand down; never guess. */
        otel_log(OTEL_LOG_ERROR, "host API or build id was never reported (api_seen=%d, build_id_seen=%d); standing down",
                 otel_host.api_seen, otel_host.build_id_seen);
        return SUCCESS;
    }

    if (!otel_resolve_install_info(&otel_install)) {
        return SUCCESS;
    }

    otel_log(OTEL_LOG_DEBUG, "host: module API %d, %s%s | install: root=\"%s\", libc=%s",
             otel_host.module_api_no, otel_host.thread_safety == OTEL_TS_ZTS ? "zts" : "non-zts",
             otel_host.debug_build ? ", debug" : "", otel_install.root, otel_install.libc_flavor);

    if (otel_has_conflicting_extension()) {
        return SUCCESS;
    }

    if (!otel_load_extension()) {
        return SUCCESS;
    }

    /* Registered after the dispatched extension so that its RINIT runs after
     * opentelemetry.so's, which is what makes the hook API available before
     * the SDK bootstraps. */
    otel_bootstrap_enabled = 1;
    if (!otel_register_bootstrap_module()) {
        otel_bootstrap_enabled = 0;
    }

    return SUCCESS;
}

static void otel_loader_shutdown(zend_extension *extension)
{
    (void)extension;
    otel_log(OTEL_LOG_DEBUG, "shutdown");
}

/* ------------------------------------------------------------------------ */
/* Extension declaration                                                      */
/* ------------------------------------------------------------------------ */

/* Deliberately impossible version information.
 *
 * The ZEND_EXTENSION() macro would emit the API number and build id of
 * whatever PHP we compiled against, which would make us load silently on that
 * one version and route through the callbacks everywhere else -- two code
 * paths, one of them rarely exercised. Declaring {0, "0"} guarantees a
 * mismatch on every PHP, so every host takes the same, tested path. */
ZEND_DLEXPORT zend_extension_version_info extension_version_info = {0, "0"};

ZEND_DLEXPORT zend_extension zend_extension_entry = {
    OTEL_LOADER_NAME,
    OTEL_LOADER_VERSION,
    OTEL_LOADER_AUTHOR,
    OTEL_LOADER_URL,
    OTEL_LOADER_COPYRIGHT,
    otel_loader_startup,  /* startup   */
    otel_loader_shutdown, /* shutdown  */
    NULL,                 /* activate   */
    NULL,                 /* deactivate */
    NULL,                 /* message_handler     */
    NULL,                 /* op_array_handler    */
    NULL,                 /* statement_handler   */
    NULL,                 /* fcall_begin_handler */
    NULL,                 /* fcall_end_handler   */
    NULL,                 /* op_array_ctor */
    NULL,                 /* op_array_dtor */
    otel_api_no_check,    /* api_no_check   */
    otel_build_id_check,  /* build_id_check */
    NULL,                 /* op_array_persist_calc */
    NULL,                 /* op_array_persist      */
    NULL, NULL, NULL, NULL, /* reserved5..8 */
    NULL,                 /* handle          */
    0                     /* resource_number */
};
