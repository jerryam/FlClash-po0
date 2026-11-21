package com.follow.clash.service.po0

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/** The po0 firewall API answers on this address only, and whitelists the /24 the request comes from. */
internal const val PO0_API_HOST = "124.221.69.228"
internal const val PO0_MIN_INTERVAL = 1
internal const val PO0_MAX_INTERVAL = 3600
internal const val PO0_DEFAULT_INTERVAL = 5
internal const val PO0_MAX_BACKOFF_MS = 30_000L

private val tokenPattern = Regex("^pgnfw_[^\\s,|;@/?#&]+$")

internal data class Po0Token(
    val token: String,
    val name: String = "",
    val enabled: Boolean = true,
) {
    val label: String
        get() = name.ifEmpty { maskPo0Token(token) }
}

internal data class Po0Settings(
    val enabled: Boolean = true,
    val tokens: List<Po0Token> = emptyList(),
    val interval: Int = PO0_DEFAULT_INTERVAL,
) {
    val activeTokens: List<Po0Token>
        get() = if (enabled) tokens.filter { it.enabled } else emptyList()

    fun toJson(): String = JsonObject().apply {
        addProperty("enabled", enabled)
        addProperty("interval", interval)
        add("tokens", JsonArray().apply {
            tokens.forEach { entry ->
                add(JsonObject().apply {
                    addProperty("token", entry.token)
                    addProperty("name", entry.name)
                    addProperty("enabled", entry.enabled)
                })
            }
        })
    }.toString()

    companion object {
        fun fromJson(text: String?): Po0Settings {
            val data = text?.let(::parseObject) ?: return Po0Settings()
            val seen = mutableSetOf<String>()
            val tokens = data.array("tokens").mapNotNull { item ->
                val entry = item.takeIf { it.isJsonObject }?.asJsonObject ?: return@mapNotNull null
                val token = entry.string("token")?.takeIf { tokenPattern.matches(it) }
                    ?: return@mapNotNull null
                if (!seen.add(token)) return@mapNotNull null
                Po0Token(
                    token = token,
                    name = entry.string("name").orEmpty(),
                    enabled = entry.boolean("enabled") != false,
                )
            }
            return Po0Settings(
                enabled = data.boolean("enabled") != false,
                tokens = tokens,
                interval = data.number("interval")?.toInt()?.coerceIn(PO0_MIN_INTERVAL, PO0_MAX_INTERVAL)
                    ?: PO0_DEFAULT_INTERVAL,
            )
        }
    }
}

internal enum class Po0ResultType(val wire: String) {
    APPLIED("applied"),
    NOT_APPLIED("notApplied"),
    DISABLED("disabled"),
    REJECTED("rejected"),
    ERROR("error"),
}

internal data class Po0Result(
    val type: Po0ResultType,
    val time: Long,
    val currentIp: String? = null,
    val whitelist: List<String> = emptyList(),
    val limit: Int? = null,
    val message: String? = null,
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("type", type.wire)
        addProperty("time", time)
        addProperty("currentIp", currentIp)
        add("whitelist", JsonArray().apply { whitelist.forEach { add(it) } })
        addProperty("limit", limit)
        addProperty("message", message)
    }
}

internal data class Po0Status(
    val results: Map<String, Po0Result> = emptyMap(),
    val lastRound: Long? = null,
    val busy: Boolean = false,
) {
    fun toJson(): String = JsonObject().apply {
        addProperty("type", "status")
        add("results", JsonObject().apply {
            results.forEach { (token, result) -> add(token, result.toJson()) }
        })
        addProperty("lastRound", lastRound)
        addProperty("busy", busy)
    }.toString()
}

internal fun describePo0Result(result: Po0Result): String {
    val exit = result.currentIp?.takeIf { it.isNotEmpty() }?.let { "（出口 ${po0C24Of(it)}）" }.orEmpty()
    return when (result.type) {
        Po0ResultType.APPLIED -> "已加白$exit"
        Po0ResultType.NOT_APPLIED -> "未加白$exit"
        Po0ResultType.DISABLED -> "po0 端防火墙未开启"
        Po0ResultType.REJECTED -> "被拒绝：${result.message.orEmpty()}"
        Po0ResultType.ERROR -> "失败：${result.message.orEmpty()}"
    }
}

internal fun maskPo0Token(token: String): String =
    if (token.length <= 12) token else token.substring(0, 12) + "…"

internal fun redactPo0Token(text: String, token: String): String =
    text.replace(token, maskPo0Token(token))

