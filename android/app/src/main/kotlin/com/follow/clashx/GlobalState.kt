package com.follow.clashx

import androidx.lifecycle.MutableLiveData
import kotlinx.coroutines.flow.MutableStateFlow

enum class RunState { START, PENDING, STOP }

object GlobalState {
    const val SUBSCRIPTION_NOTIFICATION_CHANNEL = "ScaleGuard"
    const val SUBSCRIPTION_NOTIFICATION_ID = 2

    @Volatile
    var runTime: Long = 0L

    val runStateFlow: MutableStateFlow<RunState> = MutableStateFlow(RunState.STOP)
    val runState: MutableLiveData<RunState> = MutableLiveData(RunState.STOP)

    fun syncStatus() {
        val state = if (runTime == 0L) RunState.STOP else RunState.START
        runState.value = state
        runStateFlow.value = state
    }

    fun hasActiveProfile(): Boolean = runTime > 0L

    fun handleStart() {
        runTime = System.currentTimeMillis()
        val state = RunState.START
        runState.value = state
        runStateFlow.value = state
    }

    fun handleStop() {
        runTime = 0L
        val state = RunState.STOP
        runState.value = state
        runStateFlow.value = state
    }

    suspend fun handleSyncState() {
        syncStatus()
    }
}
