package com.follow.clash.service.po0

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Po0ScheduleTest {
    private val settings = Po0Settings(interval = 5)
    private val exits = setOf("1.2.3.0/24")

    private fun Po0Schedule.round(
        failed: Boolean = false,
        listed: Set<String>? = exits,
        config: Po0Settings = settings,
    ): Long? {
        startRound()
        finishRound(0, failed, listed, config, active = true)
        return dueAt
    }

    @Test
    fun `follows the interval and backs off after failures`() {
        val schedule = Po0Schedule()
        assertEquals(5_000L, schedule.round(listed = null))
        assertEquals(10_000L, schedule.round(failed = true, listed = null))
        assertEquals(20_000L, schedule.round(failed = true, listed = null))
        assertEquals(5_000L, schedule.round(listed = null))
    }

    @Test
    fun `slows down to a minute while the same exits stay listed`() {
        val schedule = Po0Schedule()
        assertEquals(
            listOf(5_000L, 5_000L, 10_000L, 20_000L, 40_000L, 60_000L, 60_000L),
            List(7) { schedule.round() },
        )
    }

    @Test
    fun `a new exit, a network change, the screen or a manual run goes back to the interval`() {
        val schedule = Po0Schedule()
        repeat(5) { schedule.round() }
        assertEquals(5_000L, schedule.round(listed = setOf("5.6.7.0/24")))
        repeat(5) { schedule.round() }
        schedule.networkChanged()
        assertEquals(5_000L, schedule.round())
        repeat(5) { schedule.round() }
        schedule.manual()
        assertEquals(5_000L, schedule.round())
        repeat(5) { schedule.round() }
        schedule.screen(false)
        schedule.screen(true)
        assertEquals(5_000L, schedule.round())
    }

    @Test
    fun `keeps the interval when slowing down is off`() {
        val schedule = Po0Schedule()
        val fixed = settings.copy(adaptive = false)
        repeat(6) { assertEquals(5_000L, schedule.round(config = fixed)) }
    }

    @Test
    fun `with the screen off only a network change schedules rounds, retried at most five times`() {
        val schedule = Po0Schedule()
        assertFalse(schedule.screen(false))
        assertNull(schedule.round())
        schedule.networkChanged()
        schedule.kick(0, 1_000, debounce = true)
        assertEquals(1_000L, schedule.dueAt)
        assertEquals(
            listOf(10_000L, 20_000L, 30_000L, 30_000L, 30_000L, null),
            List(6) { schedule.round(failed = true, listed = null) },
        )
        schedule.networkChanged()
        assertNull(schedule.round())
        assertTrue(schedule.screen(true))
    }

    @Test
    fun `a round from before a network change leaves its retries pending`() {
        val schedule = Po0Schedule()
        schedule.screen(false)
        schedule.startRound()
        schedule.networkChanged()
        schedule.kick(0, 1_000, debounce = true)
        schedule.finishRound(0, failed = false, listedExits = exits, settings = settings, active = true)
        assertEquals(1_000L, schedule.dueAt)
        assertEquals(10_000L, schedule.round(failed = true, listed = null))
    }

    @Test
    fun `a manual run stays busy through a round already under way`() {
        val schedule = Po0Schedule()
        schedule.startRound()
        schedule.manual()
        schedule.kick(0, 0)
        schedule.finishRound(0, failed = false, listedExits = exits, settings = settings, active = true)
        assertTrue(schedule.manualPending)
        assertEquals(0L, schedule.dueAt)
        schedule.round()
        assertFalse(schedule.manualPending)
    }

    @Test
    fun `a kick keeps the sooner round unless it debounces, and nothing runs while inactive`() {
        val schedule = Po0Schedule()
        schedule.kick(0, 5_000)
        schedule.kick(0, 1_000)
        assertEquals(1_000L, schedule.dueAt)
        schedule.kick(0, 3_000, debounce = true)
        assertEquals(3_000L, schedule.dueAt)
        schedule.startRound()
        schedule.finishRound(0, failed = false, listedExits = null, settings = settings, active = false)
        assertNull(schedule.dueAt)
    }
}
