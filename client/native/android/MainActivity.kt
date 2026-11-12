package com.teledriveplayer.tele_drive_player

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bridge: TeleDriveNativeBridge? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = TeleDriveNativeBridge(this) { event ->
            runOnUiThread { eventSink?.success(event) }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    bridge?.handle("getAuthState", null, object : MethodChannel.Result {
                        override fun success(result: Any?) { eventSink?.success(result) }
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                        override fun notImplemented() {}
                    })
                }
                override fun onCancel(arguments: Any?) { eventSink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                @Suppress("UNCHECKED_CAST")
                bridge?.handle(call.method, call.arguments as? Map<*, *>, result)
                    ?: result.error("NOT_READY", "TeleDrive bridge is not initialized.", null)
            }
    }

    override fun onDestroy() {
        bridge?.close()
        bridge = null
        super.onDestroy()
    }

    companion object {
        private const val METHOD_CHANNEL = "com.teledriveplayer/teledrive"
        private const val EVENT_CHANNEL = "com.teledriveplayer/teledrive/events"
    }
}
