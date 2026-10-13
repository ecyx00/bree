#include "include/GhosttyRuntimeTestStubs.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} GhosttyRuntimeTestColor;

typedef struct {
    GhosttyRuntimeTestColor foreground;
    bool has_foreground;
    uint32_t diagnostics_count;
} GhosttyRuntimeTestConfig;

static bool bree_test_needs_confirm_quit = false;
static uint64_t bree_test_foreground_pid = 0;
static const char* bree_test_tty_name = NULL;
static uint32_t bree_test_tty_name_call_count = 0;
static void* bree_test_renderer_realized_target = NULL;
static bool bree_test_renderer_realized_calls[16];
static uint32_t bree_test_renderer_realized_call_count = 0;
static uint32_t bree_test_renderer_rebuild_call_count = 0;
static bool bree_test_renderer_realized_result = true;
static bool bree_test_renderer_occlusion_visible = true;
static bool bree_test_renderer_release_was_occluded = false;
static void* bree_test_last_updated_surface = NULL;
static void* bree_test_font_surface = NULL;
static float bree_test_font_runtime_points = 0;
static float bree_test_font_configured_runtime_points = 0;
static bool bree_test_font_adjusted = false;
static bool bree_test_font_binding_succeeds = true;
static void* bree_test_font_callback_surface = NULL;
static ghostty_font_size_action_cb bree_test_font_callback = NULL;
static void* bree_test_font_callback_userdata = NULL;
static bool bree_test_surface_key_called = false;
static int bree_test_surface_key_mods_value = 0;
static uint32_t bree_test_surface_key_unshifted_codepoint_value = 0;
static char bree_test_surface_key_text_value[32];
static pthread_mutex_t bree_test_surface_free_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bree_test_surface_free_condition = PTHREAD_COND_INITIALIZER;
static bool bree_test_surface_free_should_block = false;
static bool bree_test_surface_free_started = false;
static bool bree_test_surface_free_released = false;
static void* bree_test_surface_free_target = NULL;
static pthread_mutex_t bree_test_process_output_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bree_test_process_output_condition = PTHREAD_COND_INITIALIZER;
static bool bree_test_process_output_should_block = false;
static bool bree_test_process_output_started = false;
static bool bree_test_process_output_released = false;
static bool bree_test_process_output_called_on_main = false;
static void* bree_test_process_output_target = NULL;

typedef void (*GhosttyRuntimeTestRenderPresentedCallback)(void*, uint64_t);
typedef void (*GhosttyRuntimeTestRenderFailedCallback)(void*, uint64_t, int);
typedef struct {
    void* surface;
    GhosttyRuntimeTestRenderPresentedCallback presented;
    void* presented_userdata;
    GhosttyRuntimeTestRenderFailedCallback failed;
    void* failed_userdata;
    uint64_t pending_token;
    bool has_pending_token;
} GhosttyRuntimeTestRenderCallbacks;

static GhosttyRuntimeTestRenderCallbacks bree_test_render_callbacks[32];

static GhosttyRuntimeTestRenderCallbacks* bree_test_render_callbacks_for(void* surface) {
    for (size_t index = 0; index < sizeof(bree_test_render_callbacks) / sizeof(bree_test_render_callbacks[0]); index++) {
        if (bree_test_render_callbacks[index].surface == surface) {
            return &bree_test_render_callbacks[index];
        }
    }
    for (size_t index = 0; index < sizeof(bree_test_render_callbacks) / sizeof(bree_test_render_callbacks[0]); index++) {
        if (bree_test_render_callbacks[index].surface == NULL) {
            bree_test_render_callbacks[index].surface = surface;
            return &bree_test_render_callbacks[index];
        }
    }
    return NULL;
}

static void bree_test_render_callbacks_clear(void* surface) {
    for (size_t index = 0; index < sizeof(bree_test_render_callbacks) / sizeof(bree_test_render_callbacks[0]); index++) {
        if (bree_test_render_callbacks[index].surface == surface) {
            memset(&bree_test_render_callbacks[index], 0, sizeof(bree_test_render_callbacks[index]));
            return;
        }
    }
}

