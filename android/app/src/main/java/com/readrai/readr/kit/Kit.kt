package com.readrai.readr.kit

import java.io.File
import org.swift.swiftkit.core.SwiftArena

/**
 * The process's handle on ReadrKit. Wraps the jextract-generated
 * `com.readrai.readr.kit.AndroidLibrary` / `AndroidCredentials` facades
 * (native Swift, cross-compiled from the repo's `Sources/ReadrKit`).
 *
 * Opening loads the Swift runtime and reads the whole library file, so call
 * `open` off the main thread; the arena owns the Swift objects for the life
 * of the process.
 */
class Kit private constructor(
    @Suppress("unused") private val arena: SwiftArena,
    val library: AndroidLibrary,
    val credentials: AndroidCredentials,
) {
    companion object {
        fun open(root: File, secrets: SecretStore): Kit {
            val arena = SwiftArena.ofAuto()
            val library = AndroidLibrary.init(root.absolutePath, arena)
            val credentials = AndroidCredentials.init(secrets, arena)
            return Kit(arena, library, credentials)
        }
    }
}
