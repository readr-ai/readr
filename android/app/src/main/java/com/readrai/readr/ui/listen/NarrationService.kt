package com.readrai.readr.ui.listen

import android.content.Intent
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * The service that keeps the voice reading while the screen is off.
 *
 * It carries nothing but [NarrationSession]'s media session and the
 * media-style notification media3 builds from it. It is started when
 * narration begins and stopped when it ends, so its lifetime is the voice's:
 * there is no path by which a book left behind goes on reading (the
 * `NarrationLease` on the reader's back-stack entry stops narration, and this
 * stops with it).
 *
 * There is no player to own here. The sound is made by
 * `android.speech.tts.TextToSpeech`, sentence by sentence; the session
 * publishes a [NarrationPlayer], which is a description of [NarrationModel]
 * and nothing more.
 */
@OptIn(UnstableApi::class)
class NarrationService : MediaSessionService() {

    override fun onCreate() {
        super.onCreate()
        running = true
        val session = NarrationSession.active
        if (session == null) {
            // Started with nothing to publish — a restart after the process
            // was killed, say. There is no voice to carry, so do not sit in
            // the foreground pretending there is.
            stopSelf()
            return
        }
        addSession(session.session)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        NarrationSession.active?.session

    /**
     * Go foreground as soon as there is a session, playing or paused. A paused
     * audiobook whose notification had gone would leave the reader no way back
     * to it, and the foreground promise is what keeps the voice alive with the
     * screen off.
     */
    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        super.onUpdateNotification(session, true)
    }

    /**
     * The reader swiped Readr off the recents list. That is leaving the book,
     * so the voice stops — the same answer the back-stack lease gives.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        NarrationSession.active?.stopNarration()
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        /**
         * Whether the service is up. Only the instrumented tests read it —
         * the app starts and stops the service through [NarrationSession],
         * never by asking whether it is running.
         */
        @Volatile
        var running: Boolean = false
            private set
    }
}