static struct timespec bree_test_surface_free_timeout(void) {
    return (struct timespec) {
        .tv_sec = 5,
        .tv_nsec = 0,
    };
}

void bree_test_ghostty_runtime_stubs_reset(void) {
    bree_test_needs_confirm_quit = false;
    bree_test_foreground_pid = 0;
    bree_test_tty_name = NULL;
    bree_test_tty_name_call_count = 0;
    bree_test_surface_key_called = false;
    bree_test_surface_key_mods_value = 0;
    bree_test_surface_key_unshifted_codepoint_value = 0;
    bree_test_surface_key_text_value[0] = '\0';
}

void bree_test_ghostty_surface_key_reset(void) {
    bree_test_surface_key_called = false;
    bree_test_surface_key_mods_value = 0;
    bree_test_surface_key_unshifted_codepoint_value = 0;
    bree_test_surface_key_text_value[0] = '\0';
}

bool bree_test_ghostty_surface_key_was_called(void) {
    return bree_test_surface_key_called;
}

int bree_test_ghostty_surface_key_mods(void) {
    return bree_test_surface_key_mods_value;
}

uint32_t bree_test_ghostty_surface_key_unshifted_codepoint(void) {
    return bree_test_surface_key_unshifted_codepoint_value;
}

const char* bree_test_ghostty_surface_key_text(void) {
    return bree_test_surface_key_text_value;
}

void bree_test_ghostty_surface_free_blocking_begin(void *surface) {
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    bree_test_surface_free_should_block = true;
    bree_test_surface_free_started = false;
    bree_test_surface_free_released = false;
    bree_test_surface_free_target = surface;
    pthread_mutex_unlock(&bree_test_surface_free_mutex);
}

bool bree_test_ghostty_surface_free_wait_until_started(void) {
    const struct timespec timeout = bree_test_surface_free_timeout();
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    while (!bree_test_surface_free_started) {
        const int result = pthread_cond_timedwait_relative_np(
            &bree_test_surface_free_condition,
            &bree_test_surface_free_mutex,
            &timeout
        );
        if (result != 0) break;
    }
    const bool started = bree_test_surface_free_started;
    pthread_mutex_unlock(&bree_test_surface_free_mutex);
    return started;
}

bool bree_test_ghostty_surface_free_blocking_did_start(void) {
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    const bool started = bree_test_surface_free_started;
    pthread_mutex_unlock(&bree_test_surface_free_mutex);
    return started;
}

bool bree_test_ghostty_surface_free_blocking_is_active(void) {
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    const bool active =
        bree_test_surface_free_should_block
        && bree_test_surface_free_started
        && !bree_test_surface_free_released
        && bree_test_surface_free_target != NULL;
    pthread_mutex_unlock(&bree_test_surface_free_mutex);
    return active;
}

void bree_test_ghostty_surface_free_release(void) {
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    bree_test_surface_free_released = true;
    pthread_cond_broadcast(&bree_test_surface_free_condition);
    pthread_mutex_unlock(&bree_test_surface_free_mutex);
}

void bree_test_ghostty_surface_free_blocking_reset(void) {
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    bree_test_surface_free_should_block = false;
    bree_test_surface_free_started = false;
    bree_test_surface_free_released = true;
    bree_test_surface_free_target = NULL;
    pthread_cond_broadcast(&bree_test_surface_free_condition);
    pthread_mutex_unlock(&bree_test_surface_free_mutex);
}

void bree_test_ghostty_process_output_blocking_begin(void *surface) {
    pthread_mutex_lock(&bree_test_process_output_mutex);
    bree_test_process_output_should_block = true;
    bree_test_process_output_started = false;
    bree_test_process_output_released = false;
    bree_test_process_output_called_on_main = false;
    bree_test_process_output_target = surface;
    pthread_mutex_unlock(&bree_test_process_output_mutex);
}

