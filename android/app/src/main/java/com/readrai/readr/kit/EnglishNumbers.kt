package com.readrai.readr.kit

/** English narration expansion, without locale-dependent or hidden platform APIs. */
internal object EnglishNumbers {
    private val small = listOf("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
    private val tens = listOf("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
    fun integer(n: Long): String = when {
        n < 0 -> error("Use an unsigned number")
        n < 20 -> small[n.toInt()]
        n < 100 -> tens[(n / 10).toInt()] + if (n % 10 == 0L) "" else " " + integer(n % 10)
        n < 1000 -> integer(n / 100) + " hundred" + if (n % 100 == 0L) "" else " " + integer(n % 100)
        else -> {
            val (scale, name) = listOf(1_000_000_000_000_000_000L to "quintillion", 1_000_000_000_000_000L to "quadrillion", 1_000_000_000_000L to "trillion", 1_000_000_000L to "billion", 1_000_000L to "million", 1_000L to "thousand").first { n >= it.first }
            integer(n / scale) + " " + name + if (n % scale == 0L) "" else " " + integer(n % scale)
        }
    }
    private fun number(s: String): String {
        val parts = s.split('.')
        val whole = parts[0].toLongOrNull()?.let(::integer) ?: parts[0].map { small[it.digitToInt()] }.joinToString(" ")
        return whole + if (parts.size == 1) "" else " point " + parts[1].map { small[it.digitToInt()] }.joinToString(" ")
    }
    fun normalize(text: String): String {
        var value = Regex("[0-9]{1,3}(?:,[0-9]{3})+").replace(text) { it.value.replace(",", "") }
        value = Regex("([$£€])([0-9]+)(?:\\.([0-9]{1,2}))?").replace(value) {
            val unit = when (it.groupValues[1]) { "$" -> "dollars"; "£" -> "pounds"; else -> "euros" }
            number(it.groupValues[2]) + " " + unit + it.groupValues[3].takeIf(String::isNotEmpty)?.padEnd(2, '0')?.let { fraction -> " and " + number(fraction) + " cents" }.orEmpty()
        }
        value = Regex("[0-9]+(?:\\.[0-9]+)?(?:st|nd|rd|th)?").replace(value) {
            val numeric = it.value.takeWhile { c -> c.isDigit() || c == '.' }
            val spoken = number(numeric)
            if (numeric == it.value) spoken else {
                val tail = spoken.substringAfterLast(' ')
                val ordinal = mapOf("one" to "first", "two" to "second", "three" to "third", "five" to "fifth", "eight" to "eighth", "nine" to "ninth", "twelve" to "twelfth")[tail]
                    ?: if (tail.endsWith("y")) tail.dropLast(1) + "ieth" else tail + "th"
                spoken.dropLast(tail.length) + ordinal
            }
        }
        return value.replace("%", " percent ").replace("&", " and ").replace("+", " plus ").replace("=", " equals ")
    }
}
