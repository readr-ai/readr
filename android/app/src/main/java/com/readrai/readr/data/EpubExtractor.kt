package com.readrai.readr.data

import com.readrai.readr.kit.KitLimits
import java.io.File
import java.io.InputStream
import java.util.zip.ZipException
import java.util.zip.ZipInputStream

/**
 * Unzips an EPUB into a directory for ReadrKit's `DirectoryEPUBContainer`,
 * enforcing the kit's own ceilings (`EPUBExtractionLimits`, read through the
 * bridge so the two cannot drift) and rejecting path traversal. The archive
 * bytes stream through once; nothing is held in memory. `Rejected` messages
 * are reader-facing and never include archive entry names.
 */
object EpubExtractor {
    private val perEntryCap: Long by lazy { KitLimits.epubPerEntryByteCap() }
    private val totalCap: Long by lazy { KitLimits.epubCumulativeByteCap() }

    class Rejected(message: String) : Exception(message)

    fun extract(input: InputStream, into: File) {
        into.deleteRecursively()
        into.mkdirs()
        val root = into.canonicalFile
        var total = 0L
        ZipInputStream(input.buffered()).use { zip ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                // Android 14+ validates entry paths itself (SafeZipPathValidator);
                // older versions rely on the canonical-path check below.
                val entry = try { zip.nextEntry } catch (e: ZipException) { throw Rejected("This file isn't a valid EPUB archive.") } ?: break
                if (entry.isDirectory) { zip.closeEntry(); continue }
                val target = File(root, entry.name).canonicalFile
                if (!target.path.startsWith(root.path + File.separator)) throw Rejected("This EPUB isn't safe to open: an entry points outside the archive.")
                target.parentFile?.mkdirs()
                var written = 0L
                target.outputStream().use { out ->
                    while (true) {
                        val n = zip.read(buffer)
                        if (n < 0) break
                        written += n; total += n
                        if (written > perEntryCap) throw Rejected("This EPUB has an entry larger than Readr will open.")
                        if (total > totalCap) throw Rejected("This EPUB expands past the size Readr will open.")
                        out.write(buffer, 0, n)
                    }
                }
                zip.closeEntry()
            }
        }
    }
}
