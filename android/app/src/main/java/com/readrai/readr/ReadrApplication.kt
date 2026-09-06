package com.readrai.readr

import android.app.Application
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ReadrApplication : Application() {
    /** Opened on first use, off the main thread: loading the Swift runtime and decoding library.json is real work. */
    private val kit: Kit by lazy { Kit.open(filesDir, KeystoreSecretStore(this)) }
    private val libraryRepository: LibraryRepository by lazy { LibraryRepository(this, kit) }

    suspend fun library(): LibraryRepository = withContext(Dispatchers.IO) { libraryRepository }
}
