#include "waywallen_display_egl_presenter.h"

#include <errno.h>
#include <stdlib.h>

enum
{
    WW_GL_TEXTURE_2D               = 0x0DE1,
    WW_GL_SCISSOR_TEST             = 0x0C11,
    WW_GL_TEXTURE_BINDING_2D       = 0x8069,
    WW_GL_TEXTURE_MAG_FILTER       = 0x2800,
    WW_GL_TEXTURE_MIN_FILTER       = 0x2801,
    WW_GL_TEXTURE_WRAP_S           = 0x2802,
    WW_GL_TEXTURE_WRAP_T           = 0x2803,
    WW_GL_NEAREST                  = 0x2600,
    WW_GL_LINEAR                   = 0x2601,
    WW_GL_CLAMP_TO_EDGE            = 0x812F,
    WW_GL_RGBA                     = 0x1908,
    WW_GL_RGBA8                    = 0x8058,
    WW_GL_UNSIGNED_BYTE            = 0x1401,
    WW_GL_COLOR_BUFFER_BIT         = 0x00004000,
    WW_GL_READ_FRAMEBUFFER         = 0x8CA8,
    WW_GL_DRAW_FRAMEBUFFER         = 0x8CA9,
    WW_GL_READ_FRAMEBUFFER_BINDING = 0x8CAA,
    WW_GL_DRAW_FRAMEBUFFER_BINDING = 0x8CA6,
    WW_GL_COLOR_ATTACHMENT0        = 0x8CE0,
    WW_GL_FRAMEBUFFER_COMPLETE     = 0x8CD5,
    WW_GL_NO_ERROR                 = 0,
};

typedef struct waywallen_egl_shadow {
    uint32_t texture;
    uint32_t framebuffer;
    uint32_t width;
    uint32_t height;
    bool     has_content;
} waywallen_egl_shadow_t;

struct waywallen_egl_presentable {
    waywallen_egl_shadow_t            shadow;
    struct waywallen_egl_presentable* next;
};

struct waywallen_egl_presenter {
    waywallen_gl_functions_t     functions;
    void*                        user_data;
    waywallen_egl_shadow_t       current;
    waywallen_egl_shadow_t       candidate;
    uint32_t                     read_framebuffer;
    waywallen_egl_presentable_t* retained;
};

static bool complete_functions(const waywallen_gl_functions_t* functions) {
    return functions && functions->get_integer && functions->is_enabled && functions->enable &&
           functions->disable && functions->gen_textures && functions->delete_textures &&
           functions->bind_texture && functions->texture_parameter && functions->texture_image_2d &&
           functions->gen_framebuffers && functions->delete_framebuffers &&
           functions->bind_framebuffer && functions->framebuffer_texture_2d &&
           functions->check_framebuffer && functions->blit_framebuffer && functions->get_error;
}

static void destroy_shadow(waywallen_egl_presenter_t* presenter, waywallen_egl_shadow_t* shadow) {
    if (shadow->framebuffer) {
        presenter->functions.delete_framebuffers(presenter->user_data, 1, &shadow->framebuffer);
    }
    if (shadow->texture) {
        presenter->functions.delete_textures(presenter->user_data, 1, &shadow->texture);
    }
    *shadow = (waywallen_egl_shadow_t) { 0 };
}

static void describe(const waywallen_egl_shadow_t*           shadow,
                     waywallen_egl_presentable_descriptor_t* descriptor) {
    *descriptor = (waywallen_egl_presentable_descriptor_t) {
        .texture         = shadow->texture,
        .width           = shadow->width,
        .height          = shadow->height,
        .allocation_size = (uint64_t)shadow->width * (uint64_t)shadow->height * 4u,
        .has_content     = shadow->has_content,
    };
}

int waywallen_egl_presenter_create(const waywallen_gl_functions_t* functions, void* user_data,
                                   waywallen_egl_presenter_t** presenter) {
    if (! complete_functions(functions) || ! presenter) return -EINVAL;
    *presenter = calloc(1, sizeof(**presenter));
    if (! *presenter) return -ENOMEM;
    (*presenter)->functions = *functions;
    (*presenter)->user_data = user_data;
    return 0;
}

void waywallen_egl_presenter_destroy(waywallen_egl_presenter_t* presenter) {
    if (! presenter) return;
    destroy_shadow(presenter, &presenter->candidate);
    destroy_shadow(presenter, &presenter->current);
    while (presenter->retained) {
        waywallen_egl_presentable_t* retained = presenter->retained;
        presenter->retained                   = retained->next;
        destroy_shadow(presenter, &retained->shadow);
        free(retained);
    }
    if (presenter->read_framebuffer) {
        presenter->functions.delete_framebuffers(
            presenter->user_data, 1, &presenter->read_framebuffer);
    }
    free(presenter);
}

