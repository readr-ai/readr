package com.readrai.readr.data

import java.io.File
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Unzips an EPUB into a directory for ReadrKit's `DirectoryEPUBContainer`,
 * with the same ceilings as the kit's `EPUBExtractionLimits` (64 MB per
 * entry, 512 MB in total) and no path traversal. The archive bytes stream
 * through once; nothing is held in memory.
 */
object EpubExtractor {
    private const val PER_ENTRY_CAP = 64L * 1024 * 1024
    private const val TOTAL_CAP = 512L * 1024 * 1024

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
                val entry = try { zip.nextEntry } catch (e: java.util.zip.ZipException) { throw Rejected("malformed archive: ${e.message}") } ?: break
                if (entry.isDirectory) { zip.closeEntry(); continue }
                val target = File(root, entry.name).canonicalFile
                if (!target.path.startsWith(root.path + File.separator)) throw Rejected("entry escapes the archive: ${entry.name}")
                target.parentFile?.mkdirs()
                var written = 0L
                target.outputStream().use { out ->
                    while (true) {
                        val n = zip.read(buffer)
                        if (n < 0) break
                        written += n; total += n
                        if (written > PER_ENTRY_CAP) throw Rejected("entry too large: ${entry.name}")
                        if (total > TOTAL_CAP) throw Rejected("archive expands past the cumulative cap")
                        out.write(buffer, 0, n)
                    }
                }
                zip.closeEntry()
            }
        }
    }
}
