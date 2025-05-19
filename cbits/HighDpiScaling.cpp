#include "QtGui/QGuiApplication"

extern "C" void hsqml_enable_high_dpi_scaling() {
    QGuiApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
}
