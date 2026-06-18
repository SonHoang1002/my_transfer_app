//
//  Models.swift
//  Runner
//
//  Created by sonmac on 18/6/26.
//

// Models.swift
// SuperTransfer — iOS
//
// Tương đương với các file model Kotlin:
//   ScanMode.kt / SendMode.kt / TargetDevice.kt / TransferState.kt / TransferHandle.kt
//
// Toàn bộ type đều Sendable (dùng được trong actor / async context).

import Foundation
import Network // NWConnection dùng trong TransferHandle

// MARK: - ScanMode

/// Phương thức phát hiện / kết nối thiết bị.
/// - wifi      : UDP broadcast discovery → TCP transfer
/// - bluetooth : CoreBluetooth / MultipeerConnectivity discovery → TCP transfer
///               (iOS không hỗ trợ BT RFCOMM nên transfer vẫn đi qua WiFi TCP,
///                nhưng peer được phát hiện qua BLE/MPC)
enum ScanMode: String, Codable, Sendable {
    case wifi      = "WIFI"
    case bluetooth = "BLUETOOTH"
}

// MARK: - SendMode

/// Chế độ gửi file khi có nhiều thiết bị đích.
enum SendMode: String, Sendable {
    case sequential  // Lần lượt từng thiết bị
    case parallel    // Song song tất cả cùng lúc
}

// MARK: - TargetDevice

/// Đại diện cho một thiết bị mục tiêu (đã phát hiện, chuẩn bị gửi file đến).
///
/// - `from`       : kênh phát hiện (wifi / bluetooth)
/// - `address`    : MAC/UUID của thiết bị BT; với WiFi thường để nil
/// - `bondState`  : trạng thái ghép đôi BT ("bonded" | "bonding" | "none")
/// - `isBusy`     : thiết bị đích đang bận nhận file (phản hồi từ handshake)
/// - `totalFiles` : số file trong request đến (chỉ có nghĩa với incoming request)
/// - `requestId`  : ID để accept / reject một incoming request cụ thể
struct TargetDevice: Identifiable, Hashable, Sendable {
    let id: String          // ipAddress hoặc address — dùng để deduplicate
    let name: String
    let ipAddress: String
    let port: Int
    let from: ScanMode
    let lastSeen: TimeInterval  // Date().timeIntervalSince1970
    let address: String?        // MAC/UUID Bluetooth
    let bondState: String?
    let isBusy: Bool
    let totalFiles: Int
    let requestId: Int64

