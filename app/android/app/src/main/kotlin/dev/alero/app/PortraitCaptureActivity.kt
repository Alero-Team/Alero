package dev.alero.app

import com.journeyapps.barcodescanner.CaptureActivity

/**
 * The QR scanner of the library, pinned to portrait. The library's own activity is declared sensorLandscape,
 * which is what flipped the screen; declaring this subclass as portrait in the manifest fixes it for this
 * screen only (the rest of the app keeps following the sensor).
 */
class PortraitCaptureActivity : CaptureActivity()
