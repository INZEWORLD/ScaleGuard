package com.follow.clashx.service.modules

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.buildServiceNotification
import com.follow.clashx.common.startForegroundSafely
import com.follow.clashx.service.Module
import com.follow.clashx.service.State
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class NotificationModule(service: Service) : Module(service) {
    private var scope = CoroutineScope(SupervisorJob())
    private var paramsJob: Job? = null
    private var watchdogJob: Job? = null

    override suspend fun install() {
        scope = CoroutineScope(SupervisorJob())
        ensureChannel()
        val params = State.notificationParamsFlow.value
        val notification = buildNotification(params)
        val fgType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        service.startForegroundSafely(GlobalState.NOTIFICATION_ID, notification, fgType)

        paramsJob = scope.launch {
            State.notificationParamsFlow.collectLatest { params ->
                val n = buildNotification(params)
                ContextCompat.getSystemService(service, NotificationManager::class.java)
                    ?.notify(GlobalState.NOTIFICATION_ID, n)
            }
        }

        // On Android 14+ a foreground-service notification can be swiped away
        // by the user even when it is ongoing. The tunnel keeps running, but
        // until now there was no way back to that notification short of
        // reopening the app. Put it back when it disappears.
        watchdogJob = scope.launch {
            while (true) {
                delay(10_000)
                restoreNotificationIfMissing()
            }
        }
    }

    override suspend fun uninstall() {
        paramsJob?.cancel()
        watchdogJob?.cancel()
        scope.cancel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }

    private fun restoreNotificationIfMissing() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                service,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val manager = ContextCompat.getSystemService(service, NotificationManager::class.java)
            ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            manager.activeNotifications.any { it.id == GlobalState.NOTIFICATION_ID }
        ) {
            return
        }
        GlobalState.log("VPN notification missing; restoring")
        val notification = buildNotification(State.notificationParamsFlow.value)
        val fgType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        // Both calls are deliberate: startForeground re-attaches the
        // notification to the service on OEM builds that suppress a plain
        // notify(), and notify() covers the case where the service is already
        // foreground and only the notification was dismissed.
        service.startForegroundSafely(GlobalState.NOTIFICATION_ID, notification, fgType)
        runCatching { manager.notify(GlobalState.NOTIFICATION_ID, notification) }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(GlobalState.NOTIFICATION_CHANNEL) != null) return
        val channel = NotificationChannel(
            GlobalState.NOTIFICATION_CHANNEL,
            service.getString(com.follow.clashx.common.R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(params: com.follow.clashx.service.models.NotificationParams): android.app.Notification {
        return service.buildServiceNotification(
            com.follow.clashx.service.R.drawable.ic_notification,
            params.title,
            params.text,
            params.stopText,
        )
    }
}
