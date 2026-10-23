package com.scaleguard.scaleguard_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File

/**
 * The trampoline behind "Обновление скачано — нажмите, чтобы установить".
 *
 * Android will not let a notification open the package installer directly when
 * ScaleGuard has not been granted "install unknown apps". This activity is
 * deliberately invisible: it opens the permission screen, waits for the user to
 * come back, and then opens the installer without making them tap the
 * notification a second time.
 */
class UpdateInstallActivity : Activity() {
    companion object {
        private const val EXTRA_APK_PATH = "apk_path"

        fun intent(context: Context, apkPath: String): Intent =
            Intent(context, UpdateInstallActivity::class.java).apply {
                putExtra(EXTRA_APK_PATH, apkPath)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
    }

    private var awaitingPermission = false
    private var leftForSettings = false
    private var apkPath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        apkPath = intent.getStringExtra(EXTRA_APK_PATH)
            ?: UpdateDownloadService.downloadedApk(this)?.absolutePath
        val file = apkPath?.let { File(it) }
        if (file == null || !file.exists() || file.length() <= 0L) {
            toast("Файл обновления не найден. Скачайте обновление ещё раз.")
            finish()
            return
        }
        installOrRequestPermission()
    }

    override fun onPause() {
        super.onPause()
        if (awaitingPermission) leftForSettings = true
    }

    override fun onResume() {
        super.onResume()
        if (!awaitingPermission || !leftForSettings) return
        leftForSettings = false
        awaitingPermission = false
        if (UpdateDownloadService.hasInstallPermission(this)) {
            openInstaller()
        } else {
            toast("Установка из этого источника не разрешена.")
            finish()
        }
    }

    private fun installOrRequestPermission() {
        if (!UpdateDownloadService.hasInstallPermission(this)) {
            awaitingPermission = true
            leftForSettings = false
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(settings)
            } catch (_: Exception) {
                toast("Не удалось открыть разрешение установки.")
                finish()
            }
            return
        }
        openInstaller()
    }

    private fun openInstaller() {
        val path = apkPath ?: run {
            finish()
            return
        }
        try {
            val file = File(path)
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.updates",
                file,
            )
            val installer = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(installer)
            finish()
        } catch (_: Exception) {
            toast("Не удалось открыть установщик Android.")
            finish()
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }
}