waywallen_egl_prepare_result_t waywallen_egl_presenter_prepare(waywallen_egl_presenter_t* presenter,
                                                               uint32_t source_texture,
                                                               uint32_t width, uint32_t height,
                                                               bool force_replace,
                                                               bool reuse_candidate) {
    if (! presenter || ! source_texture || ! width || ! height) {
        return WAYWALLEN_EGL_PREPARE_FAILED;
    }
    waywallen_gl_functions_t* gl        = &presenter->functions;
    void*                     user_data = presenter->user_data;
    const bool                update_candidate =
        reuse_candidate && presenter->candidate.texture && presenter->candidate.framebuffer &&
        presenter->candidate.width == width && presenter->candidate.height == height;
    const bool replace =
        ! update_candidate &&
        (force_replace || ! presenter->current.texture || ! presenter->current.framebuffer ||
         presenter->current.width != width || presenter->current.height != height);
    if (replace) destroy_shadow(presenter, &presenter->candidate);

    int32_t previous_draw    = 0;
    int32_t previous_read    = 0;
    int32_t previous_texture = 0;
    gl->get_integer(user_data, WW_GL_DRAW_FRAMEBUFFER_BINDING, &previous_draw);
    gl->get_integer(user_data, WW_GL_READ_FRAMEBUFFER_BINDING, &previous_read);
    gl->get_integer(user_data, WW_GL_TEXTURE_BINDING_2D, &previous_texture);
    const bool previous_scissor = gl->is_enabled(user_data, WW_GL_SCISSOR_TEST);
    if (previous_scissor) gl->disable(user_data, WW_GL_SCISSOR_TEST);

    uint32_t target_texture     = replace            ? 0
                                  : update_candidate ? presenter->candidate.texture
                                                     : presenter->current.texture;
    uint32_t target_framebuffer = replace            ? 0
                                  : update_candidate ? presenter->candidate.framebuffer
                                                     : presenter->current.framebuffer;
    if (replace) {
        gl->gen_textures(user_data, 1, &target_texture);
        gl->gen_framebuffers(user_data, 1, &target_framebuffer);
        if (! target_texture || ! target_framebuffer) {
            if (target_framebuffer) gl->delete_framebuffers(user_data, 1, &target_framebuffer);
            if (target_texture) gl->delete_textures(user_data, 1, &target_texture);
            gl->bind_texture(user_data, WW_GL_TEXTURE_2D, (uint32_t)previous_texture);
            gl->bind_framebuffer(user_data, WW_GL_DRAW_FRAMEBUFFER, (uint32_t)previous_draw);
            gl->bind_framebuffer(user_data, WW_GL_READ_FRAMEBUFFER, (uint32_t)previous_read);
            if (previous_scissor) gl->enable(user_data, WW_GL_SCISSOR_TEST);
            return WAYWALLEN_EGL_PREPARE_FAILED;
        }
        gl->bind_texture(user_data, WW_GL_TEXTURE_2D, target_texture);
        gl->texture_parameter(user_data, WW_GL_TEXTURE_2D, WW_GL_TEXTURE_MIN_FILTER, WW_GL_LINEAR);
        gl->texture_parameter(user_data, WW_GL_TEXTURE_2D, WW_GL_TEXTURE_MAG_FILTER, WW_GL_LINEAR);
        gl->texture_parameter(
            user_data, WW_GL_TEXTURE_2D, WW_GL_TEXTURE_WRAP_S, WW_GL_CLAMP_TO_EDGE);
        gl->texture_parameter(
            user_data, WW_GL_TEXTURE_2D, WW_GL_TEXTURE_WRAP_T, WW_GL_CLAMP_TO_EDGE);
        gl->texture_image_2d(user_data,
                             WW_GL_TEXTURE_2D,
                             0,
                             WW_GL_RGBA8,
                             (int32_t)width,
                             (int32_t)height,
                             0,
                             WW_GL_RGBA,
                             WW_GL_UNSIGNED_BYTE,
                             NULL);
    }

    gl->bind_framebuffer(user_data, WW_GL_DRAW_FRAMEBUFFER, target_framebuffer);
    gl->framebuffer_texture_2d(user_data,
                               WW_GL_DRAW_FRAMEBUFFER,
                               WW_GL_COLOR_ATTACHMENT0,
                               WW_GL_TEXTURE_2D,
                               target_texture,
                               0);
    if (! presenter->read_framebuffer) {
        gl->gen_framebuffers(user_data, 1, &presenter->read_framebuffer);
    }
    gl->bind_framebuffer(user_data, WW_GL_READ_FRAMEBUFFER, presenter->read_framebuffer);
    gl->framebuffer_texture_2d(user_data,
                               WW_GL_READ_FRAMEBUFFER,
                               WW_GL_COLOR_ATTACHMENT0,
                               WW_GL_TEXTURE_2D,
                               source_texture,
                               0);

    const bool complete =
        gl->check_framebuffer(user_data, WW_GL_DRAW_FRAMEBUFFER) == WW_GL_FRAMEBUFFER_COMPLETE &&
        gl->check_framebuffer(user_data, WW_GL_READ_FRAMEBUFFER) == WW_GL_FRAMEBUFFER_COMPLETE;
    if (complete) {
        gl->blit_framebuffer(user_data,
                             0,
                             0,
                             (int32_t)width,
                             (int32_t)height,
                             0,
                             0,
                             (int32_t)width,
                             (int32_t)height,
                             WW_GL_COLOR_BUFFER_BIT,
                             WW_GL_NEAREST);
    }
    const uint32_t error = gl->get_error(user_data);
    gl->framebuffer_texture_2d(
        user_data, WW_GL_READ_FRAMEBUFFER, WW_GL_COLOR_ATTACHMENT0, WW_GL_TEXTURE_2D, 0, 0);
    gl->bind_texture(user_data, WW_GL_TEXTURE_2D, (uint32_t)previous_texture);
    gl->bind_framebuffer(user_data, WW_GL_DRAW_FRAMEBUFFER, (uint32_t)previous_draw);
    gl->bind_framebuffer(user_data, WW_GL_READ_FRAMEBUFFER, (uint32_t)previous_read);
    if (previous_scissor) gl->enable(user_data, WW_GL_SCISSOR_TEST);

    if (! complete || error != WW_GL_NO_ERROR) {
        if (replace) {
            gl->delete_framebuffers(user_data, 1, &target_framebuffer);
            gl->delete_textures(user_data, 1, &target_texture);
        }
        return complete ? WAYWALLEN_EGL_PREPARE_FAILED_AFTER_GPU_WORK
                        : WAYWALLEN_EGL_PREPARE_FAILED;
    }

    if (replace || update_candidate) {
        if (replace) {
            presenter->candidate = (waywallen_egl_shadow_t) {
                .texture     = target_texture,
                .framebuffer = target_framebuffer,
                .width       = width,
                .height      = height,
            };
        }
        presenter->candidate.has_content = true;
        return WAYWALLEN_EGL_PREPARE_CANDIDATE_READY;
    }
    presenter->current.has_content = true;
    return WAYWALLEN_EGL_PREPARE_CURRENT_UPDATED;
}

