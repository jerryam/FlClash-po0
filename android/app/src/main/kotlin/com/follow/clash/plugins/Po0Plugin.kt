package com.follow.clash.plugins

import com.follow.clash.common.Components
import com.follow.clash.service.po0.Po0Firewall
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The po0 page's view of [Po0Firewall], which runs on in the service once the page is gone. */
class Po0Plugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var scope: CoroutineScope? = null
    private var observer: Job? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        methods = MethodChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/po0")
            .also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/po0_events")
            .also { it.setStreamHandler(this) }
        Po0Firewall.attachUi()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Po0Firewall.detachUi()
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
        scope?.cancel()
        scope = null
        observer = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val scope = scope ?: return result.error("detached", null, null)
        scope.launch {
            try {
                val value: Any? = withContext(Dispatchers.IO) {
                    when (call.method) {
                        "getSettings" -> Po0Firewall.settingsJson()
                        "setSettings" -> Po0Firewall.updateSettings(call.arguments as String)
                        "runNow" -> Po0Firewall.runNow()
                        "kick" -> Po0Firewall.kick()
                        else -> NOT_IMPLEMENTED
                    }
                }
                when (value) {
                    NOT_IMPLEMENTED -> result.notImplemented()
                    is String -> result.success(value)
                    else -> result.success(null)
                }
            } catch (error: Exception) {
                result.error("po0", error.message, null)
            }
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        observer?.cancel()
        observer = scope?.let { Po0Firewall.observe(it, sink::success) }
    }

    override fun onCancel(arguments: Any?) {
        observer?.cancel()
        observer = null
    }

    private companion object {
        val NOT_IMPLEMENTED = Any()
    }
}