bool bree_test_ghostty_process_output_wait_until_started(void) {
    const struct timespec timeout = bree_test_surface_free_timeout();
    pthread_mutex_lock(&bree_test_process_output_mutex);
    while (!bree_test_process_output_started) {
        const int result = pthread_cond_timedwait_relative_np(
            &bree_test_process_output_condition,
            &bree_test_process_output_mutex,
            &timeout
        );
        if (result != 0) break;
    }
    const bool started = bree_test_process_output_started;
    pthread_mutex_unlock(&bree_test_process_output_mutex);
    return started;
}

bool bree_test_ghostty_process_output_called_on_main_thread(void) {
    pthread_mutex_lock(&bree_test_process_output_mutex);
    const bool called_on_main = bree_test_process_output_called_on_main;
    pthread_mutex_unlock(&bree_test_process_output_mutex);
    return called_on_main;
}

void bree_test_ghostty_process_output_release(void) {
    pthread_mutex_lock(&bree_test_process_output_mutex);
    bree_test_process_output_released = true;
    pthread_cond_broadcast(&bree_test_process_output_condition);
    pthread_mutex_unlock(&bree_test_process_output_mutex);
}

void bree_test_ghostty_process_output_blocking_reset(void) {
    pthread_mutex_lock(&bree_test_process_output_mutex);
    bree_test_process_output_should_block = false;
    bree_test_process_output_started = false;
    bree_test_process_output_released = true;
    bree_test_process_output_called_on_main = false;
    bree_test_process_output_target = NULL;
    pthread_cond_broadcast(&bree_test_process_output_condition);
    pthread_mutex_unlock(&bree_test_process_output_mutex);
}

void bree_test_ghostty_renderer_realized_begin(void* surface) {
    bree_test_renderer_realized_target = surface;
    bree_test_renderer_realized_call_count = 0;
    bree_test_renderer_rebuild_call_count = 0;
    bree_test_renderer_realized_result = true;
    bree_test_renderer_occlusion_visible = true;
    bree_test_renderer_release_was_occluded = false;
}

void bree_test_ghostty_renderer_realized_reset(void) {
    bree_test_renderer_realized_target = NULL;
    bree_test_renderer_realized_call_count = 0;
    bree_test_renderer_rebuild_call_count = 0;
    bree_test_renderer_realized_result = true;
    bree_test_renderer_occlusion_visible = true;
    bree_test_renderer_release_was_occluded = false;
}

bool bree_test_ghostty_renderer_occlusion_visible(void) {
    return bree_test_renderer_occlusion_visible;
}

void bree_test_ghostty_runtime_stubs_set_close_state(bool needs_confirm, uint64_t foreground_pid, const char* tty_name) {
    bree_test_needs_confirm_quit = needs_confirm;
    bree_test_foreground_pid = foreground_pid;
    bree_test_tty_name = tty_name;
}

uint32_t bree_test_ghostty_renderer_realized_call_count(void) {
    return bree_test_renderer_realized_call_count;
}

uint32_t bree_test_ghostty_renderer_rebuild_call_count(void) {
    return bree_test_renderer_rebuild_call_count;
}

bool bree_test_ghostty_renderer_realized_call_value(uint32_t index) {
    if (index >= bree_test_renderer_realized_call_count) return false;
    return bree_test_renderer_realized_calls[index];
}

void bree_test_ghostty_renderer_realized_set_result(bool result) {
    bree_test_renderer_realized_result = result;
}

bool bree_test_ghostty_renderer_release_was_occluded(void) {
    return bree_test_renderer_release_was_occluded;
}

bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

bool ghostty_surface_read_selection_clipboard_text(
    void *surface,
    uintptr_t max_bytes,
    ghostty_text_s *selection
) {
    (void)surface;
    (void)max_bytes;
    if (selection != NULL) {
        *selection = (ghostty_text_s){0};
    }
    return false;
}

