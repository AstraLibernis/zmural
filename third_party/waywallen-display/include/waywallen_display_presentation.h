#ifndef WAYWALLEN_DISPLAY_PRESENTATION_H
#define WAYWALLEN_DISPLAY_PRESENTATION_H

#include <stdbool.h>
#include <stdint.h>

#include "waywallen_display_protocol_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct waywallen_presentation_controller waywallen_presentation_controller_t;

typedef struct waywallen_presentation_content {
    bool                           valid;
    bool                           config_valid;
    uint64_t                       buffer_generation;
    uint64_t                       content_token;
    uint64_t                       presentation_config_generation;
    uint32_t                       width;
    uint32_t                       height;
    uint32_t                       fourcc;
    waywallen_composition_config_t config;
} waywallen_presentation_content_t;

typedef enum waywallen_presentation_config_result
{
    WAYWALLEN_PRESENTATION_CONFIG_REJECTED = 0,
    WAYWALLEN_PRESENTATION_CONFIG_STAGED,
    WAYWALLEN_PRESENTATION_CONFIG_DISPLAYED_UPDATED,
} waywallen_presentation_config_result_t;

typedef enum waywallen_presentation_prepare_result
{
    WAYWALLEN_PRESENTATION_PREPARE_REJECTED = 0,
    WAYWALLEN_PRESENTATION_PREPARE_ALREADY_PREPARED,
    WAYWALLEN_PRESENTATION_PREPARE_QUEUED,
    WAYWALLEN_PRESENTATION_PREPARE_DIRECT,
    WAYWALLEN_PRESENTATION_PREPARE_TRANSITION,
} waywallen_presentation_prepare_result_t;

typedef enum waywallen_presentation_accept_result
{
    WAYWALLEN_PRESENTATION_ACCEPT_REJECTED = 0,
    WAYWALLEN_PRESENTATION_ACCEPT_REBOUND,
    WAYWALLEN_PRESENTATION_ACCEPT_CONTENT_CHANGED,
} waywallen_presentation_accept_result_t;

waywallen_presentation_controller_t* waywallen_presentation_controller_new(void);
void waywallen_presentation_controller_free(waywallen_presentation_controller_t* controller);
void waywallen_presentation_controller_reset(waywallen_presentation_controller_t* controller);

void waywallen_presentation_controller_begin_incoming(
    waywallen_presentation_controller_t* controller, uint64_t buffer_generation,
    uint64_t content_token, uint64_t presentation_config_generation, uint32_t width,
    uint32_t height, uint32_t fourcc, bool valid);
void waywallen_presentation_controller_retire_incoming(
    waywallen_presentation_controller_t* controller, uint64_t buffer_generation);

waywallen_presentation_config_result_t
waywallen_presentation_controller_apply_config(waywallen_presentation_controller_t*  controller,
                                               const waywallen_composition_config_t* config);
bool waywallen_presentation_controller_incoming_for(
    const waywallen_presentation_controller_t* controller, uint64_t buffer_generation,
    waywallen_presentation_content_t* content);

waywallen_presentation_prepare_result_t
waywallen_presentation_controller_prepare(waywallen_presentation_controller_t*    controller,
                                          const waywallen_presentation_content_t* content,
                                          bool transition_configured, bool outgoing_available,
                                          uint64_t* serial);
bool waywallen_presentation_controller_promote(waywallen_presentation_controller_t* controller,
                                               uint64_t                             serial);
waywallen_presentation_accept_result_t
waywallen_presentation_controller_accept(waywallen_presentation_controller_t* controller,
                                         uint64_t                             serial,
                                         waywallen_presentation_content_t*    accepted);
bool waywallen_presentation_controller_discard(waywallen_presentation_controller_t* controller,
                                               uint64_t                             serial);

bool waywallen_presentation_controller_buffer_changes_with(
    const waywallen_presentation_controller_t* controller, uint64_t buffer_generation);
bool waywallen_presentation_controller_prepared(
    const waywallen_presentation_controller_t* controller, uint64_t serial,
    waywallen_presentation_content_t* content, bool* transition);
bool waywallen_presentation_controller_displayed(
    const waywallen_presentation_controller_t* controller,
    waywallen_presentation_content_t*          content);
uint64_t waywallen_presentation_controller_committed_token(
    const waywallen_presentation_controller_t* controller);
bool waywallen_presentation_controller_transition_active(
    const waywallen_presentation_controller_t* controller);
void waywallen_presentation_controller_set_transition_active(
    waywallen_presentation_controller_t* controller, bool active);

#ifdef __cplusplus
}
#endif

#endif
