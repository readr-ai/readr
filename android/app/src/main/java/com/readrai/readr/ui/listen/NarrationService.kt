package com.readrai.readr.ui.listen

import android.content.Intent
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import com.readrai.readr.MainActivity
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
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
 * Kokoro PCM playback, sentence by sentence; the session
 * publishes a [NarrationPlayer], which is a description of [NarrationModel]
 * and nothing more.
 */
@OptIn(UnstableApi::class)
class NarrationService : MediaSessionService() {

    override fun onCreate() {
        super.onCreate()
        // A startForegroundService request can outlive a session that was
        // immediately paused/released. Acknowledge it synchronously: relying
        // on Media3's asynchronous notification update can miss the deadline.
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Readr listening", NotificationManager.IMPORTANCE_LOW))
        val opening = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(BOOTSTRAP_NOTIFICATION, Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Readr")
            .setContentText("Preparing Readr Voice")
            .setContentIntent(opening).setOnlyAlertOnce(true).setOngoing(true)
            .setCategory(Notification.CATEGORY_TRANSPORT).setVisibility(Notification.VISIBILITY_PRIVATE).build())
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

    // Media3 replaces the bootstrap using the same notification id, then owns
    // promotion/demotion for playing, preparing and paused states.

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
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = DefaultMediaNotificationProvider.DEFAULT_CHANNEL_ID
        private const val BOOTSTRAP_NOTIFICATION = DefaultMediaNotificationProvider.DEFAULT_NOTIFICATION_ID
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
