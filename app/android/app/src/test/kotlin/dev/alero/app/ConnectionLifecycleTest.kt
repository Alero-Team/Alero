package dev.alero.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionLifecycleTest {
    @Test fun remoteDisconnectKeepsGraceForReconnection() {
        assertFalse(stopServiceImmediately(true, "Disconnected", "paused_remote"))
        assertFalse(stopServiceImmediately(true, "Disconnected", "connection lost"))
        assertFalse(stopServiceImmediately(true, "Connected", ""))
    }

    @Test fun localDisconnectAndForgetStopImmediately() {
        assertTrue(stopServiceImmediately(true, "Disconnected", "paused"))
        assertTrue(stopServiceImmediately(false, "Disconnected", ""))
        assertTrue(stopServiceImmediately(true, "Rejected", ""))
    }
}
