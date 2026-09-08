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

    /**
     * Whether the `startForegroundService` that started this is still owed its
     * `startForeground` — see [onUpdateNotification].
     */
    private var owesForeground = true

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
     * The notification stays up for as long as there is a session, playing or
     * paused: a paused audiobook whose notification had gone would leave the
     * reader no way back to it.
     *
     * Whether the service must be *in the foreground* for it is media3's call,
     * not ours, so the flag is passed through — it used to be forced `true`,
     * which kept the service in the foreground for a book nobody was
     * listening to.
     *
     * The one exception is the **first** update. `NarrationSession` starts
     * this with `startForegroundService`, and that is a promise to call
     * `startForeground` within a few seconds or be killed for it
     * (`ForegroundServiceDidNotStartInTimeException`). media3 says foreground
     * is not required whenever the player is not playing — which is true of a
     * book held from its very first publish, when the phone refuses audio
     * focus. So the promise is kept once, and every update after it is
     * media3's own call.
     */
    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        val keepingThePromise = owesForeground
        owesForeground = false
        super.onUpdateNotification(session, startInForegroundRequired || keepingThePromise)
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
