#ifndef CLIPBOARDHELPER_H
#define CLIPBOARDHELPER_H

#include <QtGui/QGuiApplication>
#include <QtGui/QClipboard>
#include <QtCore/QObject>

class HsQMLClipboardHelper : public QObject {
    Q_OBJECT
public:
    explicit HsQMLClipboardHelper(QObject *parent = nullptr);

    Q_INVOKABLE void copyText(const QString &text);
};

#endif // CLIPBOARDHELPER_H
