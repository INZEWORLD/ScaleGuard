package com.follow.clashx.plugins

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService as AndroidVpnService
import java.io.File
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import com.follow.clashx.GlobalState
import com.follow.clashx.RunState
import com.follow.clashx.Service
import com.follow.clashx.common.Components
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.SavedParams
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.models.gsonSanitized
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

class ServicePlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    MethodChannel.MethodCallHandler,
    CoroutineScope {

    private var job = SupervisorJob()
    override val coroutineContext get() = job + Dispatchers.Main

    private lateinit var channel: MethodChannel
    private val eventChannel = Channel<String?>(Channel.UNLIMITED)
    private val gson = Gson()
    @Volatile private var attached = false
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    companion object {
        private const val VPN_PERMISSION_REQUEST_CODE = 4201
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job = SupervisorJob()
        channel = MethodChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/service")
        channel.setMethodCallHandler(this)
        attached = true
        // Single FIFO consumer so events (logs/traffic/state) reach Flutter strictly in
        // order, instead of racing across a Semaphore-bounded parallel dispatch pool.
        launch {
            for (value in eventChannel) {
                invokeOnMain("event", value)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        job.cancel()
        // The engine is gone, so nothing consumes events anymore — drop OUR remote
        // listener so a dead engine doesn't keep the cross-process pipe pumping into
        // an unconsumed channel. Owner-guarded: if a recreated activity's new engine
        // already registered its own listener, this is a no-op. Runs on the global
        // scope — the plugin's own job was cancelled above.
        CommonGlobalState.launch { Service.clearEventListener(this@ServicePlugin) }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        pending.success(resultCode == android.app.Activity.RESULT_OK)
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> handleInit(result)
            "shutdown" -> handleShutdown(result)
            "invokeAction" -> handleInvokeAction(call, result)
            "quickStart" -> handleQuickStart(call, result)
            "syncState" -> handleSyncState(call, result)
            "updateNotificationParams" -> handleUpdateNotificationParams(call, result)
            "start" -> handleStart(call, result)
            "stop" -> handleStop(result)
            "requestPermission" -> handleRequestPermission(result)
            "configureProfile" -> handleConfigureProfile(call, result)
            "startVpn" -> handleStart(call, result)
            "stopVpn" -> handleStop(result)
            "getRunTime" -> handleGetRunTime(result)
            "startListener" -> launch { Service.startListener(); result.successOnMain(true) }
            "stopListener" -> launch { Service.stopListener(); result.successOnMain(true) }
            "setState" -> launch {
                val data = call.arguments<String>() ?: ""
                Service.setState(data)
                result.successOnMain(true)
            }
            "setCrashlytics" -> {
                val enable = call.arguments<Boolean>() ?: true
                SavedParams.setCrashlyticsEnabled(enable)
                CommonGlobalState.setCrashlytics(enable)
                launch {
                    Service.setCrashlytics(enable)
                    result.successOnMain(true)
                }
            }
            "updateDns" -> launch {
                val data = call.arguments<String>() ?: ""
                Service.updateDns(data)
                result.successOnMain(true)
            }
            "getAndroidVpnOptions" -> launch { result.successOnMain(Service.getAndroidVpnOptions()) }
            "getCurrentProfileName" -> launch { result.successOnMain(Service.getCurrentProfileName()) }
            "getTraffic" -> launch { result.successOnMain(Service.getTraffic()) }
            "getTotalTraffic" -> launch { result.successOnMain(Service.getTotalTraffic()) }
            "showSubscriptionNotification" -> handleShowSubscriptionNotification(call, result)
            "saveParams" -> {
                val args = call.arguments as? Map<*, *>
                val init = args?.get("init") as? String ?: ""
                val params = args?.get("params") as? String ?: ""
                val state = args?.get("state") as? String ?: ""
                com.follow.clashx.common.SavedParams.saveQuickStartParams(init, params, state)
                result.successOnMain(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleInit(result: MethodChannel.Result) {
        runCatching { Service.bind() }.onFailure {
            Log.w("ServicePlugin", "Service.bind() failed: ${it.message}")
        }
        Service.onServiceDisconnected = ::onServiceDisconnected
        launch {
            Service.setEventListener({ value -> dispatchEvent(value) }, owner = this@ServicePlugin)
                .onSuccess { result.successOnMain("") }
                .onFailure {
                    Log.w("ServicePlugin", "setEventListener failed: ${it.message}")
                    // Report the failure to Dart instead of swallowing it. A false
                    // "init succeeded" leaves Dart's _initSucceeded=true with NO live
                    // event pipe (empty Logs/Connections/Traffic), and reconnectIfNeeded()
                    // then no-ops forever — fixable only by a full app kill. Surfacing the
                    // error makes _initSucceeded=false so the resume-time reconnectIfNeeded()
                    // re-binds and re-registers the listener.
                    result.errorOnMain(
                        "init_event_listener_failed",
                        it.message ?: "setEventListener failed",
                        null,
                    )
                }
        }
    }

    private fun handleShutdown(result: MethodChannel.Result) {
        launch { Service.setEventListener(null) }
        Service.unbind()
        result.successOnMain(true)
    }

    private fun onServiceDisconnected(message: String) {
        Log.w("ServicePlugin", "remote service disconnected: $message")
        // A RemoteService binder drop means the IPC bridge (the :remote process) was
        // recycled — NOT that the tunnel died. FlVpnService is START_STICKY + foreground
        // and recovers itself via coldStart as long as the persistent isVpnActive flag
        // stays set. Clearing that flag / forcing STOP here was exactly what dropped the
        // VPN on some phones when the app was reopened from background: the disconnect
        // queued while :main was frozen fired on resume and sabotaged the sticky recovery
        // (coldStart then saw isVpnActive == false and stopped itself). Instead, re-derive
        // the real state from the StateHub snapshot — handleSyncState keeps START while
        // the tunnel is genuinely up (recovery bias included) and genuine teardowns arrive
        // as pushed STOPPED transitions once the connection re-establishes. The "crash"
        // signal makes Dart re-bind and re-register its event listener against the
        // reconnected service.
        CommonGlobalState.launch { GlobalState.handleSyncState() }
        invokeOnMain("crash", message)
    }

    private fun handleInvokeAction(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments<String>() ?: run { result.successOnMain(""); return }
        launch {
            // Service.invokeAction completes the callback exactly once (real result /
            // registration failure / watchdog), so don't also complete here.
            Service.invokeAction(data) { payload -> result.successOnMain(payload) }
                .onFailure { Log.w("ServicePlugin", "invokeAction failed: ${it.message}") }
        }
    }

    private fun handleQuickStart(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val initParams = args?.get("init") as? String ?: ""
        val params = args?.get("params") as? String ?: ""
        val state = args?.get("state") as? String ?: ""
        launch {
            // Service.quickStart completes onResult exactly once (real result /
            // registration failure / watchdog), so don't also complete here.
            Service.quickStart(
                initParams,
                params,
                state,
                onStarted = { invokeOnMain("onStarted", null) },
                onResult = { payload -> result.successOnMain(payload) },
            ).onFailure { Log.w("ServicePlugin", "quickStart failed: ${it.message}") }
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val json = call.argument<String>("data") ?: call.arguments as? String
        val options = try {
            if (json.isNullOrBlank()) VpnOptions() else gson.fromJson(json, VpnOptions::class.java).gsonSanitized()
        } catch (e: Exception) {
            Log.w("ServicePlugin", "VpnOptions parse failed, using defaults: ${e.message}")
            VpnOptions()
        }
        doStartService(options, result)
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        val intent = AndroidVpnService.prepare(CommonGlobalState.application)
        if (intent == null) {
            result.successOnMain(true)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.errorOnMain("activity_unavailable", "VPN permission requires an active activity", null)
            return
        }
        pendingPermissionResult?.errorOnMain("permission_replaced", "A newer VPN permission request replaced this one", null)
        pendingPermissionResult = result
        activity.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
    }

    private fun handleConfigureProfile(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrBlank()) {
            result.errorOnMain("empty_profile", "Mihomo profile is empty", null)
            return
        }
        launch {
            runCatching {
                val appFiles = CommonGlobalState.application.filesDir
                val homeDir = File(appFiles, "mihomo").apply { mkdirs() }
                File(homeDir, "config.yaml").writeText(config, Charsets.UTF_8)
                CommonGlobalState.log("configureProfile: config written to ${homeDir.absolutePath}")
                val init = gson.toJson(mapOf("home-dir" to homeDir.absolutePath, "version" to 35))
                val setup = gson.toJson(mapOf("selected-map" to emptyMap<String, String>(), "test-url" to "https://www.gstatic.com/generate_204"))
                val setupResult = Service.quickStart(
                    init,
                    setup,
                    "",
                    onStarted = null,
                    onResult = { payload ->
                        CommonGlobalState.log("configureProfile: core response=${payload.ifBlank { "OK" }}")
                        if (payload.isBlank()) {
                            result.successOnMain(true)
                        } else {
                            result.errorOnMain("profile_rejected", payload, null)
                        }
                    },
                )
                if (setupResult.isFailure) {
                    val message = setupResult.exceptionOrNull()?.message ?: "core unavailable"
                    CommonGlobalState.log("configureProfile failed: $message")
                    result.errorOnMain("core_unavailable", message, null)
                }
            }.onFailure {
                CommonGlobalState.log("configureProfile exception: ${it.message}")
                result.errorOnMain("profile_write_failed", it.message, null)
            }
        }
    }

    private fun doStartService(options: VpnOptions, result: MethodChannel.Result) {
        launch {
            val start = Service.startServiceDetailed(options, GlobalState.runTime)
            val rt = start.runtime
            GlobalState.runTime = rt
            if (rt == 0L) {
                com.follow.clashx.common.SavedParams.setVpnActive(false)
            }
            GlobalState.runStateFlow.tryEmit(if (rt == 0L) RunState.STOP else RunState.START)
            result.successOnMain(mapOf("runtime" to rt, "error" to start.error))
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        launch {
            runCatching { Service.stopService() }
                .onFailure { Log.w("ServicePlugin", "stopService failed: ${it.message}") }
            GlobalState.runTime = 0L
            com.follow.clashx.common.SavedParams.setVpnActive(false)
            GlobalState.runStateFlow.tryEmit(RunState.STOP)
            result.successOnMain(true)
        }
    }

    private fun handleGetRunTime(result: MethodChannel.Result) {
        launch {
            GlobalState.handleSyncState()
            result.successOnMain(GlobalState.runTime)
        }
    }

    private fun handleUpdateNotificationParams(call: MethodCall, result: MethodChannel.Result) {
        val json = call.arguments<String>() ?: ""
        CommonGlobalState.log("updateNotificationParams: raw=$json")
        val params = try {
            gson.fromJson(json, NotificationParams::class.java) ?: NotificationParams()
        } catch (_: Exception) {
            NotificationParams()
        }
        CommonGlobalState.log("updateNotificationParams: title=${params.title}")
        launch {
            runCatching { Service.updateNotificationParams(params) }
                .onFailure { Log.w("ServicePlugin", "updateNotificationParams failed: ${it.message}") }
            result.successOnMain(true)
        }
    }

    private fun handleSyncState(call: MethodCall, result: MethodChannel.Result) {
        launch {
            val stateJson = call.arguments<String>() ?: ""
            if (stateJson.isNotBlank()) {
                Service.setState(stateJson)
            }
            GlobalState.handleSyncState()
            result.successOnMain("")
        }
    }

    private fun handleShowSubscriptionNotification(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run { result.successOnMain(false); return }
        val title = args["title"] as? String ?: ""
        val message = args["message"] as? String ?: ""
        val actionLabel = args["actionLabel"] as? String ?: ""
        val actionUrl = args["actionUrl"] as? String ?: ""

        // Channel creation / Builder.build() / notify can throw (bad icon res, OEM
        // notification quirks); wrap so a throw never strands the Flutter result.
        runCatching {
            val ctx = CommonGlobalState.application
            val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (manager.getNotificationChannel(GlobalState.SUBSCRIPTION_NOTIFICATION_CHANNEL) == null) {
                    val ch = NotificationChannel(
                        GlobalState.SUBSCRIPTION_NOTIFICATION_CHANNEL,
                        "Subscription Updates",
                        NotificationManager.IMPORTANCE_HIGH,
                    )
                    manager.createNotificationChannel(ch)
                }
            }

            val builder = NotificationCompat.Builder(ctx, GlobalState.SUBSCRIPTION_NOTIFICATION_CHANNEL)
                .setSmallIcon(com.follow.clashx.service.R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(message)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)

            if (actionUrl.isNotBlank()) {
                val openIntent = Intent(Intent.ACTION_VIEW, Uri.parse(actionUrl))
                val pi = PendingIntent.getActivity(
                    ctx, 0, openIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                builder.addAction(0, actionLabel.ifBlank { "Open" }, pi)
                builder.setContentIntent(pi)
            }

            manager.notify(GlobalState.SUBSCRIPTION_NOTIFICATION_ID, builder.build())
        }.onSuccess {
            result.successOnMain(true)
        }.onFailure {
            Log.w("ServicePlugin", "showSubscriptionNotification failed: ${it.message}")
            result.errorOnMain("subscription_notification_failed", it.message, null)
        }
    }

    private fun dispatchEvent(value: String?) {
        eventChannel.trySend(value)
    }

    private fun invokeOnMain(method: String, argument: Any?) {
        if (!attached) return
        Handler(Looper.getMainLooper()).post {
            if (!attached) return@post
            runCatching { channel.invokeMethod(method, argument) }
        }
    }

    private fun MethodChannel.Result.successOnMain(value: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runCatching { success(value) }
        } else {
            Handler(Looper.getMainLooper()).post { runCatching { success(value) } }
        }
    }

    private fun MethodChannel.Result.errorOnMain(code: String, message: String?, details: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runCatching { error(code, message, details) }
        } else {
            Handler(Looper.getMainLooper()).post { runCatching { error(code, message, details) } }
        }
    }
}
