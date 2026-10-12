#pragma once

#include <waywallen_display_protocol_types.h>

#include <QColor>
#include <QMatrix4x4>
#include <QRectF>

inline QMatrix4x4 qtCompositionTransform(quint32 transform, const QSizeF& bounds) {
    QMatrix4x4 matrix;
    if (transform == 0) return matrix;
    const bool  swap      = (transform & 1u) != 0;
    const qreal preWidth  = swap ? bounds.height() : bounds.width();
    const qreal preHeight = swap ? bounds.width() : bounds.height();
    matrix.translate(float(bounds.width() / 2), float(bounds.height() / 2));
    if (transform >= 4) matrix.scale(-1.0f, 1.0f);
    matrix.rotate(float((transform & 3u) * 90u), 0.0f, 0.0f, 1.0f);
    matrix.translate(float(-preWidth / 2), float(-preHeight / 2));
    return matrix;
}

inline QRectF qtRect(const ww_rect_t& rect) {
    return { static_cast<qreal>(rect.x),
             static_cast<qreal>(rect.y),
             static_cast<qreal>(rect.w),
             static_cast<qreal>(rect.h) };
}

inline QColor qtColor(const waywallen_rgba_color_t& color) {
    return QColor::fromRgbF(static_cast<qreal>(color.r),
                            static_cast<qreal>(color.g),
                            static_cast<qreal>(color.b),
                            static_cast<qreal>(color.a));
}
