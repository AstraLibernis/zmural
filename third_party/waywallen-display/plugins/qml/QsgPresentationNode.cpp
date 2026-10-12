#include "QsgPresentationNode.hpp"

#include <QLineF>
#include <QMatrix4x4>
#include <QQuickWindow>
#include <QSGClipNode>
#include <QSGGeometry>
#include <QSGImageNode>
#include <QSGOpacityNode>
#include <QSGRectangleNode>
#include <QSGTexture>
#include <QSGTransformNode>
#include <cmath>
#include <limits>

PresentationNode* PresentationNode::create(QQuickWindow* window) {
    auto* clear = window->createRectangleNode();
    auto* image = window->createImageNode();
    if (! clear || ! image) {
        delete clear;
        delete image;
        return nullptr;
    }
    return new PresentationNode(clear, image);
}

PresentationNode::PresentationNode(QSGRectangleNode* clear, QSGImageNode* image)
    : clearNode(clear), transformNode(new QSGTransformNode()), imageNode(image) {
    imageNode->setFiltering(QSGTexture::Linear);
    imageNode->setOwnsTexture(true);
    appendChildNode(clearNode);
    appendChildNode(transformNode);
    transformNode->appendChildNode(imageNode);
}

void PresentationNode::installTexture(QSGTexture* texture, TextureBackend backend, quintptr handle,
                                      const QSize& size) {
    imageNode->setTexture(texture);
    textureBackend = backend;
    nativeTexture  = handle;
    textureSize    = size;
}

bool PresentationNode::wraps(TextureBackend backend, quintptr handle, const QSize& size) const {
    return textureBackend == backend && nativeTexture == handle && textureSize == size;
}

TransitionNode* TransitionNode::create(QQuickWindow* window, qulonglong serial,
                                       QSGTexture* outgoing, QSGTexture* incoming) {
    if (! window || ! outgoing || ! incoming) {
        delete outgoing;
        delete incoming;
        return nullptr;
    }
    auto* outgoingClear = window->createRectangleNode();
    auto* outgoingNode  = window->createImageNode();
    auto* incomingClear = window->createRectangleNode();
    auto* incomingNode  = window->createImageNode();
    if (! outgoingClear || ! outgoingNode || ! incomingClear || ! incomingNode) {
        delete outgoingClear;
        delete outgoingNode;
        delete incomingClear;
        delete incomingNode;
        delete outgoing;
        delete incoming;
        return nullptr;
    }
    return new TransitionNode(
        serial, outgoingClear, outgoing, outgoingNode, incomingClear, incoming, incomingNode);
}

TransitionNode::TransitionNode(qulonglong serial, QSGRectangleNode* outgoingClear,
                               QSGTexture* outgoingTexture, QSGImageNode* outgoingNode,
                               QSGRectangleNode* incomingClear, QSGTexture* incomingTexture,
                               QSGImageNode* incomingNode)
    : m_serial(serial),
      m_outgoingClear(outgoingClear),
      m_outgoingNode(outgoingNode),
      m_incomingClear(incomingClear),
      m_incomingNode(incomingNode),
      m_clipGeometry(new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(), 100)) {
    m_outgoingNode->setTexture(outgoingTexture);
    m_outgoingNode->setOwnsTexture(true);
    m_outgoingNode->setFiltering(QSGTexture::Linear);
    m_incomingNode->setTexture(incomingTexture);
    m_incomingNode->setOwnsTexture(true);
    m_incomingNode->setFiltering(QSGTexture::Linear);

    m_incomingOpacity   = new QSGOpacityNode();
    m_clipNode          = new QSGClipNode();
    m_outgoingTransform = new QSGTransformNode();
    m_incomingTransform = new QSGTransformNode();
    m_clipGeometry->setDrawingMode(QSGGeometry::DrawTriangleFan);
    m_clipGeometry->setVertexDataPattern(QSGGeometry::DynamicPattern);
    m_clipNode->setGeometry(m_clipGeometry);
    m_clipNode->setFlag(QSGNode::OwnsGeometry);

    appendChildNode(m_outgoingClear);
    appendChildNode(m_outgoingTransform);
    m_outgoingTransform->appendChildNode(m_outgoingNode);
    appendChildNode(m_incomingOpacity);
    m_incomingOpacity->appendChildNode(m_clipNode);
    m_clipNode->appendChildNode(m_incomingClear);
    m_clipNode->appendChildNode(m_incomingTransform);
    m_incomingTransform->appendChildNode(m_incomingNode);
}

void TransitionNode::updateScene(WaywallenDisplay::TransitionKind kind, qreal progress,
                                 quint32 angle, const QPointF& origin, const QRectF& bounds,
                                 const waywallen_presentation_content_t& outgoingContent,
                                 const waywallen_presentation_content_t& incomingContent,
                                 int displayWidth, int displayHeight) {
    m_outgoingClear->setRect(bounds);
    m_outgoingClear->setColor(qtColor(outgoingContent.config.clear_color));
    PresentationNode::configureImage(
        m_outgoingNode, m_outgoingTransform, outgoingContent, bounds, displayWidth, displayHeight);

    m_incomingClear->setRect(bounds);
    m_incomingClear->setColor(qtColor(incomingContent.config.clear_color));
    PresentationNode::configureImage(
        m_incomingNode, m_incomingTransform, incomingContent, bounds, displayWidth, displayHeight);
    updateClip(kind, progress, angle, origin, bounds);
}

