#include "ClipboardHelper.h"

HsQMLClipboardHelper::HsQMLClipboardHelper(QObject *parent)
    : QObject(parent) {}

void HsQMLClipboardHelper::copyText(const QString &text) {
    QClipboard *clipboard = QGuiApplication::clipboard();
    clipboard->setText(text);
}
