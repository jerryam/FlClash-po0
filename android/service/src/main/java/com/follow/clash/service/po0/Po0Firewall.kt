package com.follow.clash.service.po0

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.PowerManager
import androidx.core.content.getSystemService
import com.follow.clash.common.GlobalState
import com.follow.clash.common.registerReceiverCompat
import com.google.gson.JsonObject
import java.net.Inet4Address
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Keeps the current exit's /24 on every po0 token's whitelist while a FlClash
 * service runs or the app is open, so swiping the app away keeps it going.
 *
 * Each round reads the whitelist (read-only, it takes no slot) and adds the
 * exit only when it is missing. While the VPN runs, every request goes on a
 * socket the VPN service protects, so it leaves on the physical network.
 * With the screen off, only a network change starts a round.
 */
object Po0Firewall {
    private const val PREFERENCES = "po0"
    private const val SETTINGS_KEY = "settings"
    private const val NETWORK_DELAY_MS = 1_000L
    private const val SERVICE_DELAY_MS = 2_000L
    private const val SCREEN_OFF_RETRIES = 5

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val lock = Any()
    private val client = Po0Client(::prepareSocket)
    private val status = MutableStateFlow(Po0Status())
    private val logs = MutableSharedFlow<String>(
        extraBufferCapacity = 32,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    private val context: Context
        get() = GlobalState.application
    private val connectivity by lazy { context.getSystemService<ConnectivityManager>() }

    private var started = false
    private var settings = Po0Settings()
    private val services = LinkedHashSet<Service>()
    private var uiCount = 0
    private var screenOn = true
    private var dueAt: Long? = null
    private var failures = 0
    private var pendingNetwork = false
    private var screenOffRetries = 0
    private val networkAddresses = mutableMapOf<Network, List<String>>()

    private val shouldRun: Boolean
        get() = (services.isNotEmpty() || uiCount > 0) && settings.activeTokens.isNotEmpty()

    fun settingsJson(): String {
        ensureStarted()
        return synchronized(lock) { settings.toJson() }
    }

    /** Saves the settings and returns them as kept, invalid tokens dropped. */
    fun updateSettings(json: String): String {
        ensureStarted()
        val next = Po0Settings.fromJson(json)
        synchronized(lock) {
            settings = next
            failures = 0
            val tokens = next.tokens.map { it.token }.toSet()
            status.update { it.copy(results = it.results.filterKeys(tokens::contains)) }
        }
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(SETTINGS_KEY, next.toJson())
            .apply()
        kick()
        return next.toJson()
    }

    /** Sends the status, then every status change and log line, as JSON. */
    fun observe(target: CoroutineScope, onEvent: (String) -> Unit): Job = target.launch {
        launch { logs.collect { onEvent(it) } }
        status.collect { onEvent(it.toJson()) }
    }

    fun attachUi() {
        ensureStarted()
        synchronized(lock) { uiCount++ }
        kick()
    }

    fun detachUi() {
        synchronized(lock) { uiCount = (uiCount - 1).coerceAtLeast(0) }
    }

    fun runNow() {
        synchronized(lock) {
            if (!shouldRun) return
            failures = 0
            status.update { it.copy(busy = true) }
        }
        kick()
    }

    fun kick() = kick(0)

    internal fun attachService(service: Service) {
        ensureStarted()
        synchronized(lock) { services.add(service) }
        client.reset()
        kick(SERVICE_DELAY_MS)
    }

    internal fun detachService(service: Service) {
        synchronized(lock) { services.remove(service) }
        client.reset()
        kick(SERVICE_DELAY_MS)
    }

    private fun kick(delayMs: Long, debounce: Boolean = false) {
        synchronized(lock) {
            if (!shouldRun) {
                dueAt = null
                return
            }
            val at = now() + delayMs
            val current = dueAt
            dueAt = if (debounce || current == null) at else minOf(current, at)
        }
        wake.trySend(Unit)
    }

    private fun now() = System.nanoTime() / 1_000_000

    private fun ensureStarted() {
        synchronized(lock) {
            if (started) return
            started = true
            settings = Po0Settings.fromJson(
                context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(SETTINGS_KEY, null),
            )
            screenOn = context.getSystemService<PowerManager>()?.isInteractive ?: true
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        context.registerReceiverCompat(screenReceiver, filter)
        runCatching { connectivity?.registerNetworkCallback(networkRequest, networkCallback) }
            .onFailure { log("无法监听网络变化：$it", warning = true) }
        scope.launch { loop() }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON -> onScreen(true)
                Intent.ACTION_SCREEN_OFF -> onScreen(false)
            }
        }
    }

