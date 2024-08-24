#ifndef CLIPBOARDHELPER_H
#define CLIPBOARDHELPER_H

#include <QApplication>
#include <QClipboard>
#include <QObject>

class HsQMLClipboardHelper : public QObject {
    Q_OBJECT
public:
    explicit HsQMLClipboardHelper(QObject *parent = nullptr);

    Q_INVOKABLE void copyText(const QString &text);
};

#endif // CLIPBOARDHELPER_H
