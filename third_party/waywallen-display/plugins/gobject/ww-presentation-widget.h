#ifndef WW_PRESENTATION_WIDGET_H
#define WW_PRESENTATION_WIDGET_H

#include "ww-display.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define WW_TYPE_PRESENTATION_WIDGET (ww_presentation_widget_get_type())
G_DECLARE_FINAL_TYPE(WwPresentationWidget, ww_presentation_widget, WW, PRESENTATION_WIDGET,
                     GtkWidget)

WwPresentationWidget* ww_presentation_widget_new(void);

/**
 * ww_presentation_widget_set_display:
 * @self: a #WwPresentationWidget
 * @display: (nullable): a #WwDisplay, or NULL to detach
 * @scale: physical-to-logical display scale
 *
 * Connects the presentation owner directly to the typed display stream.
 * Content identities remain in native code and are never converted through
 * the JavaScript number type.
 */
void ww_presentation_widget_set_display(WwPresentationWidget* self, WwDisplay* display,
                                        gdouble scale);

/**
 * ww_presentation_widget_stage_shadow:
 * @self: a #WwPresentationWidget
 * @fd: owned shadow DMA-BUF fd; the widget closes it
 * @n_planes: number of DMA-BUF planes
 * @width: shadow width in pixels
 * @height: shadow height in pixels
 * @fourcc: DRM fourcc
 * @modifier: DRM modifier
 * @strides: (array fixed-size=4): per-plane byte pitch
 * @offsets: (array fixed-size=4): per-plane byte offset
 * @buffer_generation: binding generation
 * @content_token: opaque logical content identity
 * @presentation_config_generation: presentation config used by the binding
 * @composition_generation: initial composition generation
 * @sx: @sy: @sw: @sh: source rectangle
 * @dx: @dy: @dw: @dh: destination rectangle
 * @transform: output transform
 * @cr: @cg: @cb: @ca: clear color
 *
 * Imports a candidate binding without replacing the displayed content.
 * The candidate becomes displayable when its first frame is received.
 *
 * Returns: TRUE when the shadow was imported
 */
gboolean ww_presentation_widget_stage_shadow(
    WwPresentationWidget* self, gint fd, guint n_planes, guint width, guint height, guint fourcc,
    guint64 modifier, const guint strides[4], const guint64 offsets[4], guint64 buffer_generation,
    guint64 content_token, guint64 presentation_config_generation, guint64 composition_generation,
    gdouble sx, gdouble sy, gdouble sw, gdouble sh, gdouble dx, gdouble dy, gdouble dw, gdouble dh,
    guint transform, gdouble cr, gdouble cg, gdouble cb, gdouble ca);

/**
 * ww_presentation_widget_set_composition:
 * @self: a #WwPresentationWidget
 * @composition_generation: composition generation
 * @buffer_generation: target binding generation
 * @sx: @sy: @sw: @sh: source rectangle
 * @dx: @dy: @dw: @dh: destination rectangle
 * @transform: output transform
 * @cr: @cg: @cb: @ca: clear color
 */
void ww_presentation_widget_set_composition(WwPresentationWidget* self,
                                            guint64               composition_generation,
                                            guint64 buffer_generation, gdouble sx, gdouble sy,
                                            gdouble sw, gdouble sh, gdouble dx, gdouble dy,
                                            gdouble dw, gdouble dh, guint transform, gdouble cr,
                                            gdouble cg, gdouble cb, gdouble ca);

/**
 * ww_presentation_widget_retire_binding:
 * @self: a #WwPresentationWidget
 * @buffer_generation: retired binding generation
 */
void ww_presentation_widget_retire_binding(WwPresentationWidget* self, guint64 buffer_generation);

/**
 * ww_presentation_widget_frame_ready:
 * @self: a #WwPresentationWidget
 * @buffer_generation: frame binding generation
 */
void ww_presentation_widget_frame_ready(WwPresentationWidget* self, guint64 buffer_generation);

/**
 * ww_presentation_widget_set_transition:
 * @self: a #WwPresentationWidget
 * @config_generation: presentation config generation
 * @kind: transition kind
 * @duration_ms: duration in milliseconds
 * @angle: wipe angle in degrees
 * @origin_x: grow origin X in normalized output coordinates
 * @origin_y: grow origin Y in normalized output coordinates
 */
void ww_presentation_widget_set_transition(WwPresentationWidget* self, guint64 config_generation,
                                           WwTransitionKind kind, guint duration_ms, guint angle,
                                           gdouble origin_x, gdouble origin_y);

/**
 * ww_presentation_widget_clear:
 * @self: a #WwPresentationWidget
 */
void ww_presentation_widget_clear(WwPresentationWidget* self);

G_END_DECLS

#endif /* WW_PRESENTATION_WIDGET_H */
