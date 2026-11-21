package com.follow.clash.plugins

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import com.follow.clash.common.Components
import com.follow.clash.common.registerReceiverCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/** Screen on and off for the po0 whitelist checks, which pause while it is off. */
class Po0ScreenPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private var context: Context? = null
    private var channel: EventChannel? = null
    private var receiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = EventChannel(
            binding.binaryMessenger,
            "${Components.PACKAGE_NAME}/po0_screen",
        ).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setStreamHandler(null)
        channel = null
        unregister()
        context = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val context = context ?: return
        unregister()
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        events.success(power?.isInteractive ?: true)
        val next = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_ON -> events.success(true)
                    Intent.ACTION_SCREEN_OFF -> events.success(false)
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        context.registerReceiverCompat(next, filter)
        receiver = next
    }

    override fun onCancel(arguments: Any?) {
        unregister()
    }

    private fun unregister() {
        val current = receiver ?: return
        receiver = null
        runCatching { context?.unregisterReceiver(current) }
    }
}
