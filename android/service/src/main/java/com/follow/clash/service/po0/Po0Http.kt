package com.follow.clash.service.po0

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URLEncoder
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.delay

/** Nothing would leave on the physical network, so nothing is sent: any other route could whitelist a proxy node. */
internal class Po0RouteUnavailable(message: String) : IOException(message)

internal class HttpResponse(val status: Int, val body: String, val keepAlive: Boolean)

private const val MAX_BODY_BYTES = 1 shl 20

internal fun readHttpResponse(input: InputStream): HttpResponse {
    while (true) {
        val statusLine = readLine(input) ?: throw EOFException("connection closed before a response")
        val parts = statusLine.split(' ', limit = 3)
        val status = parts.getOrNull(1)?.toIntOrNull()
            ?: throw IOException("malformed status line: ${statusLine.take(40)}")
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = readLine(input) ?: throw EOFException("connection closed in the headers")
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) {
                headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
        }
        if (status in 100..199) continue
        val connection = headers["connection"]?.lowercase()
        val http11 = parts[0] == "HTTP/1.1"
        var keepAlive = if (http11) connection != "close" else connection == "keep-alive"
        val length = headers["content-length"]?.toLongOrNull()
        val body = when {
            headers["transfer-encoding"]?.lowercase()?.contains("chunked") == true -> readChunked(input)
            status == 204 || status == 304 -> ByteArray(0)
            length != null -> readExactly(input, length)
            else -> {
                keepAlive = false
                readToEnd(input)
            }
        }
        return HttpResponse(status, body.toString(Charsets.UTF_8), keepAlive)
    }
}

private fun readLine(input: InputStream): String? {
    val bytes = ByteArrayOutputStream()
    while (true) {
        val byte = input.read()
        if (byte == -1) return if (bytes.size() == 0) null else bytes.toString(Charsets.UTF_8.name())
        if (byte == '\n'.code) break
        bytes.write(byte)
        if (bytes.size() > 8192) throw IOException("header line too long")
    }
    return bytes.toString(Charsets.UTF_8.name()).removeSuffix("\r")
}

private fun readExactly(input: InputStream, length: Long): ByteArray {
    if (length > MAX_BODY_BYTES) throw IOException("response too large")
    val buffer = ByteArray(length.toInt())
    var read = 0
    while (read < buffer.size) {
        val count = input.read(buffer, read, buffer.size - read)
        if (count == -1) throw EOFException("connection closed in the body")
        read += count
    }
    return buffer
}

private fun readChunked(input: InputStream): ByteArray {
    val body = ByteArrayOutputStream()
    while (true) {
        val sizeLine = readLine(input) ?: throw EOFException("connection closed in a chunk")
        val size = sizeLine.substringBefore(';').trim().toLongOrNull(16)
            ?: throw IOException("malformed chunk size")
        if (size == 0L) {
            while (readLine(input)?.isNotEmpty() == true) Unit
            return body.toByteArray()
        }
        if (body.size() + size > MAX_BODY_BYTES) throw IOException("response too large")
        body.write(readExactly(input, size))
        readLine(input)
    }
}

private fun readToEnd(input: InputStream): ByteArray {
    val body = ByteArrayOutputStream()
    val buffer = ByteArray(4096)
    while (true) {
        val count = input.read(buffer)
        if (count == -1) return body.toByteArray()
        body.write(buffer, 0, count)
        if (body.size() > MAX_BODY_BYTES) throw IOException("response too large")
    }
}

/**
 * Talks to the po0 API over sockets it opens itself, which [prepare] marks to
 * bypass the VPN before they connect.
 */
internal class Po0Client(private val prepare: (Socket) -> Unit) {
    private class Connection(val socket: SSLSocket) {
        val input = BufferedInputStream(socket.inputStream)
        val output = socket.outputStream
        var lastUsed = System.nanoTime()
    }

    @Volatile
    private var connection: Connection? = null

    suspend fun check(token: String): Po0Result =
        call(token, "GET", pathOf(token), attempts = 1, timeoutMs = CHECK_TIMEOUT_MS)

    /** The server treats a listed /24 as done, so a retry is safe. */
    suspend fun add(token: String): Po0Result =
        call(token, "POST", pathOf(token) + "/add", attempts = 3, timeoutMs = ADD_TIMEOUT_MS)

    /** Safe from any thread: closing the socket also fails a request waiting on it. */
    fun reset() {
        val current = connection ?: return
        connection = null
        runCatching { current.socket.close() }
    }

    private fun pathOf(token: String) = "/api/firewall/" + URLEncoder.encode(token, "UTF-8")

