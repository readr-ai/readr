package com.readrai.readr

import com.readrai.readr.ui.listen.NarrationAudioFocus

/**
 * The phone's audio focus, as a test states it. "A call came in", "the
 * navigation prompt finished" and "another app took the audio for good" are
 * things the system does to an app, not things a test can provoke — so the
 * session takes its focus through this seam and a test sends the change
 * itself.
 */
class FakeAudioFocus : NarrationAudioFocus {
    /** Whether the phone would give focus at all. */
    var granted = true
    var abandoned = false
        private set

    private var listener: ((Int) -> Unit)? = null

    override fun request(onChange: (Int) -> Unit): Boolean {
        listener = onChange
        return granted
    }

    override fun abandon() {
        abandoned = true
        listener = null
    }

    /** One of `AudioManager`'s `AUDIOFOCUS_*` changes, as the system would send it. */
    fun send(change: Int) {
        listener?.invoke(change)
    }
}
