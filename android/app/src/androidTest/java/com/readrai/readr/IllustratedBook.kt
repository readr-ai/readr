package com.readrai.readr

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * A small EPUB with the things the bundled sample has none of: an inline
 * figure, a link into the book, a link out of it, and an anchor to land on.
 * Alice is 12 chapters of unbroken prose — a fine book and a poor fixture for
 * pictures — so the tests that need a picture build one here.
 *
 * The figure is drawn on the device rather than checked in as bytes, so the
 * test owns its own pixels and there is no binary in the repository.
 */
object IllustratedBook {
    const val TITLE = "The Illustrated Wonderland"
    const val IMAGE_PATH = "OEBPS/images/fig1.png"
    const val MISSING_PATH = "OEBPS/images/nowhere.png"
    const val ALT = "A rabbit in a waistcoat, in outline"
    const val FIGURE_WIDTH = 320
    const val FIGURE_HEIGHT = 200
    const val EXTERNAL_URL = "https://example.org/wonderland/notes"
    const val ANCHOR = "part-two"
    const val FIRST_PATH = "OEBPS/ch1.xhtml"
    const val SECOND_PATH = "OEBPS/ch2.xhtml"
    const val ANCHORED_SENTENCE = "The second part begins here."

    /** Chapter indices. Three of the chapters are nothing but one long link, so a tap anywhere on them lands on it. */
    const val PROSE_CHAPTER = 0
    const val ANCHOR_CHAPTER = 1
    const val EXTERNAL_LINK_CHAPTER = 2
    const val INTERNAL_LINK_CHAPTER = 3
    const val NOTE_CHAPTER = 4

    const val NOTE_ID = "fn5"
    const val NOTE_TEXT = "Carroll told the story on a river outing in July 1862."

    /**
     * The trap for cross-document notes: chapter six lifts a note of its own
     * called `fn1` *and* is one long link to `notes.xhtml#fn1`. Note ids recur
     * document by document, so a reader that answered the link from the notes
     * in hand would show the wrong note and never travel.
     */
    const val CROSS_NOTE_CHAPTER = 5
    const val NOTES_CHAPTER = 6
    const val CROSS_NOTE_ID = "fn1"
    const val CROSS_NOTE_TEXT = "The note of chapter six, which is not the one the link points at."
    const val NOTES_SENTENCE = "The note the link actually points at."

    private val paragraph = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the " +
        "age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light."

    /** Writes the archive to `file` and returns it. */
    fun write(file: File): File {
        file.parentFile?.mkdirs()
        ZipOutputStream(file.outputStream().buffered()).use { zip ->
            zip.put("mimetype", "application/epub+zip".toByteArray())
            zip.put("META-INF/container.xml", CONTAINER.toByteArray())
            zip.put("OEBPS/content.opf", OPF.toByteArray())
            zip.put(FIRST_PATH, firstChapter().toByteArray())
            zip.put(SECOND_PATH, secondChapter().toByteArray())
            zip.put("OEBPS/ch3.xhtml", allOneLink("Chapter Three", EXTERNAL_URL, "the notes online"))
            zip.put("OEBPS/ch4.xhtml", allOneLink("Chapter Four", "ch2.xhtml#$ANCHOR", "the second part"))
            zip.put("OEBPS/ch5.xhtml", noteChapter().toByteArray())
            zip.put("OEBPS/ch6.xhtml", crossNoteChapter().toByteArray())
            zip.put("OEBPS/notes.xhtml", notesDocument().toByteArray())
            zip.put(IMAGE_PATH, png(FIGURE_WIDTH, FIGURE_HEIGHT))
        }
        return file
    }

    /** A PNG of the given pixel size — a plain figure, drawn, not shipped. */
    fun png(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.rgb(0xF2, 0xEC, 0xDE))
        val ink = Paint().apply { color = Color.rgb(0x26, 0x22, 0x1C); strokeWidth = 4f; isAntiAlias = true }
        canvas.drawLine(0f, 0f, width.toFloat(), height.toFloat(), ink)
        canvas.drawLine(0f, height.toFloat(), width.toFloat(), 0f, ink)
        ink.style = Paint.Style.STROKE
        canvas.drawRect(6f, 6f, width - 6f, height - 6f, ink)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    private fun ZipOutputStream.put(name: String, bytes: ByteArray) {
        putNextEntry(ZipEntry(name))
        write(bytes)
        closeEntry()
    }