    private suspend fun call(
        token: String,
        method: String,
        path: String,
        attempts: Int,
        timeoutMs: Int,
    ): Po0Result {
        var lastError: String? = null
        for (attempt in 1..attempts) {
            if (attempt > 1) delay(RETRY_DELAY_MS * (attempt - 1))
            try {
                val response = send(method, path, timeoutMs)
                if (isTransientPo0Response(response.status, response.body)) {
                    lastError = "HTTP ${response.status}"
                    continue
                }
                return parsePo0Response(token, response.status, response.body, System.currentTimeMillis())
            } catch (error: Po0RouteUnavailable) {
                throw error
            } catch (_: SocketTimeoutException) {
                lastError = "请求超时"
                reset()
            } catch (error: IOException) {
                lastError = error.message ?: error.javaClass.simpleName
                reset()
            }
        }
        return Po0Result(
            Po0ResultType.ERROR,
            System.currentTimeMillis(),
            message = redactPo0Token(lastError ?: "请求失败", token),
        )
    }

    @Synchronized
    private fun send(method: String, path: String, timeoutMs: Int): HttpResponse {
        val pooled = connection?.takeIf { System.nanoTime() - it.lastUsed < IDLE_TIMEOUT_NS }
        if (pooled == null) reset()
        try {
            return exchange(pooled ?: open(), method, path, timeoutMs)
        } catch (error: IOException) {
            reset()
            // The server may have closed an idle pooled connection.
            if (pooled == null || error is Po0RouteUnavailable || error is SocketTimeoutException) throw error
        }
        return exchange(open(), method, path, timeoutMs)
    }

    private fun open(): Connection {
        val raw = Socket()
        try {
            prepare(raw)
            raw.connect(InetSocketAddress(PO0_API_HOST, 443), CONNECT_TIMEOUT_MS)
            raw.soTimeout = CHECK_TIMEOUT_MS
            val ssl = sslContext.socketFactory.createSocket(raw, PO0_API_HOST, 443, true) as SSLSocket
            ssl.startHandshake()
            if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(PO0_API_HOST, ssl.session)) {
                ssl.close()
                throw SSLPeerUnverifiedException("证书不属于 $PO0_API_HOST")
            }
            return Connection(ssl).also { connection = it }
        } catch (error: Exception) {
            runCatching { raw.close() }
            throw error as? IOException ?: IOException(error.message, error)
        }
    }

    private fun exchange(target: Connection, method: String, path: String, timeoutMs: Int): HttpResponse {
        target.socket.soTimeout = timeoutMs
        val request = buildString {
            append("$method $path HTTP/1.1\r\n")
            append("Host: $PO0_API_HOST\r\n")
            append("User-Agent: FlClash-po0\r\n")
            append("Accept: application/json\r\n")
            append("Content-Type: application/json\r\n")
            if (method == "POST") append("Content-Length: 0\r\n")
            append("\r\n")
        }
        target.output.write(request.toByteArray(Charsets.US_ASCII))
        target.output.flush()
        val response = readHttpResponse(target.input)
        target.lastUsed = System.nanoTime()
        if (!response.keepAlive) reset()
        return response
    }

    companion object {
        private const val CHECK_TIMEOUT_MS = 5_000
        private const val ADD_TIMEOUT_MS = 20_000
        private const val CONNECT_TIMEOUT_MS = 5_000
        private const val RETRY_DELAY_MS = 1_500L
        private const val IDLE_TIMEOUT_NS = 25_000_000_000L

        private val sslContext: SSLContext by lazy {
            SSLContext.getInstance("TLS").apply {
                init(null, arrayOf(Po0TrustManager()), null)
            }
        }
    }
}

/** The system roots, plus ISRG Root X1 for the Android 7 devices that lack it. */
private class Po0TrustManager : X509TrustManager {
    private val system = trustManagerOf(null)
    private val isrg = trustManagerOf(
        KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry(
                "isrg-root-x1",
                CertificateFactory.getInstance("X.509").generateCertificate(ISRG_ROOT_X1.byteInputStream()),
            )
        },
    )

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
        system.checkClientTrusted(chain, authType)

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
        try {
            system.checkServerTrusted(chain, authType)
        } catch (error: java.security.cert.CertificateException) {
            try {
                isrg.checkServerTrusted(chain, authType)
            } catch (_: java.security.cert.CertificateException) {
                throw error
            }
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers + isrg.acceptedIssuers

    private fun trustManagerOf(store: KeyStore?): X509TrustManager =
        TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            .apply { init(store) }
            .trustManagers
            .filterIsInstance<X509TrustManager>()
            .first()
}

private val ISRG_ROOT_X1 = """
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
""".trimIndent()