// GhosttyRuntimeCInterop.initialize() in BreeTerminalCore references
// ghostty_init directly, so this test runner needs a definition to link.
int ghostty_init(uintptr_t argc, char **argv) {
    (void)argc;
    (void)argv;
    return 0;
}

void *ghostty_config_new(void) {
    return calloc(1, sizeof(GhosttyRuntimeTestConfig));
}

void ghostty_config_free(void *config) {
    free(config);
}

void ghostty_config_load_string(
    void *raw_config,
    const char *contents,
    uintptr_t contents_len,
    const char *path
) {
    (void)contents_len;
    (void)path;
    GhosttyRuntimeTestConfig *config = raw_config;
    const char *value = strchr(contents, '=');
    if (config == NULL || value == NULL) return;
    do { value++; } while (*value == ' ' || *value == '\t');

    if (strcasecmp(value, "black") == 0) {
        config->foreground = (GhosttyRuntimeTestColor){0, 0, 0};
        config->has_foreground = true;
        return;
    }

    config->diagnostics_count = 1;
}

ghostty_string_s ghostty_config_serialize(void *raw_config) {
    const GhosttyRuntimeTestConfig *config = raw_config;
    if (config == NULL) {
        return (ghostty_string_s){0};
    }

    const int length = snprintf(
        NULL,
        0,
        "foreground=%u,%u,%u;has=%u;diagnostics=%u",
        config->foreground.r,
        config->foreground.g,
        config->foreground.b,
        (unsigned)config->has_foreground,
        config->diagnostics_count
    );
    if (length < 0) {
        return (ghostty_string_s){0};
    }
    char *serialized = malloc((size_t)length + 1);
    if (serialized == NULL) {
        return (ghostty_string_s){0};
    }
    snprintf(
        serialized,
        (size_t)length + 1,
        "foreground=%u,%u,%u;has=%u;diagnostics=%u",
        config->foreground.r,
        config->foreground.g,
        config->foreground.b,
        (unsigned)config->has_foreground,
        config->diagnostics_count
    );
    return (ghostty_string_s){
        .ptr = serialized,
        .len = (uintptr_t)length,
        .sentinel = true,
    };
}

bool ghostty_config_get(
    void *raw_config,
    void *raw_value,
    const char *key,
    uintptr_t key_len
) {
    GhosttyRuntimeTestConfig *config = raw_config;
    if (config == NULL || raw_value == NULL || !config->has_foreground ||
        key_len != strlen("foreground") || strncmp(key, "foreground", key_len) != 0) {
        return false;
    }
    *(GhosttyRuntimeTestColor *)raw_value = config->foreground;
    return true;
}

uint32_t ghostty_config_diagnostics_count(void *raw_config) {
    GhosttyRuntimeTestConfig *config = raw_config;
    return config == NULL ? 0 : config->diagnostics_count;
}

