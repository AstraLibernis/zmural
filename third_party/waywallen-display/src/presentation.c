#include "waywallen_display_presentation.h"

#include <stdlib.h>
#include <string.h>

typedef struct waywallen_prepared_presentation {
    bool                             valid;
    bool                             transition;
    bool                             promoted;
    uint64_t                         serial;
    waywallen_presentation_content_t content;
} waywallen_prepared_presentation_t;

struct waywallen_presentation_controller {
    waywallen_presentation_content_t  incoming;
    waywallen_presentation_content_t  displayed;
    waywallen_prepared_presentation_t prepared;
    uint64_t                          committed_token;
    uint64_t                          serial;
    bool                              transition_active;
};

static bool same_identity(const waywallen_presentation_content_t* left,
                          const waywallen_presentation_content_t* right) {
    return left->buffer_generation == right->buffer_generation &&
           left->content_token == right->content_token &&
           left->presentation_config_generation == right->presentation_config_generation;
}

static bool valid_incoming(const waywallen_presentation_controller_t* controller,
                           const waywallen_presentation_content_t*    content) {
    return content->valid && content->config_valid && content->content_token != 0 &&
           content->buffer_generation == content->config.buffer_generation &&
           controller->incoming.valid && controller->incoming.config_valid &&
           same_identity(content, &controller->incoming) &&
           content->config.generation == controller->incoming.config.generation;
}

waywallen_presentation_controller_t* waywallen_presentation_controller_new(void) {
    return calloc(1, sizeof(waywallen_presentation_controller_t));
}

void waywallen_presentation_controller_free(waywallen_presentation_controller_t* controller) {
    free(controller);
}

void waywallen_presentation_controller_reset(waywallen_presentation_controller_t* controller) {
    if (controller) memset(controller, 0, sizeof(*controller));
}

void waywallen_presentation_controller_begin_incoming(
    waywallen_presentation_controller_t* controller, uint64_t buffer_generation,
    uint64_t content_token, uint64_t presentation_config_generation, uint32_t width,
    uint32_t height, uint32_t fourcc, bool valid) {
    if (! controller) return;
    controller->incoming = (waywallen_presentation_content_t) {
        .valid                          = valid && content_token != 0,
        .buffer_generation              = buffer_generation,
        .content_token                  = content_token,
        .presentation_config_generation = presentation_config_generation,
        .width                          = width,
        .height                         = height,
        .fourcc                         = fourcc,
    };

    if (controller->prepared.valid && ! controller->prepared.promoted &&
        ! same_identity(&controller->prepared.content, &controller->incoming)) {
        controller->prepared = (waywallen_prepared_presentation_t) { 0 };
    }
}

void waywallen_presentation_controller_retire_incoming(
    waywallen_presentation_controller_t* controller, uint64_t buffer_generation) {
    if (! controller) return;
    if (controller->incoming.buffer_generation == buffer_generation) {
        controller->incoming = (waywallen_presentation_content_t) { 0 };
    }
    if (controller->prepared.valid && ! controller->prepared.promoted &&
        controller->prepared.content.buffer_generation == buffer_generation) {
        controller->prepared = (waywallen_prepared_presentation_t) { 0 };
    }
}

waywallen_presentation_config_result_t
waywallen_presentation_controller_apply_config(waywallen_presentation_controller_t*  controller,
                                               const waywallen_composition_config_t* config) {
    if (! controller || ! config) return WAYWALLEN_PRESENTATION_CONFIG_REJECTED;
    if (controller->displayed.valid &&
        controller->displayed.buffer_generation == config->buffer_generation) {
        controller->displayed.config       = *config;
        controller->displayed.config_valid = true;
        if (controller->incoming.valid &&
            controller->incoming.buffer_generation == config->buffer_generation) {
            controller->incoming.config       = *config;
            controller->incoming.config_valid = true;
        }
        if (controller->prepared.valid &&
            controller->prepared.content.buffer_generation == config->buffer_generation) {
            controller->prepared.content.config       = *config;
            controller->prepared.content.config_valid = true;
        }
        return WAYWALLEN_PRESENTATION_CONFIG_DISPLAYED_UPDATED;
    }
    if (! controller->incoming.valid ||
        controller->incoming.buffer_generation != config->buffer_generation) {
        return WAYWALLEN_PRESENTATION_CONFIG_REJECTED;
    }
    controller->incoming.config       = *config;
    controller->incoming.config_valid = true;
    if (controller->prepared.valid &&
        controller->prepared.content.buffer_generation == config->buffer_generation) {
        controller->prepared.content.config       = *config;
        controller->prepared.content.config_valid = true;
    }
    return WAYWALLEN_PRESENTATION_CONFIG_STAGED;
}

