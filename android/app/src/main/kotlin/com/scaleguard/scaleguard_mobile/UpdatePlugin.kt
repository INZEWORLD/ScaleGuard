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
 * Hands a downloaded APK to Android's package installer.
 *
 * The file lives in the application cache, so it is shared through a FileProvider
 * with a one-shot read grant; no external-storage permission is involved. On
 * Android 8+ the package installer itself requires the "install unknown apps"
 * permission, which belongs to ScaleGuard rather than to the installer, so the
 * first update opens that settings page and reports [RESULT_PERMISSION] back to
 * Dart instead of failing silently.
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
        if (call.method != "installApk") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        val context = appContext
        if (context == null || path.isNullOrEmpty()) {
            result.error("bad_args", "APK path is missing", null)
            return
        }
        try {
            val file = File(path)
            if (!file.exists() || file.length() == 0L) {
                result.error("missing_apk", "Downloaded APK is missing", null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !context.packageManager.canRequestPackageInstalls()
            ) {
                val settings = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")
                )
                settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(settings)
                result.success(RESULT_PERMISSION)
                return
            }
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.updates",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(intent)
            result.success(RESULT_STARTED)
        } catch (error: Exception) {
            result.error("install_failed", error.message ?: "Cannot open installer", null)
        }
    }
}
