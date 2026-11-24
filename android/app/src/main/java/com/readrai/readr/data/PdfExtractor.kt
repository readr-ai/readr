package com.readrai.readr.data

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import com.googlecode.tesseract.android.TessBaseAPI
import android.content.Context
import java.io.File
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Native text extraction on Android 15+, local bundled Tesseract OCR for scans/older phones. */
object PdfExtractor {
    suspend fun pages(context: Context, file: File): List<String> {
        var recognizer: TessBaseAPI? = null
        fun ocr(): TessBaseAPI {
            recognizer?.let { return it }
            val root = File(context.filesDir, "ocr")
            val data = File(root, "tessdata/eng.traineddata")
            fun validData(): Boolean {
                if (!data.isFile || data.length() != 4113088L) return false
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                data.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) } }
                return digest.digest().joinToString("") { "%02x".format(it) } == "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"
            }
            if (!validData()) {
                data.parentFile!!.mkdirs()
                val partial = File(data.parentFile, "eng.partial")
                context.assets.open("eng.traineddata").use { input -> partial.outputStream().use { input.copyTo(it) } }
                check(partial.renameTo(data)) { "Could not install OCR data" }
            }
            val candidate = TessBaseAPI()
            try { check(candidate.init(root.path, "eng")) { "OCR could not start" }; recognizer = candidate; return candidate }
            catch (e: Exception) { candidate.recycle(); throw e }
        }
        try {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { document ->
                    require(document.pageCount > 0) { "This PDF has no pages." }
                    val pages = ArrayList<String>(document.pageCount)
                    for (index in 0 until document.pageCount) {
                        currentCoroutineContext().ensureActive()
                        document.openPage(index).use { page ->
                            val text = if (Build.VERSION.SDK_INT >= 35) page.textContents.joinToString("\n") { it.text } else ""
                            if (text.isNotBlank()) { pages.add(text); return@use }
                            val scale = 2200f / maxOf(page.width, page.height).coerceAtLeast(1)
                            val bitmap = Bitmap.createBitmap(maxOf(1, (page.width * scale).toInt()), maxOf(1, (page.height * scale).toInt()), Bitmap.Config.ARGB_8888)
                            bitmap.eraseColor(Color.WHITE)
                            try {
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                val engine = ocr()
                                engine.setImage(bitmap)
                                pages.add(engine.utF8Text.orEmpty())
                                engine.clear()

                            } finally { bitmap.recycle() }
                        }
                    }
                    return pages
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: SecurityException) { throw LibraryRepository.ImportFailed("This PDF is password protected. Import an unlocked copy.") }
        catch (e: Exception) { throw LibraryRepository.ImportFailed("Readr couldn't read this PDF. Check that it opens elsewhere and import an unlocked, undamaged copy.") }
        finally { recognizer?.recycle() }
    }
}
