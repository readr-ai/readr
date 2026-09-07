package com.readrai.readr

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * An OpenAI-shaped chat server, running on the device for the length of one
 * test.
 *
 * The streaming path is the whole point of Ask, and there is no way to prove
 * a token reached the reader *while* the model was still writing without a
 * server that writes slowly. This one answers `POST …/chat/completions` with
 * `text/event-stream` and puts [deltas] on the wire [gapMillis] apart,
 * recording when it sent each one ([sentAt]) so a test can compare that
 * against when the token arrived.
 *
 * A non-2xx [status] answers with [errorBody] instead, which is how the
 * rejected-key path is exercised without a real key.
 *
 * Nothing in the app can reach it: the facade only sends a provider here
 * while `AndroidProviders.overrideEndpoint` says so, which nothing but a test
 * calls.
 */
class FakeChatServer(
    private val deltas: List<String> = DEFAULT_DELTAS,
    private val gapMillis: Long = 300,
    private val status: Int = 200,
    private val errorBody: String = "",
) : Closeable {

    private val socket = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))

    /** When each streamed chunk went out, in `System.currentTimeMillis()`. */
    val sentAt = CopyOnWriteArrayList<Long>()

    /** How many chat requests arrived, streaming or validating. */
    @Volatile
    var requests = 0
        private set

    val origin: String get() = "http://127.0.0.1:${socket.localPort}"

    private val worker = Thread {
        while (!socket.isClosed) {
            val connection = try {
                socket.accept()
            } catch (e: Exception) {
                return@Thread
            }
            try {
                connection.use { serve(it) }
            } catch (e: Exception) {
                // A client that hangs up mid-answer (a cancelled ask) is the
                // normal case here, not a failure.
            }
        }
    }.apply { isDaemon = true; start() }

    override fun close() {
        socket.close()
        worker.interrupt()
    }

    private fun serve(connection: Socket) {
        val input = connection.getInputStream()
        val output = connection.getOutputStream()
        val head = readHead(input)
        // curl announces a large POST body and waits to be told to send it.
        if (head.contains("100-continue", ignoreCase = true)) {
            output.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray())
            output.flush()
        }
        val body = readBody(input, contentLength(head))
        requests += 1

        if (status != 200) {
            respond(output, status, "application/json", errorBody)
            return
        }
        // The validation call is an ordinary completion, not a stream; only a
        // request that asked for a stream gets one.
        if (!body.contains("\"stream\":true")) {
            respond(output, 200, "application/json", VALIDATION_BODY)
            return
        }
        output.write(
            (
                "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: text/event-stream\r\n" +
                    "Cache-Control: no-cache\r\n" +
                    "Connection: close\r\n\r\n"
                ).toByteArray()
        )
        output.flush()
        for ((index, delta) in deltas.withIndex()) {
            if (index > 0) Thread.sleep(gapMillis)
            sentAt += System.currentTimeMillis()
            output.write("data: {\"choices\":[{\"delta\":{\"content\":\"${escape(delta)}\"}}]}\n\n".toByteArray())
            output.flush()
        }
        Thread.sleep(gapMillis)
        output.write("data: [DONE]\n\n".toByteArray())
        output.flush()
    }

    private fun respond(output: OutputStream, status: Int, type: String, body: String) {
        val bytes = body.toByteArray()
        output.write(
            (
                "HTTP/1.1 $status ${reason(status)}\r\n" +
                    "Content-Type: $type\r\n" +
                    "Content-Length: ${bytes.size}\r\n" +
                    "Connection: close\r\n\r\n"
                ).toByteArray()
        )
        output.write(bytes)
        output.flush()
    }

    /** Everything up to the blank line that ends the request head. */
    private fun readHead(input: InputStream): String {
        val head = StringBuilder()
        var matched = 0
        while (matched < 4) {
            val byte = input.read()
            if (byte < 0) break
            val c = byte.toChar()
            head.append(c)
            matched = when {
                (matched == 0 || matched == 2) && c == '\r' -> matched + 1
                (matched == 1 || matched == 3) && c == '\n' -> matched + 1
                else -> 0
            }
        }
        return head.toString()
    }

    private fun readBody(input: InputStream, length: Int): String {
        if (length <= 0) return ""
        val bytes = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(bytes, read, length - read)
            if (n < 0) break
            read += n
        }
        return String(bytes, 0, read)
    }

    private fun contentLength(head: String): Int = head.lineSequence()
        .firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
        ?.substringAfter(':')?.trim()?.toIntOrNull() ?: 0

    private fun reason(status: Int): String = when (status) {
        200 -> "OK"
        401 -> "Unauthorized"
        429 -> "Too Many Requests"
        else -> "Error"
    }

    /** Enough JSON escaping for the plain sentences a test streams. */
    private fun escape(text: String): String =
        text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")

    companion object {
        /** Three deltas, so "streamed, not buffered" has something to prove. */
        val DEFAULT_DELTAS = listOf("Alice follows ", "the White Rabbit ", "down the hole.")

        /** What the joined answer should read as. */
        val DEFAULT_ANSWER = DEFAULT_DELTAS.joinToString("")

        private const val VALIDATION_BODY =
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}"
    }
}