void ghostty_config_get_diagnostic(void) {}
void ghostty_string_free(ghostty_string_s string) {
    if (string.sentinel) {
        free((void *)string.ptr);
    }
}
bool ghostty_surface_binding_action(
    void *surface,
    const char *action,
    uintptr_t action_len
) {
    if (surface == bree_test_font_surface) {
        if (!bree_test_font_binding_succeeds) return false;
        const float previous_points =
            bree_test_font_runtime_points;
        const bool previous_adjusted =
            bree_test_font_adjusted;
        int32_t observed_action = -1;
        char buffer[128];
        const uintptr_t copy_len =
            action_len < sizeof(buffer) - 1
                ? action_len
                : sizeof(buffer) - 1;
        memcpy(buffer, action, copy_len);
        buffer[copy_len] = '\0';
        const char *set_prefix = "set_font_size:";
        if (strncmp(
                buffer,
                set_prefix,
                strlen(set_prefix)
            ) == 0) {
            bree_test_font_runtime_points =
                strtof(buffer + strlen(set_prefix), NULL);
            if (bree_test_font_runtime_points > 255) {
                bree_test_font_runtime_points = 255;
            }
            if (bree_test_font_runtime_points < 1) {
                bree_test_font_runtime_points = 1;
            }
            bree_test_font_adjusted = true;
            observed_action = 3;
        } else if (strcmp(buffer, "reset_font_size") == 0) {
            bree_test_font_runtime_points =
                bree_test_font_configured_runtime_points;
            bree_test_font_adjusted = false;
            observed_action = 2;
        } else if (strncmp(buffer, "increase_font_size:", 19) == 0) {
            bree_test_font_runtime_points += strtof(buffer + 19, NULL);
            if (bree_test_font_runtime_points > 255) {
                bree_test_font_runtime_points = 255;
            }
            bree_test_font_adjusted = true;
            observed_action = 0;
        } else if (strncmp(buffer, "decrease_font_size:", 19) == 0) {
            bree_test_font_runtime_points -= strtof(buffer + 19, NULL);
            if (bree_test_font_runtime_points < 1) {
                bree_test_font_runtime_points = 1;
            }
            bree_test_font_adjusted = true;
            observed_action = 1;
        }
        if (observed_action >= 0
            && bree_test_font_callback_surface == surface
            && bree_test_font_callback != NULL) {
            bree_test_font_callback(
                bree_test_font_callback_userdata,
                observed_action,
                previous_points,
                bree_test_font_runtime_points,
                previous_adjusted,
                bree_test_font_adjusted);
        }
    }
    return true;
}

bool ghostty_surface_set_font_size_action_callback(
    void *surface,
    ghostty_font_size_action_cb callback,
    void *userdata
) {
    if (surface == NULL || callback == NULL) return false;
    bree_test_font_callback_surface = surface;
    bree_test_font_callback = callback;
    bree_test_font_callback_userdata = userdata;
    return true;
}