int waywallen_egl_presenter_commit(waywallen_egl_presenter_t*    presenter,
                                   waywallen_egl_presentable_t** retained_outgoing) {
    if (! presenter || ! retained_outgoing || *retained_outgoing ||
        ! presenter->candidate.texture || ! presenter->candidate.framebuffer ||
        ! presenter->candidate.has_content) {
        return -EINVAL;
    }
    waywallen_egl_presentable_t* retained = NULL;
    if (presenter->current.texture || presenter->current.framebuffer) {
        retained = calloc(1, sizeof(*retained));
        if (! retained) return -ENOMEM;
        retained->shadow    = presenter->current;
        retained->next      = presenter->retained;
        presenter->retained = retained;
    }
    presenter->current   = presenter->candidate;
    presenter->candidate = (waywallen_egl_shadow_t) { 0 };
    *retained_outgoing   = retained;
    return 0;
}

void waywallen_egl_presenter_discard_candidate(waywallen_egl_presenter_t* presenter) {
    if (presenter) destroy_shadow(presenter, &presenter->candidate);
}

bool waywallen_egl_presenter_current(const waywallen_egl_presenter_t*        presenter,
                                     waywallen_egl_presentable_descriptor_t* descriptor) {
    if (! presenter || ! descriptor || ! presenter->current.texture) return false;
    describe(&presenter->current, descriptor);
    return true;
}

bool waywallen_egl_presenter_candidate(const waywallen_egl_presenter_t*        presenter,
                                       waywallen_egl_presentable_descriptor_t* descriptor) {
    if (! presenter || ! descriptor || ! presenter->candidate.texture) return false;
    describe(&presenter->candidate, descriptor);
    return true;
}

bool waywallen_egl_presentable_descriptor(const waywallen_egl_presentable_t*      presentable,
                                          waywallen_egl_presentable_descriptor_t* descriptor) {
    if (! presentable || ! descriptor || ! presentable->shadow.texture) return false;
    describe(&presentable->shadow, descriptor);
    return true;
}

void waywallen_egl_presenter_release(waywallen_egl_presenter_t*   presenter,
                                     waywallen_egl_presentable_t* presentable) {
    if (! presenter || ! presentable) return;
    waywallen_egl_presentable_t** link = &presenter->retained;
    while (*link && *link != presentable) link = &(*link)->next;
    if (! *link) return;
    *link = presentable->next;
    destroy_shadow(presenter, &presentable->shadow);
    free(presentable);
}
