package com.teledriveplayer.tele_drive_player

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Locale
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Direct Android bridge for the unencrypted TeleDrive file format.
 *
 * Uses TDLib directly; no TeleDrive backend, Docker service, or public streaming endpoint.
 * The upstream TeleDrive project is Apache-2.0; its manifest and streaming contracts are
 * read-compatible here. Encrypted (tde1:) manifests are surfaced as locked, not decrypted.
 */
class TeleDriveNativeBridge(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val streamExecutor = Executors.newCachedThreadPool()
    private val fileIds = ConcurrentHashMap<String, Int>()
    private val fileLocks = ConcurrentHashMap<String, Any>()
    private val streamItems = ConcurrentHashMap<String, StreamItem>()
    @Volatile private var tdClient: Client? = null
    @Volatile private var authState = "notConfigured"
    @Volatile private var authDetail = ""
    @Volatile private var apiId = 0
    @Volatile private var apiHash = ""
    @Volatile private var parametersSent = false
    @Volatile private var server: ServerSocket? = null

    private data class Part(
        val remoteId: String,
        val index: Int,
        val offset: Long,
        val size: Long
    )
    private data class StreamItem(
        val title: String,
        val mimeType: String,
        val totalSize: Long,
        val parts: List<Part>
    )

    init {
        runCatching { readCredentials() }.getOrNull()?.let { pair ->
            apiId = pair.first
            apiHash = pair.second
            startClient()
        }
    }

    fun handle(method: String, args: Map<*, *>?, reply: MethodChannel.Result) {
        executor.execute {
            try {
                val result: Any? = when (method) {
                    "configure" -> {
                        val id = (args?.get("apiId") as? Number)?.toInt()
                            ?: throw IllegalArgumentException("Telegram API ID is required.")
                        val hash = args["apiHash"]?.toString()?.trim().orEmpty()
                        require(id > 0 && hash.length >= 16) { "Enter a valid Telegram API ID and API hash." }
                        apiId = id
                        apiHash = hash
                        saveCredentials(id, hash)
                        if (tdClient == null) startClient()
                        authSnapshot()
                    }
                    "getAuthState" -> authSnapshot()
                    "submitPhoneNumber" -> {
                        send(TdApi.SetAuthenticationPhoneNumber(
                            args?.get("phoneNumber")?.toString().orEmpty(),
                            TdApi.PhoneNumberAuthenticationSettings()
                        ))
                        mapOf("ok" to true)
                    }
                    "submitCode" -> {
                        send(TdApi.CheckAuthenticationCode(args?.get("code")?.toString().orEmpty()))
                        mapOf("ok" to true)
                    }
                    "submitPassword" -> {
                        send(TdApi.CheckAuthenticationPassword(args?.get("password")?.toString().orEmpty()))
                        mapOf("ok" to true)
                    }
                    "submitEmail" -> {
                        send(TdApi.SetAuthenticationEmailAddress(args?.get("email")?.toString().orEmpty()))
                        mapOf("ok" to true)
                    }
                    "submitEmailCode" -> {
                        send(TdApi.CheckAuthenticationEmailCode(
                            TdApi.EmailAddressAuthenticationCode(args?.get("code")?.toString().orEmpty())
                        ))
                        mapOf("ok" to true)
                    }
                    "getDrives" -> listDrives()
                    "getFiles" -> {
                        val chatId = (args?.get("chatId") as? Number)?.toLong()
                            ?: throw IllegalArgumentException("Select a TeleDrive storage channel first.")
                        listFiles(chatId)
                    }
                    "getStreamUrl" -> {
                        val id = args?.get("id")?.toString().orEmpty()
                        val item = streamItems[id] ?: throw IllegalArgumentException("File entry expired. Refresh the TeleDrive list.")
                        if (item.parts.isEmpty()) throw IllegalArgumentException("This item is locked or has no playable parts.")
                        createStreamUrl(id)
                    }
                    "logout" -> {
                        runCatching { send(TdApi.LogOut()) }
                        mapOf("ok" to true)
                    }
                    else -> throw IllegalArgumentException("Unsupported TeleDrive operation: $method")
                }
                mainPost { reply.success(result) }
            } catch (error: Throwable) {
                val message = error.cause?.message ?: error.message ?: "TeleDrive operation failed."
                mainPost { reply.error("TELEDRIVE_ERROR", message, null) }
            }
        }
    }

    private fun mainPost(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    private fun authSnapshot() = mapOf("state" to authState, "detail" to authDetail)

    private fun startClient() {
        if (tdClient != null || apiId <= 0 || apiHash.isBlank()) return
        setState("initializing")
        runCatching { Client.execute(TdApi.SetLogVerbosityLevel(1)) }
        parametersSent = false
        tdClient = Client.create(
            { update -> handleUpdate(update) },
            { error -> publishError("TDLib update error: ${error.message}") },
            { error -> publishError("TDLib error: ${error.message}") }
        )
    }

    private fun handleUpdate(update: TdApi.Object) {
        if (update is TdApi.UpdateAuthorizationState) {
            when (val auth = update.authorizationState) {
                is TdApi.AuthorizationStateWaitTdlibParameters -> sendParameters()
                is TdApi.AuthorizationStateWaitEncryptionKey ->
                    tdClient?.send(TdApi.CheckDatabaseEncryptionKey(databaseKey())) { }
                is TdApi.AuthorizationStateWaitPhoneNumber -> setState("waitingForPhoneNumber")
                is TdApi.AuthorizationStateWaitCode ->
                    setState("waitingForCode", "Telegram sent a code to ${auth.codeInfo.phoneNumber}")
                is TdApi.AuthorizationStateWaitPassword ->
                    setState("waitingForPassword", auth.passwordHint.orEmpty())
                is TdApi.AuthorizationStateWaitEmailAddress -> setState("waitingForEmail")
                is TdApi.AuthorizationStateWaitEmailCode ->
                    setState("waitingForEmailCode", auth.codeInfo.emailAddressPattern)
                is TdApi.AuthorizationStateWaitOtherDeviceConfirmation ->
                    setState("waitingForQr", auth.link)
                is TdApi.AuthorizationStateWaitRegistration ->
                    setState("registrationRequired", "Create the Telegram account in an official Telegram app first.")
                is TdApi.AuthorizationStateReady -> setState("ready")
                is TdApi.AuthorizationStateLoggingOut -> setState("loggingOut")
                is TdApi.AuthorizationStateClosing -> setState("initializing")
                is TdApi.AuthorizationStateClosed -> setState("closed")
                else -> setState("initializing", auth.javaClass.simpleName)
            }
        }
    }

    private fun sendParameters() {
        if (parametersSent) return
        val active = tdClient ?: return
        parametersSent = true
        val base = File(context.filesDir, "teledrive-tdlib")
        val params = TdApi.SetTdlibParameters().apply {
            useTestDc = false
            databaseDirectory = File(base, "db").absolutePath
            filesDirectory = File(base, "files").absolutePath
            databaseEncryptionKey = databaseKey()
            useFileDatabase = true
            useChatInfoDatabase = true
            useMessageDatabase = true
            useSecretChats = false
            apiId = this@TeleDriveNativeBridge.apiId
            apiHash = this@TeleDriveNativeBridge.apiHash
            systemLanguageCode = Locale.getDefault().toLanguageTag()
            deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}"
            systemVersion = "Android ${Build.VERSION.RELEASE}"
            applicationVersion = "TeleDrive Player"
        }
        active.send(params) { result ->
            if (result is TdApi.Error) {
                parametersSent = false
                publishError("Telegram setup failed (${result.code}): ${result.message}")
            }
        }
    }

    private fun setState(next: String, detail: String = "") {
        authState = next
        authDetail = detail
        emit(authSnapshot())
    }

    private fun publishError(message: String) {
        authDetail = message
        emit(authSnapshot())
    }

    private fun <T : TdApi.Object> send(function: TdApi.Function<T>): T {
        val active = tdClient ?: throw IllegalStateException("Telegram session is not initialized.")
        val future = CompletableFuture<T>()
        active.send(function) { response ->
            if (response is TdApi.Error) {
                future.completeExceptionally(IllegalStateException("Telegram ${response.code}: ${response.message}"))
            } else {
                @Suppress("UNCHECKED_CAST")
                future.complete(response as T)
            }
        }
        return future.get(45, TimeUnit.SECONDS)
    }

    private fun requireReady() {
        check(authState == "ready") { "Complete Telegram sign-in first. Current state: $authState" }
    }

    private fun listDrives(): List<Map<String, Any?>> {
        requireReady()
        val ids = LinkedHashSet<Long>()
        runCatching { send(TdApi.SearchChatsOnServer("TeleDrive", 50)).chatIds.forEach(ids::add) }
        for (list in listOf(TdApi.ChatListMain(), TdApi.ChatListArchive())) {
            runCatching { send(TdApi.LoadChats(list, 100)) }
            runCatching { send(TdApi.GetChats(list, 1000)).chatIds.forEach(ids::add) }
        }
        return ids.mapNotNull { chatId ->
            runCatching {
                val chat = send(TdApi.GetChat(chatId))
                val type = chat.type as? TdApi.ChatTypeSupergroup ?: return@runCatching null
                if (!type.isChannel || !(chat.title == "TeleDrive" || chat.title.startsWith("TeleDrive "))) return@runCatching null
                val group = send(TdApi.GetSupergroup(type.supergroupId))
                if (group.status !is TdApi.ChatMemberStatusCreator ||
                    !group.usernames?.activeUsernames.isNullOrEmpty().not()
                ) return@runCatching null
                mapOf("chatId" to chatId, "title" to chat.title)
            }.getOrNull()
        }.sortedBy { it["title"].toString() }
    }

    private fun listFiles(chatId: Long): List<Map<String, Any?>> {
        requireReady()
        val grouped = LinkedHashMap<String, MutableList<Part>>()
        val metadata = HashMap<String, JSONObject>()
        val lockedRows = ArrayList<Map<String, Any?>>()
        var fromMessageId = 0L
        var pages = 0
        while (pages++ < 1000) {
            val page = send(TdApi.SearchChatMessages(
                chatId, null, "", null, fromMessageId, 0, 100,
                TdApi.SearchMessagesFilterDocument()
            ))
            if (page.messages.isEmpty()) break
            for (message in page.messages) {
                val document = message.content as? TdApi.MessageDocument ?: continue
                val remote = document.document.document.remote?.id?.takeIf { it.isNotBlank() } ?: continue
                val caption = document.caption?.text.orEmpty()
                if (caption.startsWith("tde1:")) {
                    lockedRows += mapOf(
                        "id" to "locked:$chatId:${message.id}",
                        "title" to "Encrypted item (unlock support pending)",
                        "mimeType" to document.document.mimeType,
                        "size" to document.document.document.size,
                        "locked" to true,
                        "parts" to emptyList<Map<String, Any?>>()
                    )
                    continue
                }
                if (!caption.startsWith("td1:")) continue
                val manifest = runCatching { JSONObject(caption.removePrefix("td1:")) }.getOrNull() ?: continue
                val id = manifest.optString("id").takeIf { it.isNotBlank() } ?: continue
                val fileName = manifest.optString("n", document.document.fileName)
                if (fileName == "teledrive.folders.json" || fileName == "teledrive.keybackup") continue
                val total = manifest.optLong("s", document.document.document.size.toLong())
                val partSize = manifest.optLong("ps", document.document.document.size.toLong())
                    .takeIf { it > 0 } ?: document.document.document.size.toLong()
                val part = Part(
                    remoteId = remote,
                    index = manifest.optInt("pi", 0),
                    offset = manifest.optLong("po", 0L),
                    size = partSize
                )
                grouped.getOrPut(id) { mutableListOf() }.add(part)
                metadata[id] = JSONObject().put("title", fileName)
                    .put("mimeType", manifest.optString("m", document.document.mimeType))
                    .put("size", total)
            }
            val oldest = page.messages.last().id
            if (oldest <= 0 || oldest == fromMessageId) break
            fromMessageId = oldest
            if (page.messages.size < 100) break
        }
        val results = grouped.mapNotNull { (id, unsorted) ->
            val parts = unsorted.distinctBy { it.index }.sortedBy { it.index }
            if (parts.isEmpty()) return@mapNotNull null
            val meta = metadata[id] ?: return@mapNotNull null
            val title = meta.optString("title")
            val mime = meta.optString("mimeType", "application/octet-stream")
            val total = meta.optLong("size", parts.sumOf { it.size })
            streamItems[id] = StreamItem(title, mime, total, parts)
            mapOf(
                "id" to id, "title" to title, "mimeType" to mime,
                "size" to total, "locked" to false,
                "parts" to parts.map { mapOf(
                    "remoteFileId" to it.remoteId, "partIndex" to it.index,
                    "offset" to it.offset, "size" to it.size
                ) }
            )
        }
        return (results + lockedRows).sortedBy { it["title"].toString().lowercase(Locale.ROOT) }
    }

    private fun createStreamUrl(id: String): String {
        val active = server ?: ServerSocket(0, 32, InetAddress.getByName("127.0.0.1")).also { socket ->
            server = socket
            streamExecutor.execute {
                while (!socket.isClosed) {
                    try {
                        val client = socket.accept()
                        streamExecutor.execute { handleStreamRequest(client) }
                    } catch (_: Exception) {
                        if (!socket.isClosed) publishError("Local stream listener stopped unexpectedly.")
                    }
                }
            }
        }
        return "http://127.0.0.1:${active.localPort}/stream/$id"
    }

    private fun handleStreamRequest(socket: Socket) {
        socket.use { client ->
            try {
                client.soTimeout = 15000
                val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII))
                val requestLine = reader.readLine() ?: return
                val request = requestLine.split(" ")
                if (request.size < 2 || (request[0] != "GET" && request[0] != "HEAD")) {
                    writeResponse(client, 405, "Method Not Allowed", "Content-Length: 0\r\n")
                    return
                }
                var rangeHeader: String? = null
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val split = line.indexOf(':')
                    if (split > 0 && line.substring(0, split).equals("Range", true)) {
                        rangeHeader = line.substring(split + 1).trim()
                    }
                }
                val id = URLDecoder.decode(request[1].substringAfterLast('/'), "UTF-8")
                val item = streamItems[id] ?: run {
                    writeResponse(client, 404, "Not Found", "Content-Length: 0\r\n")
                    return
                }
                val range = parseRange(rangeHeader, item.totalSize)
                if (range == null && rangeHeader != null) {
                    writeResponse(client, 416, "Range Not Satisfiable", "Content-Range: bytes */${item.totalSize}\r\nContent-Length: 0\r\n")
                    return
                }
                val start = range?.first ?: 0L
                val end = range?.second ?: (item.totalSize - 1L)
                val length = if (item.totalSize == 0L) 0L else end - start + 1L
                val status = if (range != null) 206 else 200
                val headers = buildString {
                    append("Content-Type: ${item.mimeType}\r\n")
                    append("Accept-Ranges: bytes\r\n")
                    append("Content-Length: $length\r\n")
                    if (range != null) append("Content-Range: bytes $start-$end/${item.totalSize}\r\n")
                }
                writeResponse(client, status, if (status == 206) "Partial Content" else "OK", headers, close = false)
                if (request[0] == "HEAD" || length == 0L) return
                val output = client.getOutputStream()
                var position = start
                val bufferSize = 256 * 1024
                while (position <= end) {
                    val count = minOf(bufferSize.toLong(), end - position + 1L).toInt()
                    val bytes = readPlainRange(item, position, count)
                    if (bytes.isEmpty()) throw IllegalStateException("Telegram returned no bytes at offset $position.")
                    output.write(bytes)
                    position += bytes.size
                    output.flush()
                }
            } catch (error: Throwable) {
                publishError("Stream error: ${error.message ?: error.javaClass.simpleName}")
            }
        }
    }

    private fun writeResponse(socket: Socket, code: Int, reason: String, headers: String, close: Boolean = true) {
        val output = socket.getOutputStream()
        output.write("HTTP/1.1 $code $reason\r\n$headers${if (close) "Connection: close\r\n" else ""}\r\n".toByteArray(StandardCharsets.US_ASCII))
        output.flush()
    }

    private fun parseRange(value: String?, size: Long): Pair<Long, Long>? {
        if (value == null) return null
        if (!value.startsWith("bytes=") || size <= 0) return null
        val spec = value.removePrefix("bytes=").substringBefore(',').trim()
        val dash = spec.indexOf('-')
        if (dash < 0) return null
        val left = spec.substring(0, dash)
        val right = spec.substring(dash + 1)
        val start: Long
        val end: Long
        if (left.isEmpty()) {
            val suffix = right.toLongOrNull()?.takeIf { it > 0 } ?: return null
            start = (size - suffix).coerceAtLeast(0)
            end = size - 1
        } else {
            start = left.toLongOrNull() ?: return null
            end = (right.toLongOrNull() ?: (size - 1)).coerceAtMost(size - 1)
        }
        if (start < 0 || start >= size || end < start) return null
        return start to end
    }

    private fun readPlainRange(item: StreamItem, position: Long, count: Int): ByteArray {
        val part = item.parts.firstOrNull { position >= it.offset && position < it.offset + it.size }
            ?: throw IllegalStateException("No TeleDrive part covers file offset $position.")
        val within = position - part.offset
        val toRead = minOf(count.toLong(), part.size - within).toInt()
        val lock = fileLocks.computeIfAbsent(part.remoteId) { Any() }
        synchronized(lock) {
            val fileId = fileIds[part.remoteId] ?: send(
                TdApi.GetRemoteFile(part.remoteId, TdApi.FileTypeDocument())
            ).id.also { fileIds[part.remoteId] = it }
            val initial = send(TdApi.GetFile(fileId))
            if (initial.local?.isDownloadingCompleted != true &&
                !covers(initial, within, toRead.toLong())
            ) {
                send(TdApi.DownloadFile(fileId, 32, within, 0, false))
                val deadline = SystemClock.elapsedRealtime() + 45000L
                var ready = false
                while (SystemClock.elapsedRealtime() < deadline) {
                    val current = send(TdApi.GetFile(fileId))
                    if (covers(current, within, toRead.toLong())) {
                        ready = true
                        break
                    }
                    if (current.local?.isDownloadingActive != true) {
                        send(TdApi.DownloadFile(fileId, 32, within, 0, false))
                    }
                    Thread.sleep(150)
                }
                check(ready) { "Telegram stream buffer timed out at offset $within." }
            }
            val data = send(TdApi.ReadFilePart(fileId, within, toRead.toLong())).data
            if (data.isEmpty()) throw IllegalStateException("TDLib could not read the requested byte range.")
            return data
        }
    }

    private fun covers(file: TdApi.File, offset: Long, count: Long): Boolean {
        val local = file.local ?: return false
        if (local.isDownloadingCompleted) return true
        val start = local.downloadOffset
        val end = start + local.downloadedPrefixSize
        return offset >= start && offset + count <= end
    }

    private fun saveCredentials(id: Int, hash: String) {
        val payload = "$id\n$hash".toByteArray(Charsets.UTF_8)
        saveEncryptedPreference(CREDENTIALS, payload)
    }

    private fun readCredentials(): Pair<Int, String>? {
        val bytes = readEncryptedPreference(CREDENTIALS) ?: return null
        val rows = String(bytes, Charsets.UTF_8).split('\n', limit = 2)
        if (rows.size != 2) return null
        val id = rows[0].toIntOrNull() ?: return null
        return id to rows[1]
    }

    private fun databaseKey(): ByteArray {
        val stored = readEncryptedPreference(DATABASE_KEY)
        if (stored != null && stored.isNotEmpty()) return stored
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        saveEncryptedPreference(DATABASE_KEY, key)
        return key
    }

    private fun saveEncryptedPreference(name: String, value: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.iv + cipher.doFinal(value)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(name, Base64.encodeToString(encrypted, Base64.NO_WRAP)).apply()
    }

    private fun readEncryptedPreference(name: String): ByteArray? {
        val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(name, null) ?: return null
        val blob = Base64.decode(encoded, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
        return cipher.doFinal(blob.copyOfRange(12, blob.size))
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "teledrive.player.telegram.credentials"
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(
            alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }

    fun close() {
        runCatching { server?.close() }
        server = null
        streamExecutor.shutdownNow()
        runCatching { tdClient?.send(TdApi.Close()) { } }
        tdClient = null
        executor.shutdown()
    }

    companion object {
        private const val PREFS = "teledrive_native"
        private const val CREDENTIALS = "telegram_credentials"
        private const val DATABASE_KEY = "tdlib_database_key"
    }
}
