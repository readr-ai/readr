package com.readrai.readr.kit

import java.io.File
import org.swift.swiftkit.core.SwiftArena

/**
 * The process's handle on ReadrKit. Wraps the jextract-generated
 * `com.readrai.readr.kit.AndroidLibrary` / `AndroidCredentials` facades
 * (native Swift, cross-compiled from the repo's `Sources/ReadrKit`).
 *
 * The arena owns the Swift objects' lifetime; it lives as long as the process.
 */
class Kit private constructor(
    val arena: SwiftArena,
    val library: AndroidLibrary,
    val credentials: AndroidCredentials,
) {
    val description: String get() = library.kitDescription()

    companion object {
        fun open(root: File, secrets: SecretStore): Kit {
            val arena = SwiftArena.ofAuto()
            val library = AndroidLibrary.init(root.absolutePath, arena)
            val credentials = AndroidCredentials.init(secrets, arena)
            return Kit(arena, library, credentials)
        }
    }
}