    private fun onScreen(on: Boolean) {
        synchronized(lock) {
            if (screenOn == on) return
            screenOn = on
            if (!on) {
                if (!pendingNetwork) dueAt = null
                return
            }
        }
        client.reset()
        kick()
    }

    private val networkRequest = NetworkRequest.Builder()
        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        .build()

    // Only a change of IPv4 addresses can move the exit's /24.
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val addresses = linkProperties.linkAddresses
                .mapNotNull { (it.address as? Inet4Address)?.hostAddress }
                .sorted()
            val changed = synchronized(lock) { networkAddresses.put(network, addresses) != addresses }
            if (changed) onNetworkChanged()
        }

        override fun onLost(network: Network) {
            val known = synchronized(lock) { networkAddresses.remove(network) != null }
            if (known) onNetworkChanged()
        }
    }

    private fun onNetworkChanged() {
        client.reset()
        synchronized(lock) {
            failures = 0
            pendingNetwork = true
            screenOffRetries = 0
        }
        kick(NETWORK_DELAY_MS, debounce = true)
    }

    private fun prepareSocket(socket: Socket) {
        val vpn = synchronized(lock) { services.firstNotNullOfOrNull { it as? VpnService } }
        if (vpn != null) {
            if (!vpn.protect(socket)) throw Po0RouteUnavailable("请求无法绕过 VPN")
            return
        }
        val manager = connectivity ?: return
        val active = manager.activeNetwork ?: return
        if (manager.getNetworkCapabilities(active)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) {
            throw Po0RouteUnavailable("VPN 正在启停，稍后重试")
        }
    }

    private suspend fun loop() {
        while (true) {
            val wait = synchronized(lock) { dueAt?.let { (it - now()).coerceAtLeast(0) } }
            when {
                wait == null -> wake.receive()
                wait > 0 -> withTimeoutOrNull(wait) { wake.receive() }
                else -> try {
                    round()
                } catch (error: Exception) {
                    log("检查出错：$error", warning = true)
                    finish(failed = true)
                }
            }
        }
    }

    private suspend fun round() {
        val tokens = synchronized(lock) {
            dueAt = null
            if (!shouldRun) {
                status.update { it.copy(busy = false) }
                return
            }
            settings.activeTokens
        }
        var failed = false
        for (entry in tokens) {
            val result = try {
                whitelist(entry)
            } catch (error: Po0RouteUnavailable) {
                Po0Result(Po0ResultType.ERROR, System.currentTimeMillis(), message = error.message)
            }
            failed = failed || result.type == Po0ResultType.ERROR
            put(entry, result)
        }
        finish(failed)
    }

    private suspend fun whitelist(entry: Po0Token): Po0Result {
        val checked = client.check(entry.token)
        if (checked.type != Po0ResultType.NOT_APPLIED) return checked
        val added = client.add(entry.token)
        if (added.type == Po0ResultType.APPLIED) {
            log("${entry.label}：已加白 ${po0C24Of(added.currentIp.orEmpty())}")
            return added
        }
        // A refused add says nothing of the list, and the page shows how full it is.
        return added.copy(
            currentIp = added.currentIp ?: checked.currentIp,
            whitelist = added.whitelist.ifEmpty { checked.whitelist },
            limit = added.limit ?: checked.limit,
        )
    }

    private fun put(entry: Po0Token, result: Po0Result) {
        val previous = status.value.results[entry.token]
        status.update { it.copy(results = it.results + (entry.token to result)) }
        if (previous?.type != result.type || previous?.currentIp != result.currentIp) {
            log("${entry.label}：${describePo0Result(result)}", warning = result.type == Po0ResultType.ERROR)
        }
    }

    private fun finish(failed: Boolean) {
        synchronized(lock) { finishLocked(failed) }
    }

    private fun finishLocked(failed: Boolean) {
        failures = if (failed) failures + 1 else 0
        if (!failed) {
            pendingNetwork = false
            screenOffRetries = 0
        }
        val tokens = settings.tokens.map { it.token }.toSet()
        status.update {
            it.copy(
                results = it.results.filterKeys(tokens::contains),
                lastRound = System.currentTimeMillis(),
                busy = false,
            )
        }
        if (dueAt != null || !shouldRun) return
        val delay = po0NextDelayMs(settings.interval, failures)
        dueAt = when {
            screenOn -> now() + delay
            failed && pendingNetwork && screenOffRetries < SCREEN_OFF_RETRIES -> {
                screenOffRetries++
                now() + delay
            }
            else -> null
        }
    }

    private fun log(message: String, warning: Boolean = false) {
        GlobalState.log("[po0] $message")
        logs.tryEmit(
            JsonObject().apply {
                addProperty("type", "log")
                addProperty("level", if (warning) "warning" else "info")
                addProperty("message", "[po0] $message")
            }.toString(),
        )
    }
}
