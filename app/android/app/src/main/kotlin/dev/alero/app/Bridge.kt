package dev.alero.app

import org.json.JSONArray
import org.json.JSONObject

/**
 * JNI view of the Rust engine for the service (app/rust/src/jni_api.rs). It works while the engine runs, even
 * with no Flutter UI. Nothing here decides trust: the engine only delivers to and accepts from paired devices.
 */
object Bridge {
    init {
        System.loadLibrary("pb_bridge")
    }

    /** null on success, else the error. */
    external fun send(peer: String, kind: String, body: String): String?

    /** Starts sending a file (`fd:N` for an open descriptor). Returns the transfer id, or `!` + the error. */
    external fun sendFile(peer: String, path: String, name: String): String

    /** JSON array of peers, or null if the engine is not running yet. */
    external fun peers(): String?

    /** Next event as JSON, or null after [timeoutMs]. */
    external fun next(timeoutMs: Long): String?

    /** Ids of paired devices that are connected right now. */
    fun connected(): List<String> {
        val a = JSONArray(peers() ?: return emptyList())
        return (0 until a.length()).map { a.getJSONObject(it) }
            .filter { it.optBoolean("trusted") && it.optString("state") == "Connected" }
            .map { it.getString("id") }
    }

    fun sendTo(peer: String, kind: String, body: JSONObject) {
        send(peer, kind, body.toString())
    }

    fun broadcast(kind: String, body: JSONObject) {
        val s = body.toString()
        for (p in connected()) send(p, kind, s)
    }
}