bool waywallen_presentation_controller_incoming_for(
    const waywallen_presentation_controller_t* controller, uint64_t buffer_generation,
    waywallen_presentation_content_t* content) {
    if (! controller || ! content || ! controller->incoming.valid ||
        ! controller->incoming.config_valid ||
        controller->incoming.buffer_generation != buffer_generation) {
        return false;
    }
    *content = controller->incoming;
    return true;
}

waywallen_presentation_prepare_result_t
waywallen_presentation_controller_prepare(waywallen_presentation_controller_t*    controller,
                                          const waywallen_presentation_content_t* content,
                                          bool transition_configured, bool outgoing_available,
                                          uint64_t* serial) {
    if (! controller || ! content || ! serial || ! valid_incoming(controller, content)) {
        return WAYWALLEN_PRESENTATION_PREPARE_REJECTED;
    }
    if (controller->transition_active) return WAYWALLEN_PRESENTATION_PREPARE_QUEUED;
    if (controller->prepared.valid && same_identity(&controller->prepared.content, content)) {
        *serial = controller->prepared.serial;
        return WAYWALLEN_PRESENTATION_PREPARE_ALREADY_PREPARED;
    }

    controller->prepared = (waywallen_prepared_presentation_t) {
        .valid      = true,
        .transition = transition_configured && outgoing_available &&
                      controller->committed_token != 0 &&
                      controller->committed_token != content->content_token,
        .serial     = ++controller->serial,
        .content    = *content,
    };
    *serial = controller->prepared.serial;
    return controller->prepared.transition ? WAYWALLEN_PRESENTATION_PREPARE_TRANSITION
                                           : WAYWALLEN_PRESENTATION_PREPARE_DIRECT;
}

bool waywallen_presentation_controller_promote(waywallen_presentation_controller_t* controller,
                                               uint64_t                             serial) {
    if (! controller || ! controller->prepared.valid || controller->prepared.serial != serial ||
        ! valid_incoming(controller, &controller->prepared.content)) {
        return false;
    }
    controller->displayed         = controller->prepared.content;
    controller->prepared.promoted = true;
    return true;
}

waywallen_presentation_accept_result_t
waywallen_presentation_controller_accept(waywallen_presentation_controller_t* controller,
                                         uint64_t                             serial,
                                         waywallen_presentation_content_t*    accepted) {
    if (! controller || ! accepted || ! controller->prepared.valid ||
        controller->prepared.serial != serial || ! controller->displayed.valid ||
        ! same_identity(&controller->displayed, &controller->prepared.content)) {
        return WAYWALLEN_PRESENTATION_ACCEPT_REJECTED;
    }
    *accepted                   = controller->prepared.content;
    const bool changed          = controller->committed_token != accepted->content_token;
    controller->committed_token = accepted->content_token;
    controller->prepared        = (waywallen_prepared_presentation_t) { 0 };
    return changed ? WAYWALLEN_PRESENTATION_ACCEPT_CONTENT_CHANGED
                   : WAYWALLEN_PRESENTATION_ACCEPT_REBOUND;
}

bool waywallen_presentation_controller_discard(waywallen_presentation_controller_t* controller,
                                               uint64_t                             serial) {
    if (! controller || ! controller->prepared.valid || controller->prepared.serial != serial) {
        return false;
    }
    controller->prepared = (waywallen_prepared_presentation_t) { 0 };
    return true;
}

bool waywallen_presentation_controller_buffer_changes_with(
    const waywallen_presentation_controller_t* controller, uint64_t buffer_generation) {
    return ! controller || ! controller->displayed.valid ||
           controller->displayed.buffer_generation != buffer_generation;
}

bool waywallen_presentation_controller_prepared(
    const waywallen_presentation_controller_t* controller, uint64_t serial,
    waywallen_presentation_content_t* content, bool* transition) {
    if (! controller || ! content || ! transition || ! controller->prepared.valid ||
        controller->prepared.serial != serial) {
        return false;
    }
    *content    = controller->prepared.content;
    *transition = controller->prepared.transition;
    return true;
}

bool waywallen_presentation_controller_displayed(
    const waywallen_presentation_controller_t* controller,
    waywallen_presentation_content_t*          content) {
    if (! controller || ! content || ! controller->displayed.valid) return false;
    *content = controller->displayed;
    return true;
}

uint64_t waywallen_presentation_controller_committed_token(
    const waywallen_presentation_controller_t* controller) {
    return controller ? controller->committed_token : 0;
}

bool waywallen_presentation_controller_transition_active(
    const waywallen_presentation_controller_t* controller) {
    return controller && controller->transition_active;
}

void waywallen_presentation_controller_set_transition_active(
    waywallen_presentation_controller_t* controller, bool active) {
    if (controller) controller->transition_active = active;
}
