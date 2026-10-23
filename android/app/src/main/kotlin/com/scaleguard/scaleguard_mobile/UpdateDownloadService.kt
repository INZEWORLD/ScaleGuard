package com.scaleguard.scaleguard_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads an Android update while the app is in the background.
 *
 * The old updater downloaded through Dart, so closing the activity or granting
 * the "install unknown apps" permission could kill the download together with
 * the Flutter engine. This service owns the transfer instead: it starts before
 * the settings screen is opened, keeps an ongoing progress notification, and
 * turns that notification into an "install" action once the APK is complete.
 */
class UpdateDownloadService : Service() {
    companion object {
        private const val CHANNEL_ID = "scaleguard_updates"
        private const val CHANNEL_NAME = "Обновления ScaleGuard"
        private const val NOTIFICATION_ID = 0x5C06

        private const val ACTION_START = "com.scaleguard.app.action.START_UPDATE"
        private const val EXTRA_URL = "url"
        private const val EXTRA_FILE_NAME = "file_name"
        private const val EXTRA_VERSION = "version"
        private const val EXTRA_SIZE = "size"

        private const val STATE_IDLE = "idle"
        private const val STATE_DOWNLOADING = "downloading"
        private const val STATE_DONE = "done"
        private const val STATE_FAILED = "failed"

        @Volatile private var state = STATE_IDLE
        @Volatile private var progress = 0
        @Volatile private var apkPath: String? = null
        @Volatile private var version: String? = null
        @Volatile private var error: String? = null
        @Volatile private var currentUrl: String? = null

        /** Starts (or joins) the single background download. */
        fun start(
            context: Context,
            url: String,
            fileName: String,
            version: String,
            expectedSize: Long,
        ) {
            val intent = Intent(context, UpdateDownloadService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_FILE_NAME, fileName)
                putExtra(EXTRA_VERSION, version)
                putExtra(EXTRA_SIZE, expectedSize)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        /** The state the Flutter update dialog polls while it is open. */
        fun snapshot(context: Context): Map<String, Any?> = mapOf(
            "state" to state,
            "progress" to progress,
            "path" to apkPath,
            "version" to version,
            "error" to error,
            "permission" to hasInstallPermission(context),
        )

        fun downloadedApk(context: Context): File? {
            apkPath?.let { path ->
                val file = File(path)
                if (file.exists() && file.length() > 0L) return file
            }
            return newestApk(context)
        }

        fun hasInstallPermission(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                context.packageManager.canRequestPackageInstalls()

        private fun newestApk(context: Context): File? {
            val directory = File(context.cacheDir, "updates")
            return directory.listFiles()
                ?.filter { it.isFile && it.name.endsWith(".apk", ignoreCase = true) }
                ?.maxByOrNull { it.lastModified() }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var downloadJob: Job? = null
    private val handler = Handler(Looper.getMainLooper())
    private val watchdog = object : Runnable {
        override fun run() {
            if (state != STATE_DOWNLOADING) return
            val manager = getSystemService(NotificationManager::class.java)
            val visible = manager?.activeNotifications?.any { it.id == NOTIFICATION_ID } == true
            if (!visible) {
                // Android 14 lets the user swipe an ongoing foreground-service
                // notification away. Put it straight back: the download must
                // never look like it vanished.
                postForeground(buildProgressNotification(progress))
            }
            handler.postDelayed(this, 1200L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        val rawName = intent.getStringExtra(EXTRA_FILE_NAME).orEmpty()
        val nextVersion = intent.getStringExtra(EXTRA_VERSION).orEmpty()
        val expectedSize = intent.getLongExtra(EXTRA_SIZE, 0L)
        if (url.isEmpty() || rawName.isEmpty()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val fileName = File(rawName).name
        if (!fileName.endsWith(".apk", ignoreCase = true)) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        if (state == STATE_DOWNLOADING &&
            currentUrl == url &&
            version == nextVersion
        ) {
            // A repeated tap must not restart a 130 MB download.
            postForeground(buildProgressNotification(progress))
            return START_REDELIVER_INTENT
        }

        downloadJob?.cancel()
        currentUrl = url
        version = nextVersion
        state = STATE_DOWNLOADING
        progress = 0
        apkPath = null
        error = null
        postForeground(buildProgressNotification(0))
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, 1200L)

        downloadJob = scope.launch {
            download(url, fileName, expectedSize)
        }
        return START_REDELIVER_INTENT
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler.removeCallbacks(watchdog)
        downloadJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun download(url: String, fileName: String, expectedSize: Long) {
        val directory = File(cacheDir, "updates").apply { mkdirs() }
        val target = File(directory, fileName)
        val part = File(directory, "$fileName.part")
        try {
            if (expectedSize > 0L &&
                target.exists() &&
                target.length() == expectedSize
            ) {
                finishSuccess(target)
                return
            }
            target.delete()
            part.delete()
            // Keep the cache bounded: only the APK being installed is useful.
            directory.listFiles()
                ?.filter { it.isFile && it.name.endsWith(".apk", ignoreCase = true) && it != target }
                ?.forEach { runCatching { it.delete() } }

            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20_000
                readTimeout = 60_000
                instanceFollowRedirects = true
                requestMethod = "GET"
                setRequestProperty("User-Agent", "ScaleGuard-Updater")
                setRequestProperty("Accept", "application/octet-stream")
            }
            try {
                val code = connection.responseCode
                if (code !in 200..299) {
                    throw IOException("HTTP $code")
                }
                val total = if (expectedSize > 0L) {
                    expectedSize
                } else {
                    connection.contentLengthLong
                }
                var received = 0L
                var lastPercent = -1
                connection.inputStream.use { input ->
                    FileOutputStream(part).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (currentCoroutineContext().isActive) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            received += read
                            if (total > 0L) {
                                val percent =
                                    ((received * 100L) / total).toInt().coerceIn(0, 100)
                                if (percent != lastPercent) {
                                    lastPercent = percent
                                    progress = percent
                                    postProgress(percent)
                                }
                            }
                        }
                    }
                }
                if (!currentCoroutineContext().isActive) {
                    throw CancellationException()
                }
                if (received <= 0L || part.length() <= 0L) {
                    throw IOException("empty apk")
                }
                if (expectedSize > 0L && received != expectedSize) {
                    throw IOException("size mismatch")
                }
                if (target.exists()) target.delete()
                if (!part.renameTo(target)) {
                    part.copyTo(target, overwrite = true)
                    part.delete()
                }
                finishSuccess(target)
            } finally {
                connection.disconnect()
            }
        } catch (cancelled: CancellationException) {
            runCatching { part.delete() }
            throw cancelled
        } catch (failure: Exception) {
            runCatching { part.delete() }
            finishFailure(failure.message ?: "Не удалось скачать обновление")
        }
    }

    private fun finishSuccess(file: File) {
        state = STATE_DONE
        progress = 100
        apkPath = file.absolutePath
        error = null
        handler.removeCallbacks(watchdog)
        handler.post {
            val notification = buildReadyNotification(file)
            stopForegroundCompat(detach = true)
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, notification)
            stopSelf()
        }
    }

    private fun finishFailure(message: String) {
        state = STATE_FAILED
        error = message
        handler.removeCallbacks(watchdog)
        handler.post {
            val notification = buildFailedNotification(message)
            stopForegroundCompat(detach = true)
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, notification)
            stopSelf()
        }
    }

    private fun postProgress(percent: Int) {
        handler.post {
            if (state != STATE_DOWNLOADING) return@post
            val manager = getSystemService(NotificationManager::class.java) ?: return@post
            manager.notify(NOTIFICATION_ID, buildProgressNotification(percent))
        }
    }

    private fun postForeground(notification: Notification) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }.onFailure {
            // If the system refuses to promote the service (for example when
            // notification permission was revoked), still leave a notification
            // and continue the transfer from the existing process.
            runCatching {
                getSystemService(NotificationManager::class.java)
                    ?.notify(NOTIFICATION_ID, notification)
            }
        }
    }

