package com.example.mytransferapp.model

data class TransferState(
    val id: Long = 0,
    val fileName: String = "",
    val totalBytes: Long = 0,
    val bytesTransferred: Long = 0,
    val progress: Int = 0,
    val speedMbps: Double = 0.0,
    val isIncoming: Boolean = false,
    val peerName: String = "",
    val status: String = "IDLE", // IDLE, CONNECTING, TRANSFERRING, SUCCESS, FAILED
    val error: String? = null
)