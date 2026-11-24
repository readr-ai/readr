package com.readrai.readr.kit

/** Owns JNI callback lifetime independently of a cancellable vendor job. */
internal class NanoSinkGate(onDelta: (String) -> Unit, onCompleted: (String) -> Unit, onFailed: (String) -> Unit) {
    private data class Callbacks(val delta: (String) -> Unit, val completed: (String) -> Unit, val failed: (String) -> Unit)
    private var callbacks: Callbacks? = Callbacks(onDelta, onCompleted, onFailed)
    @Synchronized fun delta(text: String) { callbacks?.delta?.invoke(text) }
    @Synchronized fun completed(text: String) {
        val target = callbacks ?: return
        callbacks = null
        target.completed(text)
    }
    @Synchronized fun failed(reason: String) {
        val target = callbacks ?: return
        callbacks = null
        target.failed(reason)
    }
    @Synchronized fun close() { callbacks = null }
}
