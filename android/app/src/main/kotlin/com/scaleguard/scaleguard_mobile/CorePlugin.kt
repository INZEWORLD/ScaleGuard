package com.scaleguard.scaleguard_mobile

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService as AndroidVpnService
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import com.follow.clashx.GlobalState
import com.follow.clashx.RunState
import com.follow.clashx.Service
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.SavedParams
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The Android half of ScaleGuard's cross-platform VPN engine.
 *
 * The Dart side (`lib/core/engines/android_vpn_engine.dart`) treats Android the
 * same way it treats Windows: it generates one mihomo profile, hands it to a
 * core, and then drives that core exclusively over its RESTful controller,
 * which is why the same UI and the same server-selection logic work on every
 * platform.
 *
 * On Android the "core" is the native `FlVpnService` in `:mihomo-service`
 * (the Clash.Meta library compiled into the application), and this plugin is the
 * adapter:
 *
 *  * `startCore` writes the generated profile into the core's home directory,
 *    runs the one-time core setup, brings the `VpnService` up and reports the
 *    loopback address of the controller the Dart side should talk to;
 *  * `stopCore` tears the tunnel down;
 *  * `stats` exposes the service counters for the UI's speed graph.
 *
 * The channel name is deliberately the same on every platform
 * (`com.scaleguard.app/core`), matching the Apple implementation described in
 * `docs/apple.md`.
 */
class CorePlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener,
    MethodChannel.MethodCallHandler,
    CoroutineScope {

    private var job = SupervisorJob()
    override val coroutineContext get() = job + Dispatchers.Main

    private lateinit var channel: MethodChannel
    private val gson = Gson()
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    /**
     * The core's own event stream, kept for the last start attempt.
     *
     * The core reports listener problems as log events ("RESTful API listening
     * at", "External controller listen error"), which the logcat ring buffer
     * drops in seconds. The tail is handed back with the start result instead,
     * so the client can log why a controller never came up.
     */
    private val coreEvents = ArrayList<String>()

    companion object {
        const val CHANNEL_NAME = "com.scaleguard.app/core"
        private const val TAG = "CorePlugin"
        private const val VPN_PERMISSION_REQUEST_CODE = 4301
        private const val NOTIFICATION_REQUEST_CODE = 4302

        /** Directory the native core uses as its working home. */
        private const val CORE_HOME_DIR = "mihomo"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job = SupervisorJob()
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        job.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?): Boolean {
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        pending.success(resultCode == Activity.RESULT_OK)
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_REQUEST_CODE) return false
        val pending = pendingNotificationResult ?: return true
        pendingNotificationResult = null
        pending.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(true)
            "requestPermission" -> handleRequestPermission(result)
            "prepareTunnel" -> handleRequestPermission(result)
            "startCore" -> handleStartCore(call, result)
            "updateNotification" -> handleUpdateNotification(call, result)
            "tunnelStatus" -> handleTunnelStatus(result)
            "warmUp" -> handleWarmUp(result)
            "stopCore" -> handleStopCore(result)
            "stats" -> handleStats(result)
            "backgroundStatus" -> result.success(backgroundStatus())
            "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())
            "openBatteryUsageSettings" -> result.success(openBatteryUsageSettings())
            "requestNotifications" -> handleRequestNotifications(result)
            "openAutostartSettings" -> result.success(openAutostartSettings())
            "openAppSettings" -> result.success(openAppSettings())
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Staying alive in the background
    // -------------------------------------------------------------------------
    // The foreground service keeps the tunnel's process alive, but the battery
    // optimiser still freezes the core's threads once the screen has been off
    // for a while, and the OEM autostart gate decides whether the service may
    // come back at all. Neither has a public API that toggles it: the first is
    // an exemption the user grants, the second an OEM screen only the user can
    // change. This half reports the state and opens those screens.

    /**
     * Applications that keep the connection they were written for.
     *
     * A VPN can be detected by other applications through the system's own
     * network capabilities, and no VPN client can hide that from them — the only
     * reliable answer is not to route those applications at all. Russian
     * services are the ones that both expect a Russian address and are the most
     * likely to refuse to start behind a tunnel (Госуслуги, banks, delivery and
     * market apps), so every installed `ru.*` package is excluded, together with
     * the few large ones that live on `com.` names.
     *
     * It is computed on the device rather than shipped as a fixed list: the set
     * of installed applications differs per phone, and the builder throws for a
     * package that is not installed.
     */
    private fun packagesOutsideTunnel(): List<String> {
        val context = CommonGlobalState.application
        val self = context.packageName
        // Large Russian services that do not live on a `ru.` name. Exact names
        // for the ones that ship a browser or a store front (excluding those
        // would take the user's browsing away from the tunnel), prefixes for the
        // families.
        val knownCom = listOf(
            "com.vkontakte.android",
            "com.wildberries.ru",
            "com.avito.android",
            "com.idamob.tinkoff.android",
            "com.twinby",
            "com.yandex.bank",
            "com.apegroup.mcdonaldsrussia",
        )
        val knownPrefixes = listOf(
            "com.vkusnoitochka",
            "com.octopod.russianpost.",
            "com.allgoritm.",
            "com.edadeal.",
            "ru.kfc.",
            "app.tvoyaapteka.",
        )
        return runCatching {
            context.packageManager.getInstalledPackages(0)
                .asSequence()
                .map { it.packageName }
                .filter { it != self }
                .filter { name ->
                    name.startsWith("ru.") ||
                        name in knownCom ||
                        knownPrefixes.any { name.startsWith(it) }
                }
                .toList()
        }.getOrElse { emptyList() }
    }

    /** Whether the system currently lets the tunnel run unattended. */
    private fun backgroundStatus(): Map<String, Any> {
        val context = CommonGlobalState.application
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val notifications =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val batteryExempt =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && power != null) {
                power.isIgnoringBatteryOptimizations(context.packageName)
            } else {
                true
            }
        val notificationsEnabled =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.N || notifications.areNotificationsEnabled()
        return mapOf(
            "batteryExempt" to batteryExempt,
            "notifications" to notificationsEnabled,
            "manufacturer" to Build.MANUFACTURER,
        )
    }

    /**
     * Opens the system dialog that removes this application from battery
     * optimisation.
     *
     * The direct request is only shown for applications the system recognises as
     * needing it; when the OEM has removed that dialog the full list is opened
     * instead, where the same switch lives one tap away.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        val context = CommonGlobalState.application
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:${context.packageName}"))
            if (launch(direct)) return true
            if (launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))) return true
        }
        return openAppSettings()
    }

    /**
     * Opens the per-application battery screen, the one that says "Расход заряда
     * батареи приложением" (or "Battery saver" / "Battery usage").
     *
     * It is a different switch from the optimisation exemption: the exemption
     * keeps Doze from freezing the process, while the restriction level shown here
     * is what vendor shells use to kill a background service after a few minutes.
     * On MIUI/HyperOS the useful value is "Без ограничений" (No restrictions).
     *
     * The OEM screens are tried first because the application page buries the
     * switch behind two more taps; the plain application page is always the
     * fallback.
     */
    private fun openBatteryUsageSettings(): Boolean {
        val context = CommonGlobalState.application
        val candidates =
            listOf(
                // MIUI / HyperOS battery saver for one application.
                Intent().setClassName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
                ).putExtra("package_name", context.packageName)
                    .putExtra("package_label", applicationLabel()),
                // MIUI / HyperOS application page, where the battery row lives.
                // Not the permissions editor: that screen has no battery switch.
                Intent()
                    .setClassName(
                        "com.miui.securitycenter",
                        "com.miui.appmanager.ApplicationsDetailsActivity",
                    )
                    .putExtra("package_name", context.packageName),
                // EMUI and HarmonyOS.
                Intent().setClassName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.power.ui.HwPowerManagerActivity",
                ),
                // ColorOS / realme.
                Intent().setClassName(
                    "com.coloros.oppoguardelf",
                    "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity",
                ),
                // One UI.
                Intent().setClassName(
                    "com.samsung.android.lool",
                    "com.samsung.android.sm.ui.battery.BatteryActivity",
                ),
            )
        for (candidate in candidates) {
            if (launch(candidate)) return true
        }
        return openAppSettings()
    }

    /** The name a vendor battery screen shows for this application. */
    private fun applicationLabel(): String {
        val context = CommonGlobalState.application
        return runCatching {
            context.packageManager.getApplicationLabel(context.applicationInfo).toString()
        }.getOrElse { "ScaleGuard" }
    }

    /** Asks for the notification permission the foreground tunnel needs. */
    private fun handleRequestNotifications(result: MethodChannel.Result) {
        val context = CommonGlobalState.application
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(openNotificationSettings())
            return
        }
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(openNotificationSettings())
            return
        }
        pendingNotificationResult?.success(false)
        pendingNotificationResult = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        )
    }

    private fun openNotificationSettings(): Boolean {
        val context = CommonGlobalState.application
        val intent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:${context.packageName}"))
            }
        return launch(intent)
    }

    /** The application's own system page, where autostart usually also lives. */
    private fun openAppSettings(): Boolean {
        val context = CommonGlobalState.application
        return launch(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${context.packageName}")),
        )
    }

    /** The OEM autostart screen, for the shells that hide it behind an activity. */
    private fun openAutostartSettings(): Boolean {
        val candidates =
            listOf(
                Intent().setClassName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
                Intent("miui.intent.action.OP_AUTO_START"),
                Intent().setClassName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                ),
                Intent().setClassName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                ),
                Intent().setClassName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                ),
            )
        for (candidate in candidates) {
            if (launch(candidate)) return true
        }
        return openAppSettings()
    }

    private fun launch(intent: Intent): Boolean {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val host: Context = activityBinding?.activity ?: CommonGlobalState.application
        return runCatching { host.startActivity(intent) }
            .onFailure { Log.d(TAG, "could not open $intent: ${it.message}") }
            .isSuccess
    }

    /** Asks Android for the VPN consent dialog. */
    private fun handleRequestPermission(result: MethodChannel.Result) {
        val context = CommonGlobalState.application
        val intent = AndroidVpnService.prepare(context)
        if (intent == null) {
            // Already granted for this application.
            result.success(true)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        activity.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
    }

    /**
     * Boots the native core with a profile generated by Dart.
     *
     * Arguments: `config` (the mihomo YAML), `controllerUrl` (where the core will
     * expose its RESTful controller) and `logLevel`.
     */
    /**
     * Replaces the line under the notification title.
     *
     * The latency changes while the session runs and the notification is what
     * the user sees after leaving the application, so it is kept current instead
     * of only being right at the moment the tunnel came up.
     */
    private fun handleUpdateNotification(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim().orEmpty()
        if (text.isEmpty()) {
            result.success(false)
            return
        }
        SavedParams.saveNotificationText(text)
        launch {
            runCatching { Service.updateNotificationParams(NotificationParams(text = text)) }
                .onFailure { Log.d(TAG, "updateNotification failed: ${it.message}") }
            result.success(true)
        }
    }

    /**
     * Whether a tunnel is already carrying traffic, and where its controller
     * listens.
     *
     * The window can be closed while the foreground service keeps the tunnel
     * up. A relaunch that assumed "disconnected" would start a second core over
     * the first — slow, and it drops a connection the user still has. The
     * profile on disk is the source of the ports, because it is exactly the one
     * the running core was started with.
     */
    private fun handleTunnelStatus(result: MethodChannel.Result) {
        launch {
            val state = runCatching {
                Service.bind()
                Service.fetchServiceState()
            }.getOrNull()
            val config = runCatching {
                File(File(CommonGlobalState.application.filesDir, CORE_HOME_DIR), "config.yaml")
                    .takeIf { it.exists() }
                    ?.readText()
            }.getOrNull().orEmpty()
            val controllerPort = Regex("""(?m)^external-controller:\s*(?:[\w.\-]+:)?(\d+)""")
                .find(config)
                ?.groupValues
                ?.get(1)
                ?.toIntOrNull()
                ?: 0
            val secret = Regex("""(?m)^secret:\s*(\S+)""")
                .find(config)
                ?.groupValues
                ?.get(1)
                .orEmpty()
            result.success(
                mapOf(
                    "state" to (state?.state ?: "stopped"),
                    "startedAt" to (state?.startedAt ?: 0L),
                    "controllerPort" to controllerPort,
                    "secret" to secret,
                    "mixedPort" to mixedPort(config),
                ),
            )
        }
    }

    /**
     * Loads the core before the first connect.
     *
     * A cold start spends most of its time outside Dart: `:remote` is created,
     * the core library is mapped, and only then does the profile get parsed.
     * Doing that at launch moves the cost off the path the user waits on when
     * they press "Подключить".
     */
    private fun handleWarmUp(result: MethodChannel.Result) {
        launch {
            val started = SystemClock.elapsedRealtime()
            val answer = runCatching {
                Service.bind()
                coreCall("""{"method":"getIsInit"}""", timeoutMs = 15_000)
            }.getOrDefault("failed")
            Log.d(TAG, "warmUp: ${SystemClock.elapsedRealtime() - started} ms ($answer)")
            result.success(true)
        }
    }

    private fun handleStartCore(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrBlank()) {
            result.error("empty_profile", "Профиль mihomo пуст", null)
            return
        }
        val controllerUrl = call.argument<String>("controllerUrl")
            ?: run {
                result.error("missing_controller", "Не указан адрес контроллера ядра", null)
                return
            }
        // "tun" (default) or "systemProxy": which of the two connection modes the
        // client is in. The service decides from it whether applications get the
        // core's HTTP proxy pushed into their network settings.
        val mode = call.argument<String>("mode") ?: "tun"
        val controllerPort = call.argument<Int>("controllerPort") ?: 0
        // What the status notification says under the application name. It is
        // the only part of the interface that stays on screen for a whole
        // session, so the location belongs in it from the first frame.
        val notificationText = call.argument<String>("notificationText")?.trim().orEmpty()

        launch {
            try {
                // Where the seconds of a cold start go: binding has to boot the
                // `:remote` process and load the core library, the profile is parsed
                // twice, and only then does the tunnel come up. The marks travel back
                // with the result so a slow start can be diagnosed from the log
                // instead of guessed at.
                val started = SystemClock.elapsedRealtime()
                val timings = linkedMapOf<String, Long>()
                fun mark(step: String) {
                    timings[step] = SystemClock.elapsedRealtime() - started
                }
                // 1. The service must be bound before any action reaches it, and
                //    the event pipe has to exist so the core's state reaches us.
                Service.bind()
                Service.setEventListener({ value ->
                    if (value != null) {
                        synchronized(coreEvents) {
                            if (coreEvents.size >= 200) coreEvents.removeAt(0)
                            coreEvents.add(value)
                        }
                    }
                    Log.d(TAG, "core event: $value")
                }, owner = this@CorePlugin)
                mark("bind")

                if (notificationText.isNotEmpty()) {
                    // On disk first, without a round trip: the tunnel service may
                    // still be cold, and its own start reads the text from there.
                    SavedParams.saveNotificationText(notificationText)
                    // Fire-and-forget: the binder round trip must not sit between
                    // the user's tap and the core starting.
                    launch {
                        runCatching {
                            Service.updateNotificationParams(
                                NotificationParams(text = notificationText),
                            )
                        }
                    }
                }

                // 2. Place the generated profile in the core's home directory and
                //    let the core parse it once (this also validates it).
                val homeDir = File(CommonGlobalState.application.filesDir, CORE_HOME_DIR)
                if (!homeDir.exists() && !homeDir.mkdirs()) {
                    result.error("home_dir_failed", "Не удалось создать ${homeDir.path}", null)
                    return@launch
                }
                File(homeDir, "config.yaml").writeText(config, Charsets.UTF_8)
                val configPath = File(homeDir, "config.yaml").absolutePath

                val initBefore = coreCall("""{"method":"getIsInit"}""")
                // Log events only reach the host once the pump is started; the
                // core reports listener failures there and nowhere else.
                coreCall("""{"method":"startLog"}""")
                mark("core")

                // This core does not read the profile from its home directory:
                // the setup call carries the parsed profile in a `config` field.
                val validate = coreCall(
                    gson.toJson(
                        mapOf(
                            "method" to "validateConfig",
                            // This build takes the profile's text, not a path: a
                            // path made it parse the literal path as YAML and
                            // report that a scalar cannot become a profile.
                            "data" to config,
                        ),
                    ),
                )
                // The setup call takes the profile as a structured object, so it
                // is the core's own parser that produces it: whatever field names
                // and types its structs define are exactly what comes back.
                val profileJson = loadProfileJson(configPath)
                if (profileJson == null) {
                    // Booting the default profile hides the problem behind a
                    // controller that never answers; name it instead.
                    result.error(
                        "profile_rejected",
                        "Ядро не разобрало профиль: ${actionError(validate)}",
                        null,
                    )
                    return@launch
                }

                // The profile is applied in the order the core expects, and the
                // only proof that it was applied is its own HTTP listener coming
                // up. `startListener` is a no-op while the core's "running" flag
                // is set, and setup sets that flag, so the flag is cleared first;
                // otherwise the controller never opens and the client's poll
                // times out on a tunnel that is otherwise routing fine.
                val attempts = mutableListOf<String>()
                val setupError = configureCore(homeDir.absolutePath, profileJson)
                attempts.add("setup: ${setupError ?: "ok"}")
                mark("setup")
                if (setupError != null) {
                    // The core keeps running on its default profile in this case:
                    // a tunnel that carries no traffic and answers nothing.
                    result.error("profile_rejected", setupError, null)
                    return@launch
                }
                runCatching { Service.stopListener() }
                runCatching { Service.startListener() }
                var controllerUp = awaitController(controllerPort, 1_500)
                attempts.add("listener: ${if (controllerUp) "up" else "down"}")
                mark("listener")
                val initAfter = coreCall("""{"method":"getIsInit"}""")

                // 3. Bring the tunnel up. The service owns the TUN file
                //    descriptor; `dnsServerAddress` is resolved from the profile's
                //    dns.listen setting so the core answers in-tunnel queries.
                val outsideTunnel = packagesOutsideTunnel()
                // The list is the first thing to check when a Russian service
                // still sees the tunnel: log it so `adb logcat` answers the
                // question without a rebuild.
                Log.d(TAG, "apps outside tunnel (${outsideTunnel.size}): ${outsideTunnel.joinToString()}")
                val options = VpnOptions(
                    enable = true,
                    port = mixedPort(config),
                    dnsServerAddress = controllerDnsAddress(config),
                    allowBypass = false,
                    // Only the proxy mode hands applications the core's own HTTP
                    // proxy; the tunnel covers the rest in both modes.
                    systemProxy = mode == "systemProxy",
                    ipv4 = true,
                    ipv6 = false,
                    // Russian applications keep the connection they were written
                    // for: they talk to hosts that expect a Russian address, and
                    // several of them refuse to work when the system reports a
                    // VPN at all. Excluding them from the tunnel removes both
                    // problems, and it is what "Russian sites stay direct"
                    // already promises for their web versions.
                    excludePackage = outsideTunnel,
                )
                val start = Service.startServiceDetailed(options, GlobalState.runTime)
                mark("tunnel")
                GlobalState.runTime = start.runtime
                GlobalState.runStateFlow.tryEmit(if (start.runtime == 0L) RunState.STOP else RunState.START)

                if (start.runtime == 0L) {
                    result.error(
                        "core_start_failed",
                        describeStartFailure(start.error.orEmpty()),
                        null,
                    )
                    return@launch
                }

                // `startTun` brings the tunnel interface up but does not open the
                // core's own HTTP endpoints. If the controller was still down
                // before the tunnel, give it one more chance with the flag freshly
                // cleared, now that the service owns the process.
                if (!controllerUp) {
                    runCatching { Service.stopListener() }
                    runCatching { Service.startListener() }
                    controllerUp = awaitController(controllerPort, 2_000)
                    attempts.add("after tunnel: ${if (controllerUp) "up" else "down"}")
                }
                val initFinal = coreCall("""{"method":"getIsInit"}""")

                // The core's own view of the profile: which mixed port, DNS and
                // routing it actually took from the file. When it disagrees with
                // the generated profile, the controller is usually listening on
                // another port, and the client's poll times out for no visible
                // reason. Reported to the Dart side so it lands in the app log.
                val coreOptions = runCatching { Service.getAndroidVpnOptions() }
                    .getOrNull()
                val coreProfile = runCatching { Service.getCurrentProfileName() }
                    .getOrNull()
                // A short pause so the tail of the core's startup events (the TUN
                // address line, DNS) is included in the report; it used to be 400 ms,
                // which was time the user spent waiting for "connected".
                delay(120)
                val eventTail = synchronized(coreEvents) {
                    coreEvents.takeLast(40)
                }
                mark("total")

                result.success(
                    mapOf(
                        "controllerUrl" to controllerUrl,
                        "coreOptions" to coreOptions,
                        "coreProfile" to coreProfile,
                        "coreEvents" to eventTail,
                        "initBefore" to initBefore,
                        "initAfter" to initAfter,
                        "initFinal" to initFinal,
                        "validate" to validate,
                        "attempts" to attempts,
                        "controllerUp" to controllerUp,
                        "timings" to timings,
                    ),
                )
            } catch (error: Exception) {
                Log.w(TAG, "startCore failed", error)
                result.error("core_start_exception", error.message ?: "Ошибка запуска ядра", null)
            }
        }
    }

    /**
     * Sends one method call to the core and waits for its answer.
     *
     * The core exposes a JSON-RPC-style surface (`invokeAction`), which is the
     * only way to ask it about its own state: whether it is initialised, whether
     * the generated profile parses, and what its log says.
     */
    private suspend fun coreCall(action: String, timeoutMs: Long = 8_000): String {
        var payload: String? = null
        val outcome = Service.invokeAction(action) { value -> payload = value }
        if (outcome.isFailure) {
            return "invoke failed: ${outcome.exceptionOrNull()?.message}"
        }
        val deadline = System.currentTimeMillis() + timeoutMs
        while (payload == null && System.currentTimeMillis() < deadline) {
            delay(50)
        }
        return payload ?: "no answer in ${timeoutMs}ms"
    }

    /**
     * True once something accepts a TCP connection on the core's loopback port.
     *
     * This is the client's own readiness check, done natively and without HTTP:
     * it answers "did the listener open at all", which is exactly the question
     * the Dart poll cannot separate from "the controller is slow".
     */
    private suspend fun awaitController(port: Int, timeoutMs: Long): Boolean {
        if (port <= 0) return false
        return withContext(Dispatchers.IO) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                val open = runCatching {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress("127.0.0.1", port), 250)
                    }
                    true
                }.getOrDefault(false)
                if (open) return@withContext true
                delay(120)
            }
            false
        }
    }

    /**
     * Pulls the human-readable part out of a core action response.
     *
     * The core answers errors as `{"id":"","method":"…","data":"<text>","code":0}`,
     * so the envelope itself is noise in a message meant for the user.
     */
    private fun actionError(response: String): String = runCatching {
        JsonParser.parseString(response)
            .asJsonObject
            .get("data")
            ?.takeIf { it.isJsonPrimitive }
            ?.asString
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: response

    /**
     * Asks the core to parse the profile file and returns it as JSON.
     *
     * The setup call takes the profile as a structured object, so the safest
     * source of that object is the core's own parser: whatever field names and
     * types it defines are exactly what comes back.
     */
    private suspend fun loadProfileJson(path: String): JsonElement? {
        val response = coreCall(gson.toJson(mapOf("method" to "getConfig", "data" to path)))
        return runCatching {
            val root = JsonParser.parseString(response).asJsonObject
            if (root.get("code")?.asInt != 0) return null
            root.get("data")?.takeIf { it.isJsonObject }
        }.getOrNull()
    }

    /**
     * Runs the core's one-time setup.
     *
     * Returns `null` on success, or the core's own error text, which is far more
     * useful to the user than a generic failure.
     */
    private suspend fun configureCore(homeDir: String, profile: JsonElement? = null): String? {
        val init = gson.toJson(
            mapOf(
                // `version` is the core's settings schema revision; 35 matches the
                // bundled mihomo build and is a no-op for newer revisions.
                "home-dir" to homeDir,
                "version" to 35,
            ),
        )
        val setup = JsonObject().apply {
            // Without this the core boots on its built-in default profile: no
            // proxies, no ports, and no controller, which looks exactly like a
            // core that hung.
            if (profile != null) add("config", profile)
            add("selected-map", JsonObject())
            addProperty("test-url", "https://www.gstatic.com/generate_204")
        }.toString()
        var error: String? = null
        val outcome = Service.quickStart(init, setup, "{}", onStarted = null) { payload ->
            if (payload.isNotBlank()) error = payload
        }
        if (outcome.isFailure) {
            return outcome.exceptionOrNull()?.message ?: "Ядро недоступно"
        }
        return error
    }

    private fun handleStopCore(result: MethodChannel.Result) {
        launch {
            // The listener lives in the same native core as the tunnel; closing it
            // first keeps the controller from answering for a tunnel that is about
            // to disappear.
            runCatching { Service.stopListener() }
                .onFailure { Log.w(TAG, "stopListener failed: ${it.message}") }
            runCatching { Service.stopService() }
                .onFailure { Log.w(TAG, "stopService failed: ${it.message}") }
            GlobalState.runTime = 0L
            GlobalState.runStateFlow.tryEmit(RunState.STOP)
            result.success(true)
        }
    }

    /**
     * Traffic counters for the UI.
     *
     * `Service.getTotalTraffic()`/`getTraffic()` answer as JSON packets, so they
     * are passed through to Dart as-is and parsed on that side, where a malformed
     * payload can be handled without crashing the tunnel.
     */
    private fun handleStats(result: MethodChannel.Result) {
        launch {
            val total = runCatching { Service.getTotalTraffic() }.getOrNull()
            val current = runCatching { Service.getTraffic() }.getOrNull()
            result.success(
                mapOf(
                    "total" to total,
                    "current" to current,
                    "runtime" to GlobalState.runTime,
                ),
            )
        }
    }

    /**
     * Address the tunnel offers applications as their DNS server.
     *
     * The profile sets `dns.listen` to the core's own loopback resolver, which is
     * exactly the kind of address `VpnService.Builder.addDnsServer` refuses: it
     * throws `IllegalArgumentException("Bad address")` for a loopback or wildcard
     * address, and the whole start then failed before a tunnel existed. An empty
     * answer makes the service fall back to the standard in-tun resolver, which
     * the core answers through the profile's `tun.dns-hijack`.
     */
    private fun controllerDnsAddress(config: String): String {
        val match = Regex("""listen:\s*([0-9.]+):\d+""").find(config) ?: return ""
        val address = match.groupValues[1]
        val octets = address.split('.').map { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it == null || it !in 0..255 }) return ""
        val first = octets[0] ?: return ""
        // 0.0.0.0/8 (wildcard) and 127.0.0.0/8 (loopback) are both rejected.
        return if (first == 0 || first == 127) "" else address
    }

    /**
     * The core's mixed port, taken from the profile.
     *
     * Applications are pointed at it in proxy mode. Zero means "not found", which
     * the service treats as "leave the proxy alone" rather than as port 0.
     */
    private fun mixedPort(config: String): Int =
        Regex("""(?m)^mixed-port:\s*(\d+)""")
            .find(config)
            ?.groupValues
            ?.get(1)
            ?.toIntOrNull()
            ?: 0

    /**
     * Turns the native failure text into something a user can act on.
     *
     * The core and the platform both report the raw cause ("Bad address"), which
     * never says what to do about it.
     */
    private fun describeStartFailure(raw: String): String {
        val message = raw.trim()
        return when {
            message.isEmpty() -> "Служба VPN не запустилась"
            message.contains("Bad address", ignoreCase = true) ->
                "Недопустимый адрес в настройках туннеля ($message). Обновите приложение или сообщите в поддержку."
            message.contains("establish() returned null", ignoreCase = true) ->
                "Система не выдала разрешение на VPN. Разрешите подключение и повторите."
            else -> message
        }
    }
}
