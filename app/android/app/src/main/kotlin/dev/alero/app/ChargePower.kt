package dev.alero.app

/** Power flowing into the battery, from the fuel gauge: current × voltage. Pure, so it can be tested without a phone. */
object ChargePower {
    /**
     * [rawCurrent] is `BATTERY_PROPERTY_CURRENT_NOW`: µA by the Android contract, and its sign is not the same on
     * every device, so only the magnitude counts. Under 0.5 W is a battery being held (a Pixel at its 80 % limit reads
     * ±5 mA while the status still says CHARGING), not a charge rate, so it reports 0.
     * shortcut: a legacy device that reports mA reads as ~0 W (hidden); upgrade by deriving the unit from CHARGE_COUNTER deltas.
     */
    fun milliwatts(rawCurrent: Long, millivolts: Int, charging: Boolean): Int {
        if (!charging || rawCurrent == Long.MIN_VALUE || millivolts <= 0) return 0
        val mw = Math.abs(rawCurrent) * millivolts / 1_000_000 // µA × mV = nW
        return if (mw < 500 || mw > 300_000) 0 else mw.toInt() // beyond 300 W the reading is garbage, not a charger
    }
}