/** The server lists whole /24s, as an address or as `x.x.x.0/24`. */
internal fun samePo0C24(a: String?, b: String?): Boolean {
    if (a.isNullOrEmpty() || b.isNullOrEmpty()) return false
    if (a == b) return true
    val pa = a.removeSuffix("/24").split('.')
    val pb = b.removeSuffix("/24").split('.')
    return pa.size == 4 && pb.size == 4 && pa.subList(0, 3) == pb.subList(0, 3)
}

internal fun po0C24Of(ip: String): String {
    val parts = ip.removeSuffix("/24").split('.')
    return if (parts.size == 4) "${parts[0]}.${parts[1]}.${parts[2]}.0/24" else ip
}

/**
 * The part of a network's addresses that can move the exit: its IPv4
 * addresses, and its global IPv6 /64s for networks that reach IPv4 through
 * NAT64. Rotating IPv6 privacy addresses keep their /64, so they are ignored.
 */
internal fun po0AddressKeys(addresses: List<InetAddress>): List<String> = addresses.mapNotNull { address ->
    when {
        address is Inet4Address -> address.hostAddress
        address is Inet6Address && !address.isLinkLocalAddress && !address.isLoopbackAddress ->
            address.address.take(8).joinToString("") { "%02x".format(it) } + "/64"
        else -> null
    }
}.distinct().sorted()

/** The interval, or 2/4/8/16 times it after failures, at most 30 seconds unless the interval is longer. */
internal fun po0NextDelayMs(intervalSeconds: Int, failures: Int): Long {
    val interval = intervalSeconds * 1000L
    if (failures <= 0 || interval >= PO0_MAX_BACKOFF_MS) return interval
    return (interval shl minOf(failures, 4)).coerceAtMost(PO0_MAX_BACKOFF_MS)
}

// The API now and then answers a bare 400 "Error" or a 5xx that succeeds a few
// seconds later; a JSON error body (an invalid token) is final.
internal fun isTransientPo0Response(status: Int, body: String): Boolean = when {
    status >= 500 || status == 429 -> true
    status in 200..299 || status == 403 -> false
    else -> parseObject(body) == null
}

internal fun parsePo0Response(token: String, status: Int, body: String, now: Long): Po0Result {
    val data = parseObject(body)
        ?: return Po0Result(
            Po0ResultType.ERROR,
            now,
            message = "HTTP $status: ${snippet(redactPo0Token(body, token))}",
        )
    val currentIp = data.string("currentIp")
    if (status !in 200..299) {
        val message = data.string("message") ?: data.string("msg") ?: data.string("error")
        return Po0Result(
            Po0ResultType.REJECTED,
            now,
            currentIp = currentIp,
            message = redactPo0Token(message ?: "HTTP $status", token),
        )
    }
    val rawWhitelist = data.get("whitelist")?.takeIf { it.isJsonArray }?.asJsonArray
        ?: return Po0Result(
            Po0ResultType.ERROR,
            now,
            currentIp = currentIp,
            message = snippet(redactPo0Token(body, token)),
        )
    val whitelist = rawWhitelist.mapNotNull { item ->
        when {
            item.isJsonObject -> item.asJsonObject.string("ip")
            item.isJsonPrimitive -> item.asString
            else -> null
        }
    }
    val type = when {
        data.boolean("enabled") == false -> Po0ResultType.DISABLED
        whitelist.any { samePo0C24(it, currentIp) } -> Po0ResultType.APPLIED
        else -> Po0ResultType.NOT_APPLIED
    }
    return Po0Result(
        type,
        now,
        currentIp = currentIp,
        whitelist = whitelist,
        limit = data.number("limit")?.toInt(),
    )
}

private fun snippet(text: String): String {
    val trimmed = text.trim()
    return if (trimmed.length > 80) trimmed.substring(0, 80) + "…" else trimmed
}

private fun parseObject(text: String): JsonObject? = runCatching {
    JsonParser.parseString(text).takeIf { it.isJsonObject }?.asJsonObject
}.getOrNull()

private fun JsonObject.primitive(name: String) =
    get(name)?.takeIf { it.isJsonPrimitive }?.asJsonPrimitive

private fun JsonObject.string(name: String): String? = primitive(name)?.asString

private fun JsonObject.boolean(name: String): Boolean? =
    primitive(name)?.takeIf { it.isBoolean }?.asBoolean

private fun JsonObject.number(name: String): Number? =
    primitive(name)?.takeIf { it.isNumber }?.asNumber

private fun JsonObject.array(name: String): List<JsonElement> =
    get(name)?.takeIf { it.isJsonArray }?.asJsonArray?.toList().orEmpty()
