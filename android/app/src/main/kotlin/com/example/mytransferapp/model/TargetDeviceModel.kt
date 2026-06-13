package com.example.mytransferapp.model

/**
 * Đại diện cho một thiết bị mục tiêu (đích gửi file / thiết bị được phát hiện).
 *
 * - [from] cho biết thiết bị này được phát hiện / request đến qua phương thức nào
 *   (WIFI: UDP discovery hoặc TCP server đang nhận kết nối, BLUETOOTH: BT classic scan).
 * - [address]: địa chỉ MAC — chỉ có ý nghĩa với thiết bị Bluetooth. Với WiFi, có thể
 *   để null (toMap() sẽ tự fallback về [ipAddress]).
 * - [bondState]: trạng thái ghép đôi Bluetooth ("bonded" | "bonding" | "none").
 */
class TargetDevice(
    ipAddress: String,
    name: String,
    val port: Int,
    val from: ScanMode,
    val lastSeen: Long,
    val address: String? = null,
    val bondState: String? = null,
    val totalFiles: Int = 0,
    val requestId: Long? = null
) : CoreDevice(name, ipAddress) {

    constructor(
        ipAddress: String = "",
        name: String = "",
        port: Int = 9999,
        from: ScanMode,
        address: String? = null,
        bondState: String? = null,
        totalFiles: Int = 0,
        requestId: Long? = null
    ) : this(ipAddress, name, port, from, System.currentTimeMillis(), address, bondState, totalFiles, requestId)

    fun copyWith(
        ipAddress: String? = null,
        name: String? = null,
        port: Int? = null,
        from: ScanMode? = null,
        lastSeen: Long? = null,
        address: String? = null,
        bondState: String? = null,
        totalFiles: Int? = null,
        requestId: Long? = null
    ): TargetDevice {
        return TargetDevice(
            ipAddress = ipAddress ?: this.ipAddress,
            name = name ?: this.name,
            port = port ?: this.port,
            from = from ?: this.from,
            lastSeen = lastSeen ?: this.lastSeen,
            address = address ?: this.address,
            bondState = bondState ?: this.bondState,
            totalFiles = totalFiles ?: this.totalFiles,
            requestId = requestId ?: this.requestId
        )
    }

    /**
     * Kiểm tra thiết bị còn "sống" trong khoảng thời gian [timeoutMs] kể từ
     * lần thấy cuối (mặc định 6s — dùng cho dọn dẹp danh sách scan WiFi).
     */
    fun isAlive(timeoutMs: Long = 6000): Boolean {
        return System.currentTimeMillis() - lastSeen <= timeoutMs
    }

    /**
     * Kiểm tra có requestId không
     */
    fun hasRequestId(): Boolean = requestId != null && requestId > 0

    /**
     * Kiểm tra có file để gửi không
     */
    fun hasFilesToSend(): Boolean = totalFiles > 0

    /**
     * Format số lượng file
     */
    fun getTotalFilesFormatted(): String {
        return when (totalFiles) {
            0 -> "Không có file"
            1 -> "1 file"
            else -> "$totalFiles files"
        }
    }

    /**
     * Chuyển đổi sang Map để gửi qua MethodChannel/EventChannel cho Flutter.
     *
     * - "type": "wifi" hoặc "bluetooth" (dựa theo [from], dùng cho UI hiển thị icon).
     * - "from": tên enum [ScanMode] dạng String ("WIFI" | "BLUETOOTH").
     * - "address": địa chỉ MAC (Bluetooth) — fallback về [ipAddress] nếu null.
     * - "bondState": trạng thái ghép đôi Bluetooth, mặc định "none".
     */
    override fun toMap(): Map<String, Any?> = mapOf(
        "name" to name,
        "ipAddress" to ipAddress,
        "port" to port,
        "from" to from.name,
        "type" to from.name.lowercase(),
        "lastSeen" to lastSeen,
        "address" to (address ?: ipAddress),
        "bondState" to (bondState ?: "none"),
        "totalFiles" to totalFiles,
        "requestId" to requestId
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as TargetDevice

        if (ipAddress != other.ipAddress) return false
        if (name != other.name) return false
        if (port != other.port) return false
        if (from != other.from) return false
        if (lastSeen != other.lastSeen) return false
        if (address != other.address) return false
        if (bondState != other.bondState) return false
        if (totalFiles != other.totalFiles) return false
        if (requestId != other.requestId) return false

        return true
    }

    override fun hashCode(): Int {
        var result = ipAddress.hashCode()
        result = 31 * result + name.hashCode()
        result = 31 * result + port
        result = 31 * result + from.hashCode()
        result = 31 * result + lastSeen.hashCode()
        result = 31 * result + (address?.hashCode() ?: 0)
        result = 31 * result + (bondState?.hashCode() ?: 0)
        result = 31 * result + totalFiles
        result = 31 * result + (requestId?.hashCode() ?: 0)
        return result
    }

    override fun toString(): String {
        return "TargetDevice(name='$name', ipAddress='$ipAddress', port=$port, from=$from, " +
                "lastSeen=$lastSeen, address=$address, bondState=$bondState, totalFiles=$totalFiles, requestId=$requestId)"
    }

    companion object {

        fun fromCoreDevice(
            coreDevice: CoreDevice,
            port: Int = 9999,
            from: ScanMode,
            address: String? = null,
            bondState: String? = null,
            totalFiles: Int = 0,
            requestId: Long? = null
        ): TargetDevice {
            return TargetDevice(
                ipAddress = coreDevice.ipAddress,
                name = coreDevice.name,
                port = port,
                from = from,
                lastSeen = System.currentTimeMillis(),
                address = address,
                bondState = bondState,
                totalFiles = totalFiles,
                requestId = requestId
            )
        }

        /**
         * Tạo TargetDevice từ Map gửi xuống từ Flutter, dùng cho
         * `requestSendFileToMultiple` (mỗi item trong danh sách `devices`).
         *
         * Map mong đợi tối thiểu các key: "name", "ipAddress", "port", "from"
         * (with "from" là index của [ScanMode]).
         */
        fun fromMap(map: Map<*, *>): TargetDevice {
            val fromIndex = (map["from"] as? Int) ?: ScanMode.WIFI.ordinal
            return TargetDevice(
                name = map["name"] as? String ?: "",
                ipAddress = map["ipAddress"] as? String ?: "",
                port = (map["port"] as? Int) ?: 9999,
                from = ScanMode.entries.getOrElse(fromIndex) { ScanMode.WIFI },
                lastSeen = (map["lastSeen"] as? Long) ?: System.currentTimeMillis(),
                address = map["address"] as? String,
                bondState = map["bondState"] as? String,
                totalFiles = (map["totalFiles"] as? Int) ?: 0,
                requestId = (map["requestId"] as? Long)
            )
        }
    }
}