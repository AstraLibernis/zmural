#pragma once

#include "QtPresentationTypes.hpp"
#include "WaywallenDisplay.hpp"

#include <QColor>
#include <QPointF>
#include <QRectF>
#include <QSGNode>
#include <QSize>

class QQuickWindow;
class QSGClipNode;
class QSGGeometry;
class QSGImageNode;
class QSGOpacityNode;
class QSGRectangleNode;
class QSGTexture;
class QSGTransformNode;

class PresentationNode final : public QSGNode {
public:
    enum class TextureBackend
    {
        None,
        OpenGL,
        Vulkan,
    };

    static PresentationNode* create(QQuickWindow* window);
    static void configureImage(QSGImageNode* imageNode, QSGTransformNode* transformNode,
                               const waywallen_presentation_content_t& content,
                               const QRectF& bounds, int displayWidth, int displayHeight);

    void installTexture(QSGTexture* texture, TextureBackend backend, quintptr handle,
                        const QSize& size);
    bool wraps(TextureBackend backend, quintptr handle, const QSize& size) const;

    QSGRectangleNode* clearNode;
    QSGTransformNode* transformNode;
    QSGImageNode*     imageNode;

private:
    PresentationNode(QSGRectangleNode* clear, QSGImageNode* image);

    TextureBackend textureBackend { TextureBackend::None };
    quintptr       nativeTexture { 0 };
    QSize          textureSize;
};

class TransitionNode final : public QSGNode {
public:
    static TransitionNode* create(QQuickWindow* window, qulonglong serial, QSGTexture* outgoing,
                                  QSGTexture* incoming);

    qulonglong serial() const { return m_serial; }
    void updateScene(WaywallenDisplay::TransitionKind kind, qreal progress, quint32 angle,
                     const QPointF& origin, const QRectF& bounds,
                     const waywallen_presentation_content_t& outgoingContent,
                     const waywallen_presentation_content_t& incomingContent, int displayWidth,
                     int displayHeight);

private:
    TransitionNode(qulonglong serial, QSGRectangleNode* outgoingClear, QSGTexture* outgoingTexture,
                   QSGImageNode* outgoingNode, QSGRectangleNode* incomingClear,
                   QSGTexture* incomingTexture, QSGImageNode* incomingNode);
    void updateClip(WaywallenDisplay::TransitionKind kind, qreal progress, quint32 angle,
                    const QPointF& origin, const QRectF& bounds);
    void setClipPolygon(const QVector<QPointF>& polygon);

    qulonglong        m_serial { 0 };
    QSGRectangleNode* m_outgoingClear { nullptr };
    QSGTransformNode* m_outgoingTransform { nullptr };
    QSGImageNode*     m_outgoingNode { nullptr };
    QSGOpacityNode*   m_incomingOpacity { nullptr };
    QSGClipNode*      m_clipNode { nullptr };
    QSGRectangleNode* m_incomingClear { nullptr };
    QSGTransformNode* m_incomingTransform { nullptr };
    QSGImageNode*     m_incomingNode { nullptr };
    QSGGeometry*      m_clipGeometry { nullptr };
};
