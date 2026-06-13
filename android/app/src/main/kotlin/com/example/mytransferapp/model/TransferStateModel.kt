package com.example.mytransferapp.model


/**
 * Trạng thái của một lượt truyền file (gửi hoặc nhận).
 *
 * status: IDLE, CONNECTING, TRANSFERRING, SUCCESS, FAILED
 */
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
) {
    /**
     * Chuyển đổi sang Map để gửi qua EventChannel cho Flutter.
     */
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "fileName" to fileName,
        "totalBytes" to totalBytes,
        "bytesTransferred" to bytesTransferred,
        "progress" to progress,
        "speedMbps" to speedMbps,
        "isIncoming" to isIncoming,
        "peerName" to peerName,
        "status" to status,
        "error" to (error ?: "")
    )

    val isFinished: Boolean
        get() = status == "SUCCESS" || status == "FAILED"
}