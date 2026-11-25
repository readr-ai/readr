package com.readrai.readr
import com.readrai.readr.kit.EnglishNumbers
import org.junit.Assert.assertEquals
import org.junit.Test
class EnglishNumbersTest {
    @Test fun pdfNumbersAndCurrenciesKeepTheirMeaning() {
        assertEquals("Chapter twenty third", EnglishNumbers.normalize("Chapter 23rd"))
        assertEquals("one thousand two hundred thirty four", EnglishNumbers.normalize("1,234"))
        assertEquals("twelve dollars and fifty cents", EnglishNumbers.normalize("$12.50"))
        assertEquals("zero point zero five", EnglishNumbers.normalize("0.05"))
        assertEquals("five percent ", EnglishNumbers.normalize("5%"))
    }
    @Test fun largeNumbersDoNotOverflowOrDisappear() {
        assertEquals("one two three four five six seven eight nine zero one two three four five six seven eight nine zero", EnglishNumbers.normalize("12345678901234567890"))
        assertEquals("one million", EnglishNumbers.integer(1_000_000))
    }
}