void PresentationNode::configureImage(QSGImageNode* imageNode, QSGTransformNode* transformNode,
                                      const waywallen_presentation_content_t& content,
                                      const QRectF& bounds, int displayWidth, int displayHeight) {
    const QRectF sourceRect = qtRect(content.config.source_rect);
    const QRectF destRect   = qtRect(content.config.dest_rect);
    if (sourceRect.width() > 0 && sourceRect.height() > 0) {
        imageNode->setSourceRect(sourceRect);
    } else {
        imageNode->setSourceRect(QRectF(0, 0, content.width, content.height));
    }

    if (destRect.width() > 0 && destRect.height() > 0 && displayWidth > 0 && displayHeight > 0) {
        const qreal sx = bounds.width() / qreal(displayWidth);
        const qreal sy = bounds.height() / qreal(displayHeight);
        imageNode->setRect(QRectF(
            destRect.x() * sx, destRect.y() * sy, destRect.width() * sx, destRect.height() * sy));
    } else {
        imageNode->setRect(bounds);
    }

    const auto matrix = qtCompositionTransform(content.config.transform, bounds.size());
    if (transformNode->matrix() != matrix) {
        transformNode->setMatrix(matrix);
        transformNode->markDirty(QSGNode::DirtyMatrix);
    }
}

void TransitionNode::updateClip(WaywallenDisplay::TransitionKind kind, qreal progress,
                                quint32 angle, const QPointF& origin, const QRectF& bounds) {
    progress = qBound<qreal>(0.0, progress, 1.0);
    if (kind == WaywallenDisplay::FadeTransition) {
        m_incomingOpacity->setOpacity(progress);
        m_clipNode->setIsRectangular(true);
        m_clipNode->setClipRect(bounds);
        return;
    }

    m_incomingOpacity->setOpacity(progress <= 0.0 ? 0.0 : 1.0);
    if (progress >= 1.0) {
        m_clipNode->setIsRectangular(true);
        m_clipNode->setClipRect(bounds);
        return;
    }
    m_clipNode->setIsRectangular(false);

    if (kind == WaywallenDisplay::WipeTransition) {
        QVector<QPointF> polygon {
            bounds.topLeft(), bounds.topRight(), bounds.bottomRight(), bounds.bottomLeft()
        };
        constexpr qreal pi      = 3.14159265358979323846;
        const qreal     radians = qreal(angle % 360u) * pi / 180.0;
        const QPointF   gradient(std::cos(radians), std::sin(radians));
        auto            distance = [&gradient](const QPointF& point) {
            return point.x() * gradient.x() + point.y() * gradient.y();
        };
        qreal minimum = std::numeric_limits<qreal>::max();
        qreal maximum = std::numeric_limits<qreal>::lowest();
        for (const auto& point : polygon) {
            minimum = qMin(minimum, distance(point));
            maximum = qMax(maximum, distance(point));
        }
        const qreal      threshold = minimum + (maximum - minimum) * progress;
        QVector<QPointF> clipped;
        for (int index = 0; index < polygon.size(); ++index) {
            const QPointF current          = polygon[index];
            const QPointF previous         = polygon[(index + polygon.size() - 1) % polygon.size()];
            const qreal   currentDistance  = distance(current) - threshold;
            const qreal   previousDistance = distance(previous) - threshold;
            const bool    currentInside    = currentDistance <= 0.0;
            const bool    previousInside   = previousDistance <= 0.0;
            if (currentInside != previousInside) {
                const qreal denominator = previousDistance - currentDistance;
                const qreal factor =
                    qFuzzyIsNull(denominator) ? 0.0 : previousDistance / denominator;
                clipped.push_back(previous + (current - previous) * factor);
            }
            if (currentInside) clipped.push_back(current);
        }
        setClipPolygon(clipped);
        return;
    }

    constexpr int segmentCount = 96;
    const QPointF center(bounds.left() + bounds.width() * origin.x(),
                         bounds.top() + bounds.height() * origin.y());
    const QPointF corners[] {
        bounds.topLeft(), bounds.topRight(), bounds.bottomRight(), bounds.bottomLeft()
    };
    qreal reach = 1.0;
    for (const auto& corner : corners) reach = qMax(reach, QLineF(center, corner).length());
    constexpr qreal pi     = 3.14159265358979323846;
    const qreal     radius = reach * progress / std::cos(pi / segmentCount);
    m_clipGeometry->allocate(segmentCount + 2);
    auto* points = m_clipGeometry->vertexDataAsPoint2D();
    points[0].set(static_cast<float>(center.x()), static_cast<float>(center.y()));
    for (int index = 0; index <= segmentCount; ++index) {
        const qreal radians = 2.0 * pi * qreal(index) / qreal(segmentCount);
        points[index + 1].set(static_cast<float>(center.x() + radius * std::cos(radians)),
                              static_cast<float>(center.y() + radius * std::sin(radians)));
    }
    m_clipNode->markDirty(QSGNode::DirtyGeometry);
}

void TransitionNode::setClipPolygon(const QVector<QPointF>& polygon) {
    m_clipGeometry->allocate(polygon.size());
    auto* points = m_clipGeometry->vertexDataAsPoint2D();
    for (int index = 0; index < polygon.size(); ++index) {
        points[index].set(static_cast<float>(polygon[index].x()),
                          static_cast<float>(polygon[index].y()));
    }
    m_clipNode->markDirty(QSGNode::DirtyGeometry);
}
