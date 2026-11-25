package com.readrai.readr.kit

import android.content.Context
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.LongBuffer
import java.text.Normalizer
import java.util.Locale
import org.json.JSONObject

/** English Misaki word lists plus the neural BART fallback. No word is silently discarded.
 * Dictionaries/model: nekwo/misaki-en-us-g2p-onnx @ 4b3a605d2f605318ab4f762ab9855c44106528b7.
 * Misaki and PeterReid fallback are Apache-2.0; see assets/THIRD-PARTY-NOTICES.md.
 * Heteronyms use the dictionary's DEFAULT pronunciation (no POS tagger).
 */
internal class MisakiPhonemizer(context: Context, private val environment: OrtEnvironment) {
    private val metadata = context.assets.open("misaki-en_us-g2p.json").bufferedReader().use { JSONObject(it.readText()) }
    val vocabulary: JSONObject = metadata.getJSONObject("kokoro_vocab")
    private val gold = metadata.getJSONObject("gold")
    private val silver = metadata.getJSONObject("silver")
    private val graphemes = metadata.getString("graphemes").mapIndexed { i, c -> c to i.toLong() }.toMap()
    private val phonemes = metadata.getString("phonemes")
    private val fallback = OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads(1); options.setInterOpNumThreads(1)
        environment.createSession(context.assets.open("misaki-en_us-g2p.onnx").use { it.readBytes() }, options)
    }
    private val cache = object : LinkedHashMap<String, String>(512, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > 2048
    }
    fun phonemize(text: String): String {
        var normalized = Normalizer.normalize(text, Normalizer.Form.NFKC).replace('’', '\'').replace('“', '"').replace('”', '"')
        for ((short, full) in mapOf("Mr." to "Mister", "Mrs." to "Missus", "Dr." to "Doctor", "Ms." to "Miss")) normalized = normalized.replace(Regex("\\b${Regex.escape(short)}"), full)
        normalized = EnglishNumbers.normalize(normalized)
        val tokens = Regex("[\\p{L}]+(?:'[\\p{L}]+)*|[^\\s\\p{L}]").findAll(normalized).map { it.value }.toList()
        return buildString {
            for ((index, token) in tokens.withIndex()) {
                if (token.first().isLetter()) {
                    val following = tokens.getOrNull(index + 1)
                    val vowel = following?.firstOrNull()?.lowercaseChar() in listOf('a', 'e', 'i', 'o', 'u')
                    val ps = when (token) {
                        "the", "The" -> if (vowel) "ði" else "ðə"
                        "a", "A" -> "ɐ"
                        "an", "An" -> "ɐn"
                        "to", "To" -> if (vowel) "tʊ" else "tə"
                        "I" -> "ˌI"
                        else -> word(token)
                    }
                    if (isNotEmpty() && last() != ' ') append(' ')
                    append(ps)
                } else if (token in listOf(".", ",", ";", ":", "!", "?", "—", "…", "\"", "(", ")")) append(token)
            }
        }.trim()
    }
    private fun lookup(word: String): String? {
        val entry = gold.opt(word) ?: silver.opt(word) ?: return null
        return when (entry) { is String -> entry; is JSONObject -> entry.optString("DEFAULT").takeIf { it.isNotEmpty() }; else -> null }
    }
    private fun word(raw: String): String = cache.getOrPut(raw) {
        val lower = Normalizer.normalize(raw.lowercase(Locale.US), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
        lookup(raw) ?: lookup(lower) ?: predict(lower).ifBlank {
            // The neural decoder can choose EOS immediately. Spell the word
            // rather than skipping it; if spelling is impossible, fail honestly.
            lower.map { c -> lookup(c.uppercase()) ?: error("Unsupported English grapheme") }.joinToString(" ")
        }
    }
    private fun predict(word: String): String {
        if (word.length > 128) return ""
        val unknown = metadata.getLong("unknown_id")
        val input = longArrayOf(metadata.getLong("bos_id")) + word.map { graphemes[it] ?: unknown }.toLongArray() + metadata.getLong("eos_id")
        val output = mutableListOf(metadata.getLong("start_id"))
        OnnxTensor.createTensor(environment, LongBuffer.wrap(input), longArrayOf(1, input.size.toLong())).use { encoded ->
            repeat(metadata.getInt("max_steps") - 1) {
                val ids = output.toLongArray()
                OnnxTensor.createTensor(environment, LongBuffer.wrap(ids), longArrayOf(1, ids.size.toLong())).use { decoded ->
                    fallback.run(mapOf("input_ids" to encoded, "decoder_input_ids" to decoded)).use { result ->
                        @Suppress("UNCHECKED_CAST")
                        val row = (result[0].value as Array<Array<FloatArray>>)[0].last()
                        val best = row.indices.maxBy { row[it] }.toLong()
                        output.add(best)
                        if (best == metadata.getLong("eos_id")) return output.filter { it > 3 && it < phonemes.length }.map { phonemes[it.toInt()] }.joinToString("")
                    }
                }
            }
        }
        error("English pronunciation did not finish")
    }
}