    private fun stopForegroundCompat(detach: Boolean) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(
                    if (detach) STOP_FOREGROUND_DETACH else STOP_FOREGROUND_REMOVE
                )
            } else {
                @Suppress("DEPRECATION")
                stopForeground(detach)
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Загрузка и установка обновлений ScaleGuard"
                    setShowBadge(false)
                },
            )
        }
    }

    private fun baseBuilder(): NotificationCompat.Builder =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setColor(0xFF7C5CFF.toInt())
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(
                NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE
            )

    private fun buildProgressNotification(percent: Int): Notification {
        val builder = baseBuilder()
            .setContentTitle("Скачивается обновление ScaleGuard")
            .setContentText(if (percent > 0) "$percent%" else "Подготовка…")
            .setOngoing(true)
            .setAutoCancel(false)
            .setProgress(100, percent.coerceIn(0, 100), percent <= 0)
        launchIntent()?.let { builder.setContentIntent(it) }
        return builder.build()
    }

    private fun buildReadyNotification(file: File): Notification =
        baseBuilder()
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Обновление ScaleGuard готово")
            .setContentText("Нажмите, чтобы установить")
            .setOngoing(false)
            .setAutoCancel(true)
            .setProgress(0, 0, false)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    2,
                    UpdateInstallActivity.intent(this, file.absolutePath),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()

    private fun buildFailedNotification(message: String): Notification {
        val builder = baseBuilder()
            .setContentTitle("Не удалось скачать обновление")
            .setContentText(message)
            .setOngoing(false)
            .setAutoCancel(true)
            .setProgress(0, 0, false)
        launchIntent()?.let { builder.setContentIntent(it) }
        return builder.build()
    }

    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
