package com.example.mytransferapp.model

class TargetDevice(
    ipAddress: String,
    name: String,
    val port: Int,
    val from: ScanModeStatus,
    val lastSeen: Long
) : CoreDevice(name, ipAddress) {


    constructor(
        ipAddress: String = "",
        name: String = "",
        port: Int = 9999,
        from: ScanModeStatus
    ) : this(ipAddress, name, port, from, System.currentTimeMillis())

    fun copyWith(
        ipAddress: String? = null,
        name: String? = null,
        port: Int? = null,
        from: ScanModeStatus? = null,
        lastSeen: Long? = null
    ): TargetDevice {
        return TargetDevice(
            ipAddress = ipAddress ?: this.ipAddress,
            name = name ?: this.name,
            port = port ?: this.port,
            from = from ?: this.from,
            lastSeen = lastSeen ?: this.lastSeen
        )
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as TargetDevice

        if (ipAddress != other.ipAddress) return false
        if (name != other.name) return false
        if (port != other.port) return false
        if (from != other.from) return false
        if (lastSeen != other.lastSeen) return false

        return true
    }

    override fun hashCode(): Int {
        var result = ipAddress.hashCode()
        result = 31 * result + name.hashCode()
        result = 31 * result + port
        result = 31 * result + from.hashCode()
        result = 31 * result + lastSeen.hashCode()
        return result
    }

    override fun toString(): String {
        return "TargetDevice(name='$name', ipAddress='$ipAddress', port=$port, from=$from, lastSeen=$lastSeen)"
    }

    companion object {
        // Constants for 'from' field
        const val FROM_WIFI_SCAN = 0
        const val FROM_BLUETOOTH_SCAN = 1
        const val FROM_MULTIPEER_SCAN = 2

        fun fromCoreDevice(coreDevice: CoreDevice, port: Int = 9999, from: ScanModeStatus = FROM_WIFI_SCAN): TargetDevice {
            return TargetDevice(
                ipAddress = coreDevice.ipAddress,
                name = coreDevice.name,
                port = port,
                from = from,
                lastSeen = System.currentTimeMillis()
            )
        }
    }
}