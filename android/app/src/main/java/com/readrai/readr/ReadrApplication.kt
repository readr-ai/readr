package com.readrai.readr

import android.app.Application
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.ProvidersRepository
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
import com.readrai.readr.ui.reader.ReaderSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ReadrApplication : Application() {
    /** Opened on first use, off the main thread: loading the Swift runtime and decoding library.json is real work. */
    private val kit: Kit by lazy { Kit.open(filesDir, KeystoreSecretStore(this), NanoProbe(this)) }
    private val libraryRepository: LibraryRepository by lazy { LibraryRepository(this, kit) }
    private val providersRepository: ProvidersRepository by lazy { ProvidersRepository(kit) }
    /** Reader appearance; plain preferences, read on the main thread (one small file). */
    val readerSettings: ReaderSettings by lazy { ReaderSettings(this) }

    suspend fun library(): LibraryRepository = withContext(Dispatchers.IO) { libraryRepository }

    suspend fun providers(): ProvidersRepository = withContext(Dispatchers.IO) { providersRepository }
}