void ghostty_surface_config_new(void) {}
void ghostty_surface_free(void *surface) {
    const struct timespec timeout = bree_test_surface_free_timeout();
    pthread_mutex_lock(&bree_test_surface_free_mutex);
    if (bree_test_surface_free_should_block
        && surface == bree_test_surface_free_target) {
        bree_test_surface_free_started = true;
        pthread_cond_broadcast(&bree_test_surface_free_condition);
        while (!bree_test_surface_free_released) {
            const int result = pthread_cond_timedwait_relative_np(
                &bree_test_surface_free_condition,
                &bree_test_surface_free_mutex,
                &timeout
            );
            if (result != 0) break;
        }
        bree_test_surface_free_should_block = false;
        bree_test_surface_free_target = NULL;
    }
    pthread_mutex_unlock(&bree_test_surface_free_mutex);

    if (bree_test_font_callback_surface == surface) {
        bree_test_font_callback_surface = NULL;
        bree_test_font_callback = NULL;
        bree_test_font_callback_userdata = NULL;
    }
    bree_test_render_callbacks_clear(surface);
}
void ghostty_surface_free_text(void) {}
float ghostty_surface_font_size(void *surface) {
    return surface == bree_test_font_surface
        ? bree_test_font_runtime_points
        : 0;
}
bool ghostty_surface_font_size_adjusted(void *surface) {
    return surface == bree_test_font_surface
        && bree_test_font_adjusted;
}
uint64_t ghostty_surface_foreground_pid(void *surface) {
    (void)surface;
    return bree_test_foreground_pid;
}
bool ghostty_surface_grid_metrics(void *surface, void *metrics) {
    (void)surface;
    (void)metrics;
    return false;
}
void ghostty_surface_has_selection(void) {}
bool ghostty_surface_key(void *surface, bree_test_ghostty_input_key_s key_event) {
    (void)surface;
    // Keep the capture focused on the press. Synthetic named keys may also
    // send a release, which should not erase the fields under test.
    if (key_event.action != 1) {
        return true;
    }
    bree_test_surface_key_called = true;
    bree_test_surface_key_mods_value = key_event.mods;
    bree_test_surface_key_unshifted_codepoint_value = key_event.unshifted_codepoint;
    if (key_event.text != NULL) {
        strncpy(bree_test_surface_key_text_value, key_event.text, sizeof(bree_test_surface_key_text_value) - 1);
        bree_test_surface_key_text_value[sizeof(bree_test_surface_key_text_value) - 1] = '\0';
    } else {
        bree_test_surface_key_text_value[0] = '\0';
    }
    return true;
}
void ghostty_surface_mouse_button(void) {}
void ghostty_surface_mouse_pos(void) {}
void ghostty_surface_mouse_scroll(void) {}
bool ghostty_surface_needs_confirm_quit(void *surface) {
    (void)surface;
    return bree_test_needs_confirm_quit;
}
void ghostty_surface_new(void) {}
bool ghostty_surface_process_exited(void *surface) {
    (void)surface;
    return false;
}
void ghostty_surface_process_output(void *surface, const char *data, uintptr_t len) {
    (void)data;
    (void)len;
    pthread_mutex_lock(&bree_test_process_output_mutex);
    if (bree_test_process_output_should_block
        && surface == bree_test_process_output_target) {
        bree_test_process_output_started = true;
        bree_test_process_output_called_on_main = pthread_main_np() != 0;
        pthread_cond_broadcast(&bree_test_process_output_condition);
        while (!bree_test_process_output_released) {
            const struct timespec timeout = bree_test_surface_free_timeout();
            const int result = pthread_cond_timedwait_relative_np(
                &bree_test_process_output_condition,
                &bree_test_process_output_mutex,
                &timeout
            );
            if (result != 0) break;
        }
        bree_test_process_output_should_block = false;
        bree_test_process_output_target = NULL;
    }
    pthread_mutex_unlock(&bree_test_process_output_mutex);
}
void ghostty_surface_quicklook_font(void) {}
void ghostty_surface_read_screen_tail_vt(void) {}
void ghostty_surface_read_text(void) {}
void ghostty_surface_refresh(void) {}
bool ghostty_surface_set_render_presented_callback(
    void *surface,
    void (*callback)(void *, uint64_t),
    void *userdata
) {
    if (surface == NULL || callback == NULL) return false;
    GhosttyRuntimeTestRenderCallbacks* callbacks = bree_test_render_callbacks_for(surface);
    if (callbacks == NULL || callbacks->presented != NULL) return false;
    callbacks->presented = callback;
    callbacks->presented_userdata = userdata;
    return true;
}
bool ghostty_surface_set_render_failed_callback(
    void *surface,
    void (*callback)(void *, uint64_t, int),
    void *userdata
) {
    if (surface == NULL || callback == NULL) return false;
    GhosttyRuntimeTestRenderCallbacks* callbacks = bree_test_render_callbacks_for(surface);
    if (callbacks == NULL || callbacks->failed != NULL) return false;
    callbacks->failed = callback;
    callbacks->failed_userdata = userdata;
    return true;
}
bool ghostty_surface_request_render_with_token(void *surface, uint64_t token) {
    GhosttyRuntimeTestRenderCallbacks* callbacks = bree_test_render_callbacks_for(surface);
    if (callbacks == NULL || callbacks->presented == NULL) return false;
    if (callbacks->has_pending_token) return false;
    callbacks->pending_token = token;
    callbacks->has_pending_token = true;
    return true;
}

bool bree_test_ghostty_renderer_present(void* surface) {
    GhosttyRuntimeTestRenderCallbacks* callbacks = bree_test_render_callbacks_for(surface);
    if (callbacks == NULL || callbacks->presented == NULL || !callbacks->has_pending_token) return false;
    const uint64_t token = callbacks->pending_token;
    callbacks->has_pending_token = false;
    callbacks->presented(callbacks->presented_userdata, token);
    return true;
}

