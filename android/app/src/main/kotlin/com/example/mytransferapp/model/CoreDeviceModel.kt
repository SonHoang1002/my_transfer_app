package com.example.mytransferapp.model

/**
 * Base class chung cho các loại thiết bị (thiết bị hiện tại, thiết bị mục tiêu...).
 */
abstract class CoreDevice(
    val name: String,
    val ipAddress: String,
) {
    /**
     * Map cơ bản dùng để gửi qua MethodChannel/EventChannel cho Flutter.
     * Các lớp con nên override để bổ sung thêm field riêng (port, from, lastSeen...).
     */
    open fun toMap(): Map<String, Any?> = mapOf(
        "name" to name,
        "ipAddress" to ipAddress
    )
}