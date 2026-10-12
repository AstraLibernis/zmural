#ifndef WAYWALLEN_DISPLAY_EGL_PRESENTER_H
#define WAYWALLEN_DISPLAY_EGL_PRESENTER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct waywallen_egl_presenter   waywallen_egl_presenter_t;
typedef struct waywallen_egl_presentable waywallen_egl_presentable_t;

typedef struct waywallen_gl_functions {
    void (*get_integer)(void* user_data, uint32_t name, int32_t* value);
    bool (*is_enabled)(void* user_data, uint32_t capability);
    void (*enable)(void* user_data, uint32_t capability);
    void (*disable)(void* user_data, uint32_t capability);
    void (*gen_textures)(void* user_data, int32_t count, uint32_t* textures);
    void (*delete_textures)(void* user_data, int32_t count, const uint32_t* textures);
    void (*bind_texture)(void* user_data, uint32_t target, uint32_t texture);
    void (*texture_parameter)(void* user_data, uint32_t target, uint32_t name, int32_t value);
    void (*texture_image_2d)(void* user_data, uint32_t target, int32_t level,
                             int32_t internal_format, int32_t width, int32_t height, int32_t border,
                             uint32_t format, uint32_t type, const void* data);
    void (*gen_framebuffers)(void* user_data, int32_t count, uint32_t* framebuffers);
    void (*delete_framebuffers)(void* user_data, int32_t count, const uint32_t* framebuffers);
    void (*bind_framebuffer)(void* user_data, uint32_t target, uint32_t framebuffer);
    void (*framebuffer_texture_2d)(void* user_data, uint32_t target, uint32_t attachment,
                                   uint32_t texture_target, uint32_t texture, int32_t level);
    uint32_t (*check_framebuffer)(void* user_data, uint32_t target);
    void (*blit_framebuffer)(void* user_data, int32_t source_x0, int32_t source_y0,
                             int32_t source_x1, int32_t source_y1, int32_t dest_x0, int32_t dest_y0,
                             int32_t dest_x1, int32_t dest_y1, uint32_t mask, uint32_t filter);
    uint32_t (*get_error)(void* user_data);
} waywallen_gl_functions_t;

typedef struct waywallen_egl_presentable_descriptor {
    uint32_t texture;
    uint32_t width;
    uint32_t height;
    uint64_t allocation_size;
    bool     has_content;
} waywallen_egl_presentable_descriptor_t;

typedef enum waywallen_egl_prepare_result
{
    WAYWALLEN_EGL_PREPARE_FAILED = 0,
    WAYWALLEN_EGL_PREPARE_FAILED_AFTER_GPU_WORK,
    WAYWALLEN_EGL_PREPARE_CURRENT_UPDATED,
    WAYWALLEN_EGL_PREPARE_CANDIDATE_READY,
} waywallen_egl_prepare_result_t;

/* All calls must run with the same current GL context. The presenter owns
 * current/candidate textures; retained handles stay owned until release. */
int  waywallen_egl_presenter_create(const waywallen_gl_functions_t* functions, void* user_data,
                                    waywallen_egl_presenter_t** presenter);
void waywallen_egl_presenter_destroy(waywallen_egl_presenter_t* presenter);
waywallen_egl_prepare_result_t waywallen_egl_presenter_prepare(waywallen_egl_presenter_t* presenter,
                                                               uint32_t source_texture,
                                                               uint32_t width, uint32_t height,
                                                               bool force_replace,
                                                               bool reuse_candidate);
int  waywallen_egl_presenter_commit(waywallen_egl_presenter_t*    presenter,
                                    waywallen_egl_presentable_t** retained_outgoing);
void waywallen_egl_presenter_discard_candidate(waywallen_egl_presenter_t* presenter);
bool waywallen_egl_presenter_current(const waywallen_egl_presenter_t*        presenter,
                                     waywallen_egl_presentable_descriptor_t* descriptor);
bool waywallen_egl_presenter_candidate(const waywallen_egl_presenter_t*        presenter,
                                       waywallen_egl_presentable_descriptor_t* descriptor);
bool waywallen_egl_presentable_descriptor(const waywallen_egl_presentable_t*      presentable,
                                          waywallen_egl_presentable_descriptor_t* descriptor);
void waywallen_egl_presenter_release(waywallen_egl_presenter_t*   presenter,
                                     waywallen_egl_presentable_t* presentable);

#ifdef __cplusplus
}
#endif

#endif
