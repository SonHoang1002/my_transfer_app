package com.example.mytransferapp.model

import kotlinx.coroutines.Job
import java.net.Socket

data class TransferHandle(
    val socket: Socket,
    val job: Job,
)