bool bree_test_ghostty_renderer_fail(void* surface, int status) {
    GhosttyRuntimeTestRenderCallbacks* callbacks = bree_test_render_callbacks_for(surface);
    if (callbacks == NULL || callbacks->failed == NULL || !callbacks->has_pending_token) return false;
    const uint64_t token = callbacks->pending_token;
    callbacks->has_pending_token = false;
    callbacks->failed(callbacks->failed_userdata, token, status);
    return true;
}
void ghostty_surface_render_grid_json(void) {}
void ghostty_surface_render_grid_json_with_theme(void) {}
ghostty_string_s ghostty_surface_render_grid_json_v2(
    void *surface,
    const char *surface_id,
    uintptr_t surface_id_len,
    uint64_t state_seq,
    uintptr_t scrollback_lines,
    bool include_theme,
    bool anchor_active) {
    (void)surface;
    (void)surface_id;
    (void)surface_id_len;
    (void)state_seq;
    (void)scrollback_lines;
    (void)include_theme;
    (void)anchor_active;
    return (ghostty_string_s){0};
}
void ghostty_surface_set_content_scale(void) {}
void ghostty_surface_set_display_id(void) {}
void ghostty_surface_set_focus(void) {}
void ghostty_surface_set_occlusion(void *surface, bool visible) {
    if (surface != bree_test_renderer_realized_target) return;
    bree_test_renderer_occlusion_visible = visible;
}
bool ghostty_surface_set_renderer_realized(void *surface, bool realized) {
    if (surface != bree_test_renderer_realized_target) return true;
    if (!realized) {
        bree_test_renderer_release_was_occluded = !bree_test_renderer_occlusion_visible;
    }
    if (bree_test_renderer_realized_call_count < 16) {
        bree_test_renderer_realized_calls[bree_test_renderer_realized_call_count] = realized;
        bree_test_renderer_realized_call_count++;
    }
    return bree_test_renderer_realized_result;
}
bool ghostty_surface_rebuild_renderer(void *surface) {
    if (surface != bree_test_renderer_realized_target) return true;
    bree_test_renderer_rebuild_call_count++;
    return bree_test_renderer_realized_result;
}
void ghostty_surface_set_size(void) {}
void ghostty_surface_size(void) {}
void ghostty_surface_text(void) {}
void ghostty_surface_text_input(void) {}
void ghostty_surface_update_config(void *surface, void *raw_config) {
    (void)raw_config;
    bree_test_last_updated_surface = surface;
}
ghostty_string_s ghostty_surface_tty_name(void *surface) {
    (void)surface;
    bree_test_tty_name_call_count++;
    if (bree_test_tty_name == NULL) {
        return (ghostty_string_s){0};
    }
    return (ghostty_string_s){.ptr = bree_test_tty_name, .len = strlen(bree_test_tty_name), .sentinel = false};
}

uint32_t bree_test_ghostty_tty_name_call_count(void) {
    return bree_test_tty_name_call_count;
}

bool bree_test_ghostty_surface_was_updated(void *surface) {
    return surface == bree_test_last_updated_surface;
}

void bree_test_ghostty_font_state_begin(
    void *surface,
    float runtime_points,
    bool adjusted,
    float configured_runtime_points
) {
    bree_test_font_surface = surface;
    bree_test_font_runtime_points = runtime_points;
    bree_test_font_adjusted = adjusted;
    bree_test_font_configured_runtime_points =
        configured_runtime_points;
    bree_test_font_binding_succeeds = true;
}

void bree_test_ghostty_font_state_end(void) {
    bree_test_font_surface = NULL;
    bree_test_font_runtime_points = 0;
    bree_test_font_configured_runtime_points = 0;
    bree_test_font_adjusted = false;
    bree_test_font_binding_succeeds = true;
    bree_test_font_callback_surface = NULL;
    bree_test_font_callback = NULL;
    bree_test_font_callback_userdata = NULL;
}

void bree_test_ghostty_font_binding_result(bool result) {
    bree_test_font_binding_succeeds = result;
}
