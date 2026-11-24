package com.readrai.readr.kit

import android.content.Context
import ai.onnxruntime.*
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.nio.channels.FileChannel
import org.json.JSONObject

/** Kokoro-82M v1 int8 on official ONNX Runtime, with Misaki pronunciation. */
class KokoroSynthesizer(context: Context, root: File) {
    private val environment = OrtEnvironment.getEnvironment().apply { setTelemetry(false) }
    private val model = OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads(2); options.setInterOpNumThreads(1)
        environment.createSession(File(root, "model.int8.onnx").path, options)
    }
    private val phonemizer = MisakiPhonemizer(context, environment)
    private val metadata = model.metadata.customMetadata
    private val dimensions = metadata.getValue("style_dim").split(',').map(String::toInt)
    private val speakerCount = metadata.getValue("n_speakers").toInt()
    private val styles = RandomAccessFile(File(root, "voices.bin"), "r").use { file ->
        file.channel.map(FileChannel.MapMode.READ_ONLY, 0, file.length()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
    }
    private val vocab = phonemizer.vocabulary
    init {
        check(dimensions == listOf(510, 1, 256) && speakerCount == 54 && sampleRate() == 24000) { "Unsupported Kokoro model layout" }
        check(styles.capacity() == speakerCount * dimensions[0] * dimensions[2]) { "Incomplete voice styles" }
    }
    fun sampleRate() = metadata.getValue("sample_rate").toInt()
    internal fun phonemes(text: String) = phonemizer.phonemize(text)
    fun generate(text: String, sid: Int = 3, speed: Float = 1f): KokoroAudio = generateWithCallback(text, sid, speed) { 1 }

    fun generateWithCallback(text: String, sid: Int = 3, speed: Float = 1f, callback: (FloatArray) -> Int): KokoroAudio {
        require(sid in 0 until speakerCount && speed.isFinite() && speed in 0.5f..3f)
        val phones = phonemizer.phonemize(text)
        require(phones.isNotBlank()) { "No English text to pronounce" }
        val ids = phones.map { c -> check(vocab.has(c.toString())) { "Unsupported phoneme in English voice" }; vocab.getLong(c.toString()) }
        val pieces = mutableListOf<FloatArray>()
        var offset = 0
        while (offset < ids.size) {
            var end = minOf(ids.size, offset + 508)
            if (end < ids.size) (end - 1 downTo offset + 1).firstOrNull { ids[it] == 16L }?.let { end = it }
            val sequence = longArrayOf(0) + ids.subList(offset, end).toLongArray() + 0L
            val style = FloatArray(256)
            styles.position((sid * 510 + end - offset) * 256); styles.get(style)
            OnnxTensor.createTensor(environment, LongBuffer.wrap(sequence), longArrayOf(1, sequence.size.toLong())).use { tokens ->
                OnnxTensor.createTensor(environment, FloatBuffer.wrap(style), longArrayOf(1, 256)).use { styleTensor ->
                    OnnxTensor.createTensor(environment, FloatBuffer.wrap(floatArrayOf(speed)), longArrayOf(1)).use { speedTensor ->
                        model.run(mapOf("tokens" to tokens, "style" to styleTensor, "speed" to speedTensor)).use { result ->
                            val buffer = (result[0] as OnnxTensor).floatBuffer
                            val samples = FloatArray(buffer.remaining()); buffer.get(samples)
                            check(samples.isNotEmpty() && samples.all { it.isFinite() }) { "Invalid Kokoro audio" }
                            pieces.add(samples)
                            if (callback(samples) == 0) return KokoroAudio(FloatArray(0), sampleRate())
                        }
                    }
                }
            }
            offset = end
            while (offset < ids.size && ids[offset] == 16L) offset++
        }
        val samples = FloatArray(pieces.sumOf { it.size }); var position = 0
        for (piece in pieces) { piece.copyInto(samples, position); position += piece.size }
        return KokoroAudio(samples, sampleRate())
    }
}

class KokoroAudio(val samples: FloatArray, val sampleRate: Int) {
    fun save(filename: String): Boolean {
        val dataSize = samples.size * 2
        val bytes = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN)
        bytes.put("RIFF".toByteArray()); bytes.putInt(dataSize + 36); bytes.put("WAVEfmt ".toByteArray())
        bytes.putInt(16); bytes.putShort(1); bytes.putShort(1); bytes.putInt(sampleRate); bytes.putInt(sampleRate * 2)
        bytes.putShort(2); bytes.putShort(16); bytes.put("data".toByteArray()); bytes.putInt(dataSize)
        samples.forEach { bytes.putShort((it.coerceIn(-1f, 1f) * 32767).toInt().toShort()) }
        File(filename).outputStream().use { it.write(bytes.array()) }
        return true
    }
}
