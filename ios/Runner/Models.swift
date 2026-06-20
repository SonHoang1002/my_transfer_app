// Models.swift
// SuperTransfer — iOS

import Foundation
import Network

// MARK: - ScanMode

enum ScanMode: String, Codable, Sendable {
    case wifi      = "WIFI"
    case bluetooth = "BLUETOOTH"
}

// MARK: - SendMode

enum SendMode: String, Sendable {
    case sequential
    case parallel
}

// MARK: - TargetDevice

struct TargetDevice: Identifiable, Hashable, Sendable {
    let id:         String          // ipAddress or BT UUID — for deduplication
    let name:       String
    let ipAddress:  String
    let port:       Int
    let from:       ScanMode
    let lastSeen:   TimeInterval    // seconds since 1970
    let address:    String?         // BT MAC / UUID
    let bondState:  String?
    let isBusy:     Bool
    let totalFiles: Int
    let requestId:  Int64

    init(
        name:       String,
        ipAddress:  String,
        port:       Int          = 9999,
        from:       ScanMode,
        lastSeen:   TimeInterval = Date().timeIntervalSince1970,
        address:    String?      = nil,
        bondState:  String?      = nil,
        isBusy:     Bool         = false,
        totalFiles: Int          = 0,
        requestId:  Int64        = 0
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

    func isAlive(timeout: TimeInterval = 6) -> Bool {
        Date().timeIntervalSince1970 - lastSeen <= timeout
    }

    func touch() -> TargetDevice {
        TargetDevice(name: name, ipAddress: ipAddress, port: port,
                     from: from, lastSeen: Date().timeIntervalSince1970,
                     address: address, bondState: bondState,
                     isBusy: isBusy, totalFiles: totalFiles, requestId: requestId)
    }

    /// Map sent to Flutter via MethodChannel / EventChannel.
    /// Keys mirror Android TargetDevice.toMap() exactly.
    func toMap() -> [String: Any?] {
        [
            "name"       : name,
            "ipAddress"  : ipAddress,
            "port"       : port,
            "from"       : from.rawValue,
            "type"       : from.rawValue.lowercased(),
            "lastSeen"   : Int64(lastSeen * 1000),
            "address"    : address ?? ipAddress,
            "bondState"  : bondState ?? "none",
            "isBusy"     : isBusy,
            "totalFiles" : totalFiles,
            "requestId"  : requestId,
        ]
    }

    /// Construct from a Flutter map (devices list in requestSendFileToMultiple).
    static func fromMap(_ map: [AnyHashable: Any]) -> TargetDevice? {
        guard
            let name      = map["name"]      as? String,
            let ipAddress = map["ipAddress"] as? String
        else { return nil }
        let port      = map["port"]  as? Int ?? 9999
        let fromIndex = map["from"]  as? Int ?? 0
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

struct TransferState: Identifiable, Sendable {
    let id:              Int64
    var fileName:        String         = ""
    var totalBytes:      Int64          = 0
    var bytesTransferred: Int64         = 0
    var progress:        Int            = 0
    var speedMbps:       Double         = 0
    var isIncoming:      Bool           = false
    var peerName:        String         = ""
    var status:          TransferStatus = .idle
    var error:           String?        = nil

    var isFinished: Bool { status == .success || status == .failed }

    /// Keys mirror Android TransferState.toMap() exactly.
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

final class TransferHandle: @unchecked Sendable {
    var connection: NWConnection?
    var task:       Task<Void, Never>?

    init(connection: NWConnection? = nil, task: Task<Void, Never>? = nil) {
        self.connection = connection
        self.task       = task
    }

    func cancel() {
        task?.cancel()
        connection?.cancel()
    }
}