    private fun firstChapter(): String = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
          <head><title>Chapter One</title><meta charset="utf-8"/></head>
          <body>
            <h1>Chapter One</h1>
            ${(1..6).joinToString("\n") { "<p>1.$it $paragraph</p>" }}
            <p><img src="images/fig1.png" alt="$ALT" width="$FIGURE_WIDTH" height="$FIGURE_HEIGHT"/></p>
            <p>See <a href="ch2.xhtml#$ANCHOR">the second part</a>, or read
               <a href="$EXTERNAL_URL">the notes online</a>.</p>
            ${(7..14).joinToString("\n") { "<p>1.$it $paragraph</p>" }}
          </body>
        </html>
    """.trimIndent()

    private fun secondChapter(): String = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
          <head><title>Chapter Two</title><meta charset="utf-8"/></head>
          <body>
            <h1>Chapter Two</h1>
            <p>A line before the anchor, so landing on it means something.</p>
            <p id="$ANCHOR">$ANCHORED_SENTENCE</p>
            <p><img src="images/fig1.png" alt=""/></p>
            ${(1..8).joinToString("\n") { "<p>2.$it $paragraph</p>" }}
          </body>
        </html>
    """.trimIndent()

    /**
     * A chapter that is nothing but one link, long enough to fill the page —
     * so a tap anywhere on it lands on the link, whatever the geometry.
     */
    private fun allOneLink(title: String, href: String, phrase: String): ByteArray = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
          <head><title>$title</title><meta charset="utf-8"/></head>
          <body>
            <p><a href="$href">${(1..90).joinToString(" ") { "$phrase $it," }}</a></p>
          </body>
        </html>
    """.trimIndent().toByteArray()

    /** A chapter that is one long noteref, and the note it points at. */
    private fun noteChapter(): String = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
          <head><title>Chapter Five</title><meta charset="utf-8"/></head>
          <body>
            <p><a epub:type="noteref" href="#$NOTE_ID">${(1..90).joinToString(" ") { "see the note $it," }}</a></p>
            <aside epub:type="footnote" id="$NOTE_ID"><p>$NOTE_TEXT</p></aside>
          </body>
        </html>
    """.trimIndent()

    /**
     * One long link into another document, over a note of this chapter that
     * answers to the very id the link names — so a tap anywhere on it is a
     * cross-document link that must travel rather than open what is here.
     */
    private fun crossNoteChapter(): String = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
          <head><title>Chapter Six</title><meta charset="utf-8"/></head>
          <body>
            <p><a href="notes.xhtml#$CROSS_NOTE_ID">${(1..90).joinToString(" ") { "read the note $it," }}</a></p>
            <aside epub:type="footnote" id="$CROSS_NOTE_ID"><p>$CROSS_NOTE_TEXT</p></aside>
          </body>
        </html>
    """.trimIndent()

    /** The document those links point into: a plain anchor, not a lifted note. */
    private fun notesDocument(): String = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
          <head><title>Notes</title><meta charset="utf-8"/></head>
          <body>
            <h1>Notes</h1>
            <p>A line before the note, so landing on it means something.</p>
            <p id="$CROSS_NOTE_ID">$NOTES_SENTENCE</p>
            ${(1..6).joinToString("\n") { "<p>N.$it $paragraph</p>" }}
          </body>
        </html>
    """.trimIndent()

    private const val CONTAINER = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

    private const val OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:6b1f0c22-illustrated-wonderland</dc:identifier>
    <dc:title>The Illustrated Wonderland</dc:title>
    <dc:creator>Lewis Carroll</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-09-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch4" href="ch4.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch5" href="ch5.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch6" href="ch6.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/>
    <item id="fig1" href="images/fig1.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="ch3"/>
    <itemref idref="ch4"/>
    <itemref idref="ch5"/>
    <itemref idref="ch6"/>
    <itemref idref="notes"/>
  </spine>
</package>"""
}
