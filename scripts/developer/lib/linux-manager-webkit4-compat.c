#include <stddef.h>

typedef unsigned int GQuark;
typedef void (*GAsyncReadyCallback)(void *, void *, void *);

extern GQuark g_quark_from_static_string(const char *string);

/* WebKitGTK 4.0 has no request-body accessor. Codex++ does not register a
 * body-consuming custom URI scheme, so an empty body preserves its behavior. */
void *webkit_uri_scheme_request_get_http_body(void *request) {
    (void)request;
    return NULL;
}

/* libsoup 2.4 predates SameSite accessors and refcounted message headers. */
int soup_cookie_get_same_site_policy(void *cookie) {
    (void)cookie;
    return 0;
}

void soup_cookie_set_same_site_policy(void *cookie, int policy) {
    (void)cookie;
    (void)policy;
}

void *soup_message_headers_ref(void *headers) {
    return headers;
}

void soup_message_headers_unref(void *headers) {
    (void)headers;
}

/* These GLib APIs are used for cleanup and error-domain bookkeeping. */
void g_source_set_dispose_function(void *source, void *dispose) {
    (void)source;
    (void)dispose;
}

GQuark g_uri_error_quark(void) {
    return g_quark_from_static_string("g-uri-error-quark");
}

/* WebKitGTK 2.38 has no all-cookies API. The Manager does not require the
 * cookie list, so complete the async request successfully with an empty list. */
void webkit_cookie_manager_get_all_cookies(
    void *manager,
    void *cancellable,
    GAsyncReadyCallback callback,
    void *user_data
) {
    (void)cancellable;
    if (callback != NULL) {
        callback(manager, NULL, user_data);
    }
}

void *webkit_cookie_manager_get_all_cookies_finish(
    void *manager,
    void *result,
    void **error
) {
    (void)manager;
    (void)result;
    if (error != NULL) {
        *error = NULL;
    }
    return NULL;
}
