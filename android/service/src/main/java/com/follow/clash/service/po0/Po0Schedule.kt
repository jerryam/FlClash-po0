package com.follow.clash.service.po0

/** When the next round runs. [Po0Firewall] holds its lock around every call. */
internal class Po0Schedule {
    var dueAt: Long? = null
        private set
    var manualPending = false
        private set
    var screenOn = true
        private set

    private var failures = 0
    private var pendingNetwork = false
    private var screenOffRetries = 0
    private var networkGeneration = 0
    private var roundGeneration = 0
    private var steadyRounds = 0
    private var steadyExits: Set<String>? = null

    fun cancel() {
        dueAt = null
    }

    fun kick(now: Long, delayMs: Long, debounce: Boolean = false) {
        val at = now + delayMs
        val current = dueAt
        dueAt = if (debounce || current == null) at else minOf(current, at)
    }

    /** Whether the screen turning on calls for a round now. */
    fun screen(on: Boolean): Boolean {
        if (screenOn == on) return false
        screenOn = on
        if (!on) {
            if (!pendingNetwork) dueAt = null
            return false
        }
        steadyRounds = 0
        return true
    }

    fun manual() {
        failures = 0
        steadyRounds = 0
        manualPending = true
    }

    fun settingsChanged() {
        failures = 0
        steadyRounds = 0
    }

    fun networkChanged() {
        failures = 0
        pendingNetwork = true
        screenOffRetries = 0
        steadyRounds = 0
        networkGeneration++
    }

    fun startRound() {
        dueAt = null
        manualPending = false
        roundGeneration = networkGeneration
    }

    /** [listedExits]: the exits' /24s when every token found its exit listed, else null. */
    fun finishRound(now: Long, failed: Boolean, listedExits: Set<String>?, settings: Po0Settings, active: Boolean) {
        val roundSawCurrentNetwork = roundGeneration == networkGeneration
        failures = if (failed) failures + 1 else 0
        if (!failed && roundSawCurrentNetwork) {
            pendingNetwork = false
            screenOffRetries = 0
        }
        val steady = roundSawCurrentNetwork && listedExits != null
        steadyRounds = when {
            !steady -> 0
            listedExits == steadyExits -> steadyRounds + 1
            else -> 1
        }
        steadyExits = listedExits.takeIf { steady }
        if (dueAt != null || !active) return
        val delay = if (settings.adaptive && failures == 0) {
            po0RelaxedDelayMs(settings.interval, steadyRounds)
        } else {
            po0NextDelayMs(settings.interval, failures)
        }
        dueAt = when {
            screenOn -> now + delay
            failed && pendingNetwork && screenOffRetries < SCREEN_OFF_RETRIES -> {
                screenOffRetries++
                now + delay
            }
            else -> null
        }
    }

    private companion object {
        const val SCREEN_OFF_RETRIES = 5
    }
}
