package com.readrai.readr

import android.app.Application
import com.readrai.readr.data.AskRepository
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.ProvidersRepository
import com.readrai.readr.ui.ask.AskConversations
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
import com.readrai.readr.ui.listen.Narrations
import com.readrai.readr.ui.reader.ReaderSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ReadrApplication : Application() {
    /** Opened on first use, off the main thread: loading the Swift runtime and decoding library.json is real work. */
    private val kit: Kit by lazy { Kit.open(filesDir, KeystoreSecretStore(this), NanoProbe(this)) }
    private val libraryRepository: LibraryRepository by lazy { LibraryRepository(this, kit) }
    private val providersRepository: ProvidersRepository by lazy { ProvidersRepository(kit) }
    private val askRepository: AskRepository by lazy { AskRepository(kit) }

    /**
     * One Ask conversation per book, for the life of the process — the Apple
     * app keeps one per session the same way, so closing the sheet and
     * opening it again two chapters later continues the conversation.
     */
    val askConversations: AskConversations = AskConversations()
    /** Reader appearance; plain preferences, read on the main thread (one small file). */
    val readerSettings: ReaderSettings by lazy { ReaderSettings(this) }

    /**
     * The voice reading a book aloud — one book at a time, since there is one
     * synthesizer on the phone. The kit is opened lazily behind a suspending
     * accessor: the first Listen pays for the Swift runtime, not every reader
     * who opens a book.
     */
    val narrations: Narrations by lazy { Narrations(this, { kitAsync() }, readerSettings) }

    private suspend fun kitAsync(): Kit = withContext(Dispatchers.IO) { kit }

    suspend fun library(): LibraryRepository = withContext(Dispatchers.IO) { libraryRepository }

    /**
     * Remove a book, and the Ask conversation about it: its answers quote a
     * book nobody can open any more, and a re-import is a new book with a new
     * id in any case. The one place a book goes away, so the one place the
     * transcript has to.
     */
    suspend fun removeBook(bookId: String) {
        narrations.forget(bookId)
        library().remove(bookId)
        askConversations.forget(bookId)
    }

    suspend fun providers(): ProvidersRepository = withContext(Dispatchers.IO) { providersRepository }

    suspend fun asks(): AskRepository = withContext(Dispatchers.IO) { askRepository }
}
