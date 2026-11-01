package dev.alero.app

import org.junit.Assert.*
import org.junit.Test

class ChargePowerTest {
    @Test fun pixelReadingInMicroamps() {
        // Measured on a Pixel 9a over USB: 2 085 937 µA at 4313 mV.
        assertEquals(8996, ChargePower.milliwatts(2_085_937, 4313, true))
    }

    @Test fun signDoesNotMatter() {
        assertEquals(8996, ChargePower.milliwatts(-2_085_937, 4313, true))
    }

    @Test fun batteryHeldAtItsLimitIsNotACharge() {
        // Same Pixel at its 80 % limit: sysfs read +4687 / -5468 µA with the status still CHARGING (was shown as 23 W).
        assertEquals(0, ChargePower.milliwatts(5_468, 4242, true))
        assertEquals(0, ChargePower.milliwatts(-4_687, 4242, true))
    }

    @Test fun nothingWhenNotChargingOrUnknown() {
        assertEquals(0, ChargePower.milliwatts(2_000_000, 4300, false))
        assertEquals(0, ChargePower.milliwatts(Long.MIN_VALUE, 4300, true))
        assertEquals(0, ChargePower.milliwatts(2_000_000, 0, true))
        assertEquals(0, ChargePower.milliwatts(900_000_000, 4300, true))
    }
}
