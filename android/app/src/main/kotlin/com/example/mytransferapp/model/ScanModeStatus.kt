package com.example.mytransferapp.model

/**
 * Phương thức được dùng để phát hiện / kết nối tới thiết bị.
 *
 * - WIFI: phát hiện qua UDP broadcast hoặc nhận kết nối TCP (server đang lắng nghe).
 * - BLUETOOTH: phát hiện qua BluetoothAdapter.startDiscovery() (classic scan).
 */
enum class ScanMode {
    WIFI,
    BLUETOOTH
}