    // ─── init đầy đủ ────────────────────────────────────────────────────────
    init(
        name: String,
        ipAddress: String,
        port: Int = 9999,
        from: ScanMode,
        lastSeen: TimeInterval = Date().timeIntervalSince1970,
        address: String? = nil,
        bondState: String? = nil,
        isBusy: Bool = false,
        totalFiles: Int = 0,
        requestId: Int64 = 0
    ) {
        self.id         = address ?? ipAddress
        self.name       = name
        self.ipAddress  = ipAddress
        self.port       = port
        self.from       = from
        self.lastSeen   = lastSeen
        self.address    = address
        self.bondState  = bondState
        self.isBusy     = isBusy
        self.totalFiles = totalFiles
        self.requestId  = requestId
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// Thiết bị còn xuất hiện trong khoảng [timeout] giây kể từ lần thấy cuối.
    func isAlive(timeout: TimeInterval = 6) -> Bool {
        Date().timeIntervalSince1970 - lastSeen <= timeout
    }

    func copyWith(
        name: String? = nil,
        ipAddress: String? = nil,
        port: Int? = nil,
        from: ScanMode? = nil,
        lastSeen: TimeInterval? = nil,
        address: String?? = .none,    // .none = không đổi, .some(nil) = set nil
        bondState: String?? = .none,
        isBusy: Bool? = nil,
        totalFiles: Int? = nil,
        requestId: Int64? = nil
    ) -> TargetDevice {
        TargetDevice(
            name:       name       ?? self.name,
            ipAddress:  ipAddress  ?? self.ipAddress,
            port:       port       ?? self.port,
            from:       from       ?? self.from,
            lastSeen:   lastSeen   ?? self.lastSeen,
            address:    address == .none    ? self.address    : address!,
            bondState:  bondState == .none  ? self.bondState  : bondState!,
            isBusy:     isBusy     ?? self.isBusy,
            totalFiles: totalFiles ?? self.totalFiles,
            requestId:  requestId  ?? self.requestId
        )
    }

    func touch() -> TargetDevice {
        copyWith(lastSeen: Date().timeIntervalSince1970)
    }

    // ─── Flutter bridge (toMap) ──────────────────────────────────────────────

    /// Map gửi qua MethodChannel / EventChannel cho Flutter.
    func toMap() -> [String: Any?] {
        [
            "name"       : name,
            "ipAddress"  : ipAddress,
            "port"       : port,
            "from"       : from.rawValue,
            "type"       : from.rawValue.lowercased(),
            "lastSeen"   : Int64(lastSeen * 1000),   // ms, giống Android
            "address"    : address ?? ipAddress,
            "bondState"  : bondState ?? "none",
            "isBusy"     : isBusy,
            "totalFiles" : totalFiles,
            "requestId"  : requestId,
        ]
    }

    /// Tạo từ Map gửi xuống từ Flutter (danh sách devices trong requestSendFileToMultiple).
    static func fromMap(_ map: [AnyHashable: Any]) -> TargetDevice? {
        guard
            let name      = map["name"]      as? String,
            let ipAddress = map["ipAddress"] as? String
        else { return nil }
        let port      = map["port"]       as? Int ?? 9999
        let fromIndex = map["from"]       as? Int ?? 0
        let from: ScanMode = fromIndex == 1 ? .bluetooth : .wifi
        return TargetDevice(
            name:      name,
            ipAddress: ipAddress,
            port:      port,
            from:      from,
            address:   map["address"]   as? String,
            bondState: map["bondState"] as? String
        )
    }
}

// MARK: - TransferStatus

enum TransferStatus: String, Sendable {
    case idle         = "IDLE"
    case connecting   = "CONNECTING"
    case transferring = "TRANSFERRING"
    case success      = "SUCCESS"
    case failed       = "FAILED"
}

// MARK: - TransferState

/// Trạng thái của một lượt truyền file (gửi hoặc nhận).
struct TransferState: Identifiable, Sendable {
    let id: Int64
    var fileName: String        = ""
    var totalBytes: Int64       = 0
    var bytesTransferred: Int64 = 0
    var progress: Int           = 0      // 0‥100
    var speedMbps: Double       = 0
    var isIncoming: Bool        = false
    var peerName: String        = ""
    var status: TransferStatus  = .idle
    var error: String?          = nil

    var isFinished: Bool { status == .success || status == .failed }

    /// Map gửi qua EventChannel cho Flutter.
    func toMap() -> [String: Any?] {
        [
            "id"               : id,
            "fileName"         : fileName,
            "totalBytes"       : totalBytes,
            "bytesTransferred" : bytesTransferred,
            "progress"         : progress,
            "speedMbps"        : speedMbps,
            "isIncoming"       : isIncoming,
            "peerName"         : peerName,
            "status"           : status.rawValue,
            "error"            : error ?? "",
        ]
    }
}

// MARK: - TransferHandle

/// Theo dõi một lượt transfer đang chạy — dùng để cancel bất cứ lúc nào.
final class TransferHandle: @unchecked Sendable {
    /// Kết nối NWConnection (TCP WiFi)
    var connection: NWConnection?
    /// Task async — cancel để dừng coroutine
    var task: Task<Void, Never>?

    init(connection: NWConnection? = nil, task: Task<Void, Never>? = nil) {
        self.connection = connection
        self.task       = task
    }

    func cancel() {
        task?.cancel()
        connection?.cancel()
    }
}
