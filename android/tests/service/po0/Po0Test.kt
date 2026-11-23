package com.follow.clash.service.po0

import java.io.ByteArrayInputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private const val TOKEN = "pgnfw_abcdef0123456789"

private fun response(text: String) = readHttpResponse(ByteArrayInputStream(text.toByteArray()))

class Po0HttpTest {
    @Test
    fun `reads a body by its length and keeps the connection`() {
        val stream = ByteArrayInputStream(
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n{\"a\"HTTP/1.1 204 No Content\r\n\r\n".toByteArray(),
        )
        val first = readHttpResponse(stream)
        assertEquals(200, first.status)
        assertEquals("{\"a\"", first.body)
        assertTrue(first.keepAlive)
        val second = readHttpResponse(stream)
        assertEquals(204, second.status)
        assertEquals("", second.body)
    }

    @Test
    fun `reads a chunked body`() {
        val result = response(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;x=y\r\n{\"ok\r\n3\r\n\":1\r\n1\r\n}\r\n0\r\n\r\n",
        )
        assertEquals("{\"ok\":1}", result.body)
        assertTrue(result.keepAlive)
    }

    @Test
    fun `reads to the end without a length and drops the connection`() {
        val result = response("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nError")
        assertEquals(400, result.status)
        assertEquals("Error", result.body)
        assertFalse(result.keepAlive)
    }

    @Test
    fun `skips an interim response`() {
        val result = response("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok")
        assertEquals(201, result.status)
        assertEquals("ok", result.body)
    }

    @Test
    fun `fails on a closed or cut connection`() {
        assertThrows(EOFException::class.java) { response("") }
        assertThrows(EOFException::class.java) { response("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc") }
    }

    @Test
    fun `a negative length is a broken response`() {
        assertThrows(IOException::class.java) { response("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n") }
        assertThrows(IOException::class.java) {
            response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n")
        }
    }
}

class Po0ResponseTest {
    private val now = 1_700_000_000_000L

    @Test
    fun `a listed exit is applied`() {
        val result = parsePo0Response(
            TOKEN,
            200,
            """{"currentIp":"1.2.3.4","whitelist":[{"ip":"1.2.3.0/24","slot":1},"5.6.7.8"],"limit":3,"enabled":true}""",
            now,
        )
        assertEquals(Po0ResultType.APPLIED, result.type)
        assertEquals("1.2.3.4", result.currentIp)
        assertEquals(listOf("1.2.3.0/24", "5.6.7.8"), result.whitelist)
        assertEquals(3, result.limit)
    }

    @Test
    fun `an unlisted exit is not applied, and a disabled firewall says so`() {
        val body = """{"currentIp":"9.9.9.9","whitelist":["1.2.3.0/24"]}"""
        assertEquals(Po0ResultType.NOT_APPLIED, parsePo0Response(TOKEN, 200, body, now).type)
        val disabled = """{"currentIp":"9.9.9.9","whitelist":[],"enabled":false}"""
        assertEquals(Po0ResultType.DISABLED, parsePo0Response(TOKEN, 200, disabled, now).type)
    }

    @Test
    fun `a JSON error is a rejection, with the token masked`() {
        val result = parsePo0Response(TOKEN, 403, """{"message":"bad token $TOKEN"}""", now)
        assertEquals(Po0ResultType.REJECTED, result.type)
        assertEquals("bad token pgnfw_abcdef…", result.message)
    }

    @Test
    fun `a body that is not JSON is an error`() {
        val result = parsePo0Response(TOKEN, 200, "<html>", now)
        assertEquals(Po0ResultType.ERROR, result.type)
        assertEquals("HTTP 200: <html>", result.message)
        assertEquals(Po0ResultType.ERROR, parsePo0Response(TOKEN, 200, """{"currentIp":"1.2.3.4"}""", now).type)
    }

    @Test
    fun `only bare errors and server failures are retried`() {
        assertTrue(isTransientPo0Response(502, "{}"))
        assertTrue(isTransientPo0Response(429, "{}"))
        assertTrue(isTransientPo0Response(400, "Error"))
        assertFalse(isTransientPo0Response(400, """{"error":"invalid"}"""))
        assertFalse(isTransientPo0Response(403, "Forbidden"))
        assertFalse(isTransientPo0Response(200, "<html>"))
    }
}

class Po0RulesTest {
    @Test
    fun `backs off from the interval up to 30 seconds`() {
        assertEquals(5_000L, po0NextDelayMs(5, 0))
        assertEquals(10_000L, po0NextDelayMs(5, 1))
        assertEquals(20_000L, po0NextDelayMs(5, 2))
        assertEquals(30_000L, po0NextDelayMs(5, 3))
        assertEquals(16_000L, po0NextDelayMs(1, 9))
        assertEquals(60_000L, po0NextDelayMs(60, 3))
    }

    @Test
    fun `slows down from the third steady round up to a minute`() {
        assertEquals(5_000L, po0RelaxedDelayMs(5, 2))
        assertEquals(10_000L, po0RelaxedDelayMs(5, 3))
        assertEquals(60_000L, po0RelaxedDelayMs(5, 50))
        assertEquals(60_000L, po0RelaxedDelayMs(1, 50))
        assertEquals(120_000L, po0RelaxedDelayMs(120, 50))
        assertFalse(Po0Settings.fromJson("""{"adaptive":false}""").adaptive)
        assertTrue(Po0Settings.fromJson("{}").adaptive)
    }

    @Test
    fun `compares whole slash 24s`() {
        assertTrue(samePo0C24("1.2.3.0/24", "1.2.3.99"))
        assertFalse(samePo0C24("1.2.4.0/24", "1.2.3.99"))
        assertFalse(samePo0C24(null, "1.2.3.99"))
        assertEquals("1.2.3.0/24", po0C24Of("1.2.3.4"))
    }

    @Test
    fun `network keys keep IPv4 addresses and IPv6 slash 64s`() {
        val addresses = listOf("10.0.0.2", "2001:db8:1:2::abcd", "2001:db8:1:2::1234", "fe80::1")
        assertEquals(
            listOf("10.0.0.2", "20010db800010002/64"),
            po0AddressKeys(addresses.map(InetAddress::getByName)),
        )
    }

    @Test
    fun `settings keep valid unique tokens and a clamped interval`() {
        val settings = Po0Settings.fromJson(
            """{"interval":0,"tokens":[{"token":"$TOKEN","name":"a","enabled":false},{"token":"$TOKEN"},{"token":"bad"}],"port":1}""",
        )
        assertTrue(settings.enabled)
        assertEquals(PO0_MIN_INTERVAL, settings.interval)
        assertEquals(listOf(Po0Token(TOKEN, "a", enabled = false)), settings.tokens)
        assertTrue(settings.activeTokens.isEmpty())
        assertEquals(settings, Po0Settings.fromJson(settings.toJson()))
        assertEquals(Po0Settings(), Po0Settings.fromJson("not json"))
        assertNull(Po0Settings.fromJson(null).tokens.firstOrNull())
    }

    @Test
    fun `status JSON carries what the page reads`() {
        val status = Po0Status(
            results = mapOf(TOKEN to Po0Result(Po0ResultType.NOT_APPLIED, 1L, "1.2.3.4", listOf("5.6.7.0/24"), 2)),
            lastRound = 2L,
        )
        val json = com.google.gson.JsonParser.parseString(status.toJson()).asJsonObject
        assertEquals("status", json["type"].asString)
        assertEquals(2L, json["lastRound"].asLong)
        val result = json["results"].asJsonObject[TOKEN].asJsonObject
        assertEquals("notApplied", result["type"].asString)
        assertEquals("5.6.7.0/24", result["whitelist"].asJsonArray[0].asString)
        assertEquals(2, result["limit"].asInt)
    }
}
