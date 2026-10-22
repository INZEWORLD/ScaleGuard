package com.scaleguard.scaleguard_mobile

import android.app.Application
import com.follow.clashx.common.GlobalState

class ScaleGuardApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        GlobalState.init(this)
    }
}