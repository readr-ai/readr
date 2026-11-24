package com.readrai.readr

import com.readrai.readr.kit.NanoSinkGate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class NanoSinkGateTest {
    @Test fun closedSinkDropsLateVendorCallbacks() {
        val calls = AtomicInteger()
        val gate = NanoSinkGate({ calls.incrementAndGet() }, { calls.incrementAndGet() }, { calls.incrementAndGet() })
        gate.close()
        gate.delta("late"); gate.completed("late"); gate.failed("late")
        assertEquals(0, calls.get())
    }
    @Test fun terminalEventIsDeliveredExactlyOnce() {
        val calls = mutableListOf<String>()
        val gate = NanoSinkGate({ calls.add(it) }, { calls.add("finished") }, { calls.add("failed") })
        gate.delta("answer"); gate.completed("answer"); gate.failed("late"); gate.delta("late")
        assertEquals(listOf("answer", "finished"), calls)
    }
    @Test fun closeDrainsAnAlreadyEnteredCallbackBeforeReturning() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val calls = AtomicInteger()
        val gate = NanoSinkGate({ entered.countDown(); check(release.await(3, TimeUnit.SECONDS)); calls.incrementAndGet() }, {}, {})
        val callback = Thread { gate.delta("in flight") }.apply { start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        val closer = Thread { gate.close(); closed.countDown() }.apply { start() }
        try { assertFalse(closed.await(100, TimeUnit.MILLISECONDS)) } finally { release.countDown() }
        assertTrue(closed.await(2, TimeUnit.SECONDS))
        callback.join(1000); closer.join(1000)
        gate.delta("late")
        assertEquals(1, calls.get())
    }
}
