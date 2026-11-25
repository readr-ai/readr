package com.readrai.readr.kit

/** Small LRU of immutable PCM. Counts samples, not requests, to bound memory. */
internal class SpeechAudioBuffer(private val capacitySamples: Int = 3_000_000) {
    private val audio = LinkedHashMap<String, KokoroAudio>(8, 0.75f, true)
    private var samples = 0
    @Synchronized fun put(key: String, value: KokoroAudio) {
        if (value.samples.size > capacitySamples) return
        audio.remove(key)?.let { samples -= it.samples.size }
        audio[key] = value; samples += value.samples.size
        while (samples > capacitySamples || audio.size > 8) {
            val eldest = audio.entries.first(); samples -= eldest.value.samples.size; audio.remove(eldest.key)
        }
    }
    @Synchronized fun take(key: String): KokoroAudio? = audio.remove(key)?.also { samples -= it.samples.size }
    @Synchronized fun seconds(key: String): Double? = audio[key]?.let { it.samples.size.toDouble() / it.sampleRate }
    @Synchronized fun clear() { audio.clear(); samples = 0 }
}
