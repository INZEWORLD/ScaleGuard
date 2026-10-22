package com.follow.clashx.service.models

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class NotificationParams(
    val title: String = "ScaleGuard",
    // The line under the title — location and latency. Empty keeps the
    // notification to its title, which is what the very first start has.
    val text: String = "",
    // Blank lets the notification fall back to the localized
    // `R.string.notification_stop`, which the hardcoded English default never did.
    val stopText: String = "",
) : Parcelable
