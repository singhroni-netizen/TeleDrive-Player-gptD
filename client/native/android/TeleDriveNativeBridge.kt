package com.teledriveplayer.tele_drive_player

import android.content.Context
import android.os.Build
import android.util.Base64
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.Locale
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Direct, on-device TeleDrive reader.
 *
 * It uses the same TDLib-backed Telegram protocol and TeleDrive caption manifest
 * format as Mahmud0808/TeleDrive. No HTTP backend or Docker service is required.
 * Content encryption (tde1 manifests) is deliberately reported as locked until
 * the matching TeleDrive key-recovery flow is integrated.
 */
class TeleDriveNativeBridge(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var tdClient: Client? = null
    @Volatile private var state = "notConfigured"
    @Volatile private var stateDetail = ""
    @Volatile private var apiId = 0
    @Volatile private var apiHash = ""
    @Volatile private var parametersSent = false

    init {
        runCatching { readCredentials() }.getOrNull()?.let { pair ->
            apiId = pair.first
            apiHash = pair.second
            startClient()
        }
    }

    fun handle(method: String, args: Map<*, *>?, reply: io.flutter.plugin.common.MethodChannel.Result) {
        executor.execute {
            try {
                val value: Any? = when (method) {
                    "configure" -> {
                        val id = (args?.get("apiId") as? Number)?.toInt()
                            ?: throw IllegalArgumentException("Telegram API ID is required")
                        val hash = args?.get("apiHash")?.toString()?.trim().orEmpty()
                        require(id > 0 && hash.length >= 16) { "Enter a valid Telegram API ID and API hash." }
                        apiId = id
                        apiHash = hash
                        saveCredentials(id, hash)
                        if (tdClient == null) startClient()
                        mapOf("state" to state, "detail" to stateDetail)
                    }
                    "getAuthState" -> mapOf("state" to state, "detail" to stateDetail)
                    "submitPhoneNumber" -> {
                        send(TdApi.SetAuthenticationPhoneNumber(args?.get("phoneNumber")?.toString().orEmpty(), TdApi.PhoneNumberAuthenticationSettings()))
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
                    "getDrives" -> listDrives()
                    "getFiles" -> {
                        val chatId = (args?.get("chatId") as? Number)?.toLong()
                            ?: throw IllegalArgumentException("Select a TeleDrive storage channel first.")
                        listFiles(chatId)
                    }
                    "logout" -> {
                        runCatching { send(TdApi.LogOut()) }
                        mapOf("ok" to true)
                    }
                    else -> throw IllegalArgumentException("Unsupported TeleDrive operation: $method")
                }
                main.post { reply.success(value) }
            } catch (error: Throwable) {
                val message = error.cause?.message ?: error.message ?: "TeleDrive operation failed"
                main.post { reply.error("TELEDRIVE_ERROR", message, null) }
            }
        }
    }

    private fun startClient() {
        if (tdClient != null || apiId <= 0 || apiHash.isBlank()) return
        state = "initializing"
        publishState()
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
                    tdClient?.send(TdApi.CheckDatabaseEncryptionKey(ByteArray(0))) { }
                is TdApi.AuthorizationStateWaitPhoneNumber -> setState("waitingForPhoneNumber")
                is TdApi.AuthorizationStateWaitCode -> setState("waitingForCode", "Code sent to ${auth.codeInfo.phoneNumber}")
                is TdApi.AuthorizationStateWaitPassword -> setState("waitingForPassword", auth.passwordHint.orEmpty())
                is TdApi.AuthorizationStateWaitEmailAddress -> setState("waitingForEmail")
                is TdApi.AuthorizationStateWaitEmailCode -> setState("waitingForEmailCode", auth.codeInfo.emailAddressPattern)
                is TdApi.AuthorizationStateWaitOtherDeviceConfirmation -> setState("waitingForQr", auth.link)
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
            databaseEncryptionKey = ByteArray(0)
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
        state = next
        stateDetail = detail
        publishState()
    }

    private fun publishState() = emit(mapOf("state" to state, "detail" to stateDetail))
    private fun publishError(message: String) {
        stateDetail = message
        emit(mapOf("state" to state, "detail" to message))
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
        if (state != "ready") throw IllegalStateException("Telegram is not signed in yet. Current state: $state")
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
                if (group.status !is TdApi.ChatMemberStatusCreator || !group.usernames?.activeUsernames.isNullOrEmpty().not()) return@runCatching null
                mapOf("chatId" to chatId, "title" to chat.title)
            }.getOrNull()
        }.sortedBy { it["title"].toString() }
    }

    private data class Part(
        val remoteId: String,
        val index: Int,
        val offset: Long,
        val size: Long,
        val fileName: String,
        val mimeType: String
    )

    private fun listFiles(chatId: Long): List<Map<String, Any?>> {
        requireReady()
        val grouped = LinkedHashMap<String, MutableList<Part>>()
        var fromMessageId = 0L
        var pageCount = 0
        while (pageCount++ < 1000) {
            val page = send(TdApi.SearchChatMessages(
                chatId, null, "", null, fromMessageId, 0, 100,
                TdApi.SearchMessagesFilterDocument()
            ))
            if (page.messages.isEmpty()) break
            for (message in page.messages) {
                val document = message.content as? TdApi.MessageDocument ?: continue
                val remoteId = document.document.document.remote?.id?.takeIf { it.isNotBlank() } ?: continue
                val caption = document.caption?.text.orEmpty()
                if (caption.startsWith("tde1:")) {
                    val key = "locked:$chatId:${message.id}"
                    grouped[key] = mutableListOf(Part(remoteId, 0, 0, document.document.document.size.toLong(),
                        "Encrypted TeleDrive item", document.document.mimeType))
                    continue
                }
                if (!caption.startsWith("td1:")) continue
                val manifest = runCatching { JSONObject(caption.removePrefix("td1:")) }.getOrNull() ?: continue
                val fileKey = manifest.optString("id").takeIf { it.isNotBlank() } ?: continue
                if (manifest.optLong("tr", 0L) > 0L) continue
                val name = manifest.optString("n", document.document.fileName)
                val mime = manifest.optString("m", document.document.mimeType)
                val partCount = manifest.optInt("pc", 0).coerceAtLeast(1)
                val partIndex = manifest.optInt("pi", 0)
                val partOffset = manifest.optLong("po", 0L)
                val partSize = manifest.optLong("ps", document.document.document.size.toLong())
                grouped.getOrPut(fileKey) { mutableListOf() }.add(
                    Part(remoteId, partIndex, partOffset, partSize, name, mime)
                )
            }
            val oldest = page.messages.last().id
            if (oldest <= 0 || oldest == fromMessageId) break
            fromMessageId = oldest
            if (page.messages.size < 100) break
        }
        return grouped.mapNotNull { (id, rawParts) ->
            if (id.startsWith("locked:")) {
                val part = rawParts.first()
                return@mapNotNull mapOf(
                    "id" to id, "title" to part.fileName, "mimeType" to part.mimeType,
                    "size" to part.size, "locked" to true, "parts" to emptyList<Map<String, Any?>>()
                )
            }
            val parts = rawParts.distinctBy { it.index }.sortedBy { it.index }
            val first = parts.firstOrNull() ?: return@mapNotNull null
            val totalSize = parts.maxOfOrNull { it.offset + it.size } ?: first.size
            mapOf(
                "id" to id, "title" to first.fileName, "mimeType" to first.mimeType,
                "size" to totalSize, "locked" to false,
                "parts" to parts.map { mapOf(
                    "remoteFileId" to it.remoteId, "partIndex" to it.index,
                    "offset" to it.offset, "size" to it.size
                ) }
            )
        }.sortedBy { it["title"].toString().lowercase(Locale.ROOT) }
    }

    private fun saveCredentials(id: Int, hash: String) {
        val payload = "$id\n$hash".toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(payload)
        val blob = cipher.iv + encrypted
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(CREDENTIALS, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    private fun readCredentials(): Pair<Int, String>? {
        val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(CREDENTIALS, null) ?: return null
        val blob = Base64.decode(encoded, Base64.NO_WRAP)
        val iv = blob.copyOfRange(0, 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        val rows = String(cipher.doFinal(blob.copyOfRange(12, blob.size)), Charsets.UTF_8).split('\n', limit = 2)
        if (rows.size != 2) return null
        return rows[0].toIntOrNull()?.let { it to rows[1] }
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
        runCatching { tdClient?.send(TdApi.Close()) { } }
        tdClient = null
        executor.shutdown()
    }

    companion object {
        private const val PREFS = "teledrive_native"
        private const val CREDENTIALS = "telegram_credentials"
    }
}
