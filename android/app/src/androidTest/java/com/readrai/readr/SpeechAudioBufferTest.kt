package com.readrai.readr
import com.readrai.readr.kit.*
import org.junit.Assert.*
import org.junit.Test
class SpeechAudioBufferTest {
    @Test fun cacheIsBoundedByActualAudioAndPlaybackConsumesIt() {
        val cache = SpeechAudioBuffer(10)
        cache.put("first", KokoroAudio(FloatArray(6), 2))
        cache.put("second", KokoroAudio(FloatArray(6), 2))
        assertNull(cache.take("first"))
        assertEquals(3.0, cache.seconds("second")!!, 0.0)
        assertEquals(6, cache.take("second")!!.samples.size)
        assertNull(cache.seconds("second"))
    }
    @Test fun oversizedEntriesCannotEvictUsefulPreparedSpeech() {
        val cache = SpeechAudioBuffer(10)
        cache.put("small", KokoroAudio(FloatArray(5), 2))
        cache.put("huge", KokoroAudio(FloatArray(11), 2))
        assertNotNull(cache.take("small")); assertNull(cache.take("huge"))
        cache.put("other", KokoroAudio(FloatArray(5), 2)); cache.clear(); assertNull(cache.take("other"))
    }
}
