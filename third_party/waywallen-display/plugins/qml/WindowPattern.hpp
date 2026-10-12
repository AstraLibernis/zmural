#pragma once

#include <QRegularExpression>

class WindowPattern {
public:
    explicit WindowPattern(const QString& pattern)
        : m_expression(QRegularExpression::anchoredPattern(
                           QRegularExpression::escape(pattern)
                               .replace(QStringLiteral("\\*"), QStringLiteral(".*"))
                               .replace(QStringLiteral("\\?"), QStringLiteral("."))),
                       QRegularExpression::DotMatchesEverythingOption) {}

    bool matches(const QString& value) const { return m_expression.match(value).hasMatch(); }

private:
    QRegularExpression m_expression;
};
