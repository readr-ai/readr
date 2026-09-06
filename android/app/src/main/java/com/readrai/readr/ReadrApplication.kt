package com.readrai.readr

import android.app.Application
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit

class ReadrApplication : Application() {
    lateinit var kit: Kit
        private set
    lateinit var library: LibraryRepository
        private set

    override fun onCreate() {
        super.onCreate()
        kit = Kit.open(filesDir, KeystoreSecretStore(this))
        library = LibraryRepository(this, kit)
    }
}
