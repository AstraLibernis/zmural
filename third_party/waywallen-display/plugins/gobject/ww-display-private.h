#ifndef WW_DISPLAY_PRIVATE_H
#define WW_DISPLAY_PRIVATE_H

#include "ww-display.h"

#include <waywallen_display.h>

typedef struct {
    void (*binding_ready)(WwDisplay* display, const waywallen_binding_t* binding, void* user_data);
    void (*textures_releasing)(WwDisplay* display, const waywallen_textures_t* textures,
                               void* user_data);
    void (*composition_config)(WwDisplay* display, const waywallen_composition_config_t* config,
                               void* user_data);
    void (*frame_ready)(WwDisplay* display, const waywallen_frame_t* frame, void* user_data);
    void (*presentation_snapshot)(WwDisplay*                               display,
                                  const waywallen_presentation_snapshot_t* presentation,
                                  void*                                    user_data);
} WwDisplayNativeListener;

G_GNUC_INTERNAL void _ww_display_set_native_listener(WwDisplay*                     display,
                                                     const WwDisplayNativeListener* listener,
                                                     void*                          user_data);
G_GNUC_INTERNAL void _ww_display_clear_native_listener(WwDisplay* display, void* user_data);

#endif
