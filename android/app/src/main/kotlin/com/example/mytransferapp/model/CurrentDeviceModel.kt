package com.example.mytransferapp.model

/**
 * Đại diện cho thiết bị hiện tại (thiết bị đang chạy app) — dùng để trả về
 * thông tin "device info" cho phía Flutter qua MethodChannel.
 */
class CurrentDevice(
    ipAddress: String,
    name: String,
    val port: Int,
    val lastSeen: Long
) : CoreDevice(name, ipAddress) {

    // Secondary constructor với lastSeen mặc định là thời gian hiện tại
    constructor(
        ipAddress: String,
        name: String,
        port: Int
    ) : this(ipAddress, name, port, System.currentTimeMillis())

    fun copyWith(
        ipAddress: String? = null,
        name: String? = null,
        port: Int? = null,
        lastSeen: Long? = null
    ): CurrentDevice {
        return CurrentDevice(
            ipAddress = ipAddress ?: this.ipAddress,
            name = name ?: this.name,
            port = port ?: this.port,
            lastSeen = lastSeen ?: this.lastSeen
        )
    }

    // Kiểm tra xem thiết bị có còn hoạt động không (lastSeen trong vòng 10 giây)
    fun isAlive(timeoutMs: Long = 10000): Boolean {
        return System.currentTimeMillis() - lastSeen < timeoutMs
    }

    /**
     * Chuyển đổi sang Map để gửi qua MethodChannel cho Flutter
     * (ví dụ trong "getCurrentDeviceInfo").
     */
    override fun toMap(): Map<String, Any?> = mapOf(
        "name" to name,
        "ipAddress" to ipAddress,
        "port" to port,
        "lastSeen" to lastSeen
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as CurrentDevice

        if (ipAddress != other.ipAddress) return false
        if (name != other.name) return false
        if (port != other.port) return false
        if (lastSeen != other.lastSeen) return false

        return true
    }

    override fun hashCode(): Int {
        var result = ipAddress.hashCode()
        result = 31 * result + name.hashCode()
        result = 31 * result + port
        result = 31 * result + lastSeen.hashCode()
        return result
    }

    override fun toString(): String {
        return "CurrentDevice(name='$name', ipAddress='$ipAddress', port=$port, lastSeen=$lastSeen)"
    }

    companion object {
        // Tạo CurrentDevice từ CoreDevice
        fun fromCoreDevice(coreDevice: CoreDevice, port: Int = 9999): CurrentDevice {
            return CurrentDevice(
                ipAddress = coreDevice.ipAddress,
                name = coreDevice.name,
                port = port,
                lastSeen = System.currentTimeMillis()
            )
        }

        // Tạo CurrentDevice rỗng
        fun empty(): CurrentDevice {
            return CurrentDevice(
                ipAddress = "",
                name = "",
                port = 0,
                lastSeen = 0
            )
        }
    }
}