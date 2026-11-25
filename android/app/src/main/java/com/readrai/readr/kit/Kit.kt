package com.readrai.readr.kit

import java.io.File
import org.swift.swiftkit.core.SwiftArena

/**
 * The process's handle on ReadrKit. Wraps the jextract-generated
 * `com.readrai.readr.kit.AndroidLibrary` and `AndroidProviders` facades
 * (native Swift, cross-compiled from the repo's `Sources/ReadrKit`).
 *
 * Opening loads the Swift runtime and reads the whole library file, so call
 * `open` off the main thread; the arena owns the Swift objects for the life
 * of the process.
 */
class Kit private constructor(
    @Suppress("unused") private val arena: SwiftArena,
    val library: AndroidLibrary,
    val providers: AndroidProviders,
) {
    companion object {
        /**
         * `model` is the phone's own model — see [NanoModel]: what it can say
         * about itself, and what it answers. Its readiness is asked on every
         * read of the active selection, so an answer that changes (AICore
         * finishing a download) changes what Settings shows without anything
         * being re-opened.
         */
        fun open(root: File, secrets: SecretStore, model: OnDeviceModel): Kit {
            val arena = SwiftArena.ofAuto()
            val library = AndroidLibrary.init(root.absolutePath, arena)
            val providers = AndroidProviders.init(secrets, root.absolutePath, model, arena)
            return Kit(arena, library, providers)
        }
    }
}
