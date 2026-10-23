package com.scaleguard.scaleguard_mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Dart bridge for the Android updater.
 *
 * The actual transfer lives in [UpdateDownloadService], because it has to keep
 * running after the Flutter activity is replaced by the "install unknown apps"
 * settings screen. This plugin only starts that service, reports its progress
 * to the open dialog and opens the package installer when the APK is ready.
 */
class UpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "scaleguard/updater"
        private const val RESULT_STARTED = "started"
        private const val RESULT_PERMISSION = "permission"
    }

    private var appContext: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("no_context", "Updater is not attached", null)
            return
        }
        when (call.method) {
            "startDownload" -> startDownload(context, call, result)
            "downloadStatus" -> result.success(UpdateDownloadService.snapshot(context))
            "installDownloaded" -> installDownloaded(context, result)
            "installApk" -> installApk(context, call, result)
            else -> result.notImplemented()
        }
    }

    private fun startDownload(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val url = call.argument<String>("url")
        val fileName = call.argument<String>("fileName")
        val version = call.argument<String>("version").orEmpty()
        val size = call.argument<Number>("size")?.toLong() ?: 0L
        if (url.isNullOrEmpty() || fileName.isNullOrEmpty()) {
            result.error("bad_args", "Update URL or file name is missing", null)
            return
        }
        try {
            UpdateDownloadService.start(
                context,
                url,
                fileName,
                version,
                size,
            )
            // Start the transfer first and open the permission screen straight
            // away. By the time the user returns, a large APK is already on its
            // way instead of waiting for another button press.
            val needsPermission = !UpdateDownloadService.hasInstallPermission(context)
            if (needsPermission) openPermissionSettings(context)
            result.success(
                mapOf(
                    "started" to true,
                    "permission" to needsPermission,
                ),
            )
        } catch (error: Exception) {
            result.error(
                "download_start_failed",
                error.message ?: "Cannot start update download",
                null,
            )
        }
    }

    private fun installDownloaded(context: Context, result: MethodChannel.Result) {
        val file = UpdateDownloadService.downloadedApk(context)
        if (file == null) {
            result.error("missing_apk", "Downloaded APK is missing", null)
            return
        }
        if (!UpdateDownloadService.hasInstallPermission(context)) {
            openPermissionSettings(context)
            result.success(RESULT_PERMISSION)
            return
        }
        startInstallActivity(context, file)
        result.success(RESULT_STARTED)
    }

    /**
     * Compatibility path for builds that hand us an APK directly instead of
     * going through [UpdateDownloadService].
     */
    private fun installApk(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("bad_args", "APK path is missing", null)
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.error("missing_apk", "Downloaded APK is missing", null)
            return
        }
        if (!UpdateDownloadService.hasInstallPermission(context)) {
            openPermissionSettings(context)
            result.success(RESULT_PERMISSION)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.updates",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(intent)
            result.success(RESULT_STARTED)
        } catch (error: Exception) {
            result.error(
                "install_failed",
                error.message ?: "Cannot open installer",
                null,
            )
        }
    }

    private fun startInstallActivity(context: Context, file: File) {
        context.startActivity(
            UpdateInstallActivity.intent(context, file.absolutePath)
        )
    }

    private fun openPermissionSettings(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val settings = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(settings) }
    }
}
