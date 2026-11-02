package dev.alero.app

import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetTextTest {
    @Test fun offlineHidesTheLastBattery() {
        // A computer that disconnected must not keep claiming a battery reading.
        assertEquals("Sin conexión", WidgetText.state(false, 80, true))
    }

    @Test fun onlineWithBattery() {
        assertEquals("Conectado · 58 % · cargando", WidgetText.state(true, 58, true))
        assertEquals("Conectado · 7 %", WidgetText.state(true, 7, false))
    }

    @Test fun desktopWithoutBattery() {
        assertEquals("Conectado", WidgetText.state(true, -1, false))
        assertEquals("", WidgetText.battery(-1, true))
    }

    @Test fun sizes() {
        assertEquals("512 B", WidgetText.size(512))
        assertEquals("2 KB", WidgetText.size(2048))
        assertEquals("22.7 MB", WidgetText.size(23_807_734))
        assertEquals("1.5 GB", WidgetText.size(3L shl 29))
    }

    @Test fun recentTransfers() {
        assertEquals("Recibido · foto.jpg", WidgetText.recent("foto.jpg", true, "done"))
        assertEquals("Enviado · a.pdf", WidgetText.recent("a.pdf", false, "done"))
        assertEquals("Falló · a.pdf", WidgetText.recent("a.pdf", false, "failed"))
    }
}
