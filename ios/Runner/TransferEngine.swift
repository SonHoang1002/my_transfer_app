// TransferEngine.swift
// SuperTransfer — iOS
//
// Wire protocol TƯƠNG THÍCH 100% Android ↔ iOS:
//   REQUEST: [Int32BE=0][Int32BE=metaLen]["senderName|totalFiles"]
//   Response: [Int32BE]  0=ACCEPT  1=REJECT  2=BUSY
//   FILE:    [Int32BE=1][Int32BE=metaLen]["fileName|fileSize|senderName|idx|total"][bytes...]

import Foundation
import Network
import CoreBluetooth
import Photos
import Combine
import UIKit

// MARK: - TransferEngine

@available(iOS 14, *)
@MainActor
final class TransferEngine: NSObject, ObservableObject {

    // ── Singleton ─────────────────────────────────────────────────────────────
    static let shared = TransferEngine()

    // ── Constants ──────────────────────────────────────────────────────────────
    private let udpDiscoveryPort: UInt16    = 8889
    private let tcpTransferPort:  UInt16    = 9999
    private let bufferSize:       Int       = 512 * 1024   // 512 KB
    private let requestTimeoutSec: TimeInterval = 60

    // BLE service UUID — dùng để phát hiện thiết bị qua BLE
    private let bleServiceUUID = CBUUID(string: "FA87C0D0-AFAC-11DE-8A39-0800200C9A66")

    // Handshake protocol constants (giữ nguyên với Android)
    private let MSG_TYPE_REQUEST: Int32 = 0
    private let MSG_TYPE_FILE:    Int32 = 1
    private let RESPONSE_ACCEPT:  Int32 = 0
    private let RESPONSE_REJECT:  Int32 = 1
    private let RESPONSE_BUSY:    Int32 = 2

    // ── @Published state ───────────────────────────────────────────────────────
    @Published private(set) var discoveredDevices:    [TargetDevice]       = []
    @Published private(set) var transfers:            [Int64: TransferState] = [:]
    @Published private(set) var isWifiScanning:       Bool = false
    @Published private(set) var isBluetoothScanning:  Bool = false
    @Published private(set) var isReceiving:          Bool = false
    @Published private(set) var isAdvertising:        Bool = false

    // Sự kiện: thiết bị khác gửi REQUEST đến — Flutter hiển thị dialog
    let incomingRequestSubject    = PassthroughSubject<TargetDevice, Never>()
    // Kết quả handshake phía gửi
    let sendRequestResultSubject  = PassthroughSubject<SendRequestResult, Never>()

    struct SendRequestResult {
        let device:   TargetDevice
        let accepted: Bool
        let isBusy:   Bool
    }

    // ── Internal state ─────────────────────────────────────────────────────────
    private var deviceMap:          [String: TargetDevice]                        = [:]
    private var activeTransfers:    [Int64: TransferHandle]                       = [:]
    private var activeReceiveCount: Int                                           = 0
    private var pendingRequests:    [Int64: CheckedContinuation<Bool, Never>]     = [:]

    // Tasks
    private var udpAdvertiseTask: Task<Void, Never>?
    private var udpScanTask:      Task<Void, Never>?
    private var btScanTask:       Task<Void, Never>?

    // TCP listener
    private var tcpListener: NWListener?

    // CoreBluetooth
    private var centralManager:   CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    // ── Init ───────────────────────────────────────────────────────────────────
    private override init() { super.init() }

    // MARK: - Device Info

    func getDeviceName() -> String { UIDevice.current.name }

    func getLocalIpAddress() -> String {
        var result = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let iface = ptr {
            let flags = Int32(iface.pointee.ifa_flags)
            let addr  = iface.pointee.ifa_addr.pointee
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               addr.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(iface.pointee.ifa_addr,
                               socklen_t(addr.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result = String(cString: host)
                }
            }
            ptr = iface.pointee.ifa_next
        }
        return result
    }

    func getTransferEngineStatus() -> [String: Any] {
        [
            "isWifiScanning"      : isWifiScanning,
            "isBluetoothScanning" : isBluetoothScanning,
            "isReceiving"         : isReceiving,
            "isAdvertising"       : isAdvertising,
        ]
    }

    // MARK: - Emit helpers

    private func emitTransfer(_ state: TransferState) {
        transfers[state.id] = state
    }

    private func scheduleRemoveTransfer(_ id: Int64) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            transfers.removeValue(forKey: id)
        }
    }

    // MARK: - Cancel transfers

    func cancelActiveTransfer(_ transferId: Int64? = nil) {
        if let tid = transferId {
            guard let handle = activeTransfers[tid] else { return }
            if var s = transfers[tid] {
                s.status = .failed
                s.error  = "Bị huỷ bởi người dùng"
                emitTransfer(s)
            }
            handle.cancel()
            activeTransfers.removeValue(forKey: tid)
        } else {
            for (tid, handle) in activeTransfers {
                if var s = transfers[tid] {
                    s.status = .failed
                    s.error  = "Bị huỷ bởi người dùng"
                    emitTransfer(s)
                }
                handle.cancel()
            }
            activeTransfers.removeAll()
        }
    }

    // MARK: - Accept / Reject incoming request

    func acceptRequest(_ requestId: Int64) {
        pendingRequests.removeValue(forKey: requestId)?.resume(returning: true)
    }

    func cancelRequest(_ requestId: Int64) {
        pendingRequests.removeValue(forKey: requestId)?.resume(returning: false)
    }

    // MARK: - Bluetooth device management

    func clearBluetoothDevices() {
        deviceMap = deviceMap.filter { $0.value.from != .bluetooth }
        discoveredDevices = Array(deviceMap.values)
    }

    func addBluetoothDevice(_ device: TargetDevice) {
        let key = device.address ?? device.ipAddress
        deviceMap[key] = device
        discoveredDevices = Array(deviceMap.values)
    }

    // MARK: - UDP Advertise

    func startAdvertising() {
        guard !isAdvertising else { return }
        isAdvertising    = true
        udpAdvertiseTask?.cancel()
        udpAdvertiseTask = Task.detached { [weak self] in
            await self?.runUdpAdvertiseLoop()
        }
    }

    func stopAdvertising() {
        udpAdvertiseTask?.cancel()
        udpAdvertiseTask = nil
        isAdvertising    = false
    }

    private func runUdpAdvertiseLoop() async {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            await MainActor.run { self.isAdvertising = false }
            return
        }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr             = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = udpDiscoveryPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            await MainActor.run { self.isAdvertising = false }
            return
        }

        // recvfrom timeout = 1 s so we can check cancellation
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let deviceName = await MainActor.run { self.getDeviceName() }
        let pong       = "SUPERTRANSFER_PONG:\(deviceName):\(tcpTransferPort)"

        var buf        = [UInt8](repeating: 0, count: 1024)
        var senderAddr = sockaddr_in()
        var senderLen  = socklen_t(MemoryLayout<sockaddr_in>.size)

        while !Task.isCancelled {
            let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buf, buf.count, 0, sa, &senderLen)
                }
            }
            guard n > 0 else { continue }

            let msg = String(bytes: buf[0..<n], encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard msg.hasPrefix("SUPERTRANSFER_PING:") else { continue }

            var pongBytes = [UInt8](pong.utf8)
            withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, &pongBytes, pongBytes.count, 0, sa, senderLen)
                }
            }
        }
        await MainActor.run { self.isAdvertising = false }
    }

    // MARK: - WiFi Scan

    func startWifiScanning(timeoutMs: Int) {
        deviceMap      = deviceMap.filter { $0.value.from != .wifi }
        discoveredDevices = Array(deviceMap.values)
        isWifiScanning = true
        udpScanTask?.cancel()
        udpScanTask = Task.detached { [weak self] in
            await self?.runUdpScanLoop(timeoutMs: timeoutMs)
        }
    }

    func stopWifiScanning() {
        udpScanTask?.cancel()
        udpScanTask    = nil
        isWifiScanning = false
        deviceMap      = deviceMap.filter { $0.value.from != .wifi }
        discoveredDevices = Array(deviceMap.values)
    }

    private func runUdpScanLoop(timeoutMs: Int) async {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            await MainActor.run { self.isWifiScanning = false }
            return
        }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,  &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var tv = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let deadline   = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        let deviceName = await MainActor.run { self.getDeviceName() }
        let ping       = "SUPERTRANSFER_PING:\(deviceName)"

        // Receive task
        let receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            var buf        = [UInt8](repeating: 0, count: 1024)
            var senderAddr = sockaddr_in()
            var senderLen  = socklen_t(MemoryLayout<sockaddr_in>.size)

            while !Task.isCancelled, Date() < deadline {
                let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, &buf, buf.count, 0, sa, &senderLen)
                    }
                }
                guard n > 0 else { continue }

                let msg = String(bytes: buf[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard msg.hasPrefix("SUPERTRANSFER_PONG:") else { continue }

                let parts    = msg.split(separator: ":", maxSplits: 3,
                                         omittingEmptySubsequences: false)
                let peerName = parts.count > 1 ? String(parts[1]) : "Thiết bị"
                let peerPort = parts.count > 2 ? Int(parts[2]) ?? 9999 : 9999
                let peerIp   = String(cString: inet_ntoa(senderAddr.sin_addr))
                guard !peerIp.isEmpty, peerIp != "0.0.0.0" else { continue }

                let device = TargetDevice(name: peerName, ipAddress: peerIp,
                                          port: peerPort, from: .wifi)
                await MainActor.run {
                    self.deviceMap[peerIp] = device
                    self.discoveredDevices  = Array(self.deviceMap.values)
                }
            }
        }

        // Ping loop
        while !Task.isCancelled, Date() < deadline {
            var pingBytes = [UInt8](ping.utf8)

            // 255.255.255.255
            var bcast          = sockaddr_in()
            bcast.sin_family   = sa_family_t(AF_INET)
            bcast.sin_port     = udpDiscoveryPort.bigEndian
            bcast.sin_addr     = in_addr(s_addr: INADDR_BROADCAST)
            withUnsafePointer(to: &bcast) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, &pingBytes, pingBytes.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            // Subnet broadcast
            if var subnetAddr = getSubnetBroadcastAddress() {
                var sb          = sockaddr_in()
                sb.sin_family   = sa_family_t(AF_INET)
                sb.sin_port     = udpDiscoveryPort.bigEndian
                sb.sin_addr     = subnetAddr
                withUnsafePointer(to: &sb) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(sock, &pingBytes, pingBytes.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            // Dọn WiFi device cũ quá 6 s
            await MainActor.run {
                let now    = Date().timeIntervalSince1970
                let before = self.deviceMap.count
                self.deviceMap = self.deviceMap.filter { entry in
                    entry.value.from != .wifi || (now - entry.value.lastSeen) <= 6
                }
                if self.deviceMap.count != before {
                    self.discoveredDevices = Array(self.deviceMap.values)
                }
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        receiveTask.cancel()
        await MainActor.run { self.isWifiScanning = false }
    }

    private func getSubnetBroadcastAddress() -> in_addr? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let iface = ptr {
            let addr  = iface.pointee.ifa_addr.pointee
            let flags = Int32(iface.pointee.ifa_flags)
            if addr.sa_family == UInt8(AF_INET),
               (flags & IFF_LOOPBACK) == 0,
               (flags & IFF_UP) != 0,
               let netmaskPtr = iface.pointee.ifa_netmask {
                var ip = sockaddr_in()
                var nm = sockaddr_in()
                memcpy(&ip, iface.pointee.ifa_addr, MemoryLayout<sockaddr_in>.size)
                memcpy(&nm, netmaskPtr,             MemoryLayout<sockaddr_in>.size)
                let bcast = (ip.sin_addr.s_addr & nm.sin_addr.s_addr) | ~nm.sin_addr.s_addr
                return in_addr(s_addr: bcast)
            }
            ptr = iface.pointee.ifa_next
        }
        return nil
    }

    // MARK: - Bluetooth Scan (CoreBluetooth BLE — discovery only)
    //
    // iOS không hỗ trợ Bluetooth Classic RFCOMM.
    // Discovery qua BLE, transfer vẫn qua WiFi TCP dùng IP quảng bá trong advertisement.

    func startBluetoothScan(timeoutMs: Int) {
        clearBluetoothDevices()
        isBluetoothScanning = true
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        } else if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(withServices: [bleServiceUUID], options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
        }
        btScanTask?.cancel()
        btScanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            self.stopBluetoothScan()
        }
    }

    func stopBluetoothScan() {
        btScanTask?.cancel()
        btScanTask          = nil
        centralManager?.stopScan()
        isBluetoothScanning = false
    }

    func startBluetoothAdvertising() {
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        }
        // Advertising khởi động trong peripheralManagerDidUpdateState khi poweredOn
    }

    func stopBluetoothAdvertising() {
        peripheralManager?.stopAdvertising()
    }

    // MARK: - TCP Server

    func startTcpServer(onNotification: @escaping (String, String) -> Void) {
        stopTcpServer()
        isReceiving = true

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: tcpTransferPort)!
        ) else {
            isReceiving = false
            return
        }
        tcpListener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global(qos: .userInitiated))
            Task { await self.handleIncomingTcpConnection(conn, onNotification: onNotification) }
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[TransferEngine] TCP server ready on port \(self?.tcpTransferPort ?? 9999)")
            case .failed(let err):
                print("[TransferEngine] TCP server failed: \(err)")
                Task { @MainActor in self?.isReceiving = false }
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stopTcpServer() {
        tcpListener?.cancel()
        tcpListener = nil
        isReceiving = false
    }

    // MARK: - Incoming TCP connection dispatcher

    private func handleIncomingTcpConnection(
        _ conn: NWConnection,
        onNotification: @escaping (String, String) -> Void
    ) async {
        do {
            let msgTypeData = try await readExact(conn, length: 4)
            let msgType     = msgTypeData.toInt32BE()

            switch msgType {
            case MSG_TYPE_REQUEST:
                await handleIncomingRequest(conn, onNotification: onNotification)

            case MSG_TYPE_FILE:
                let transferId = Int64.random(in: Int64.min ... Int64.max)
                let handle     = TransferHandle(connection: conn)
                await MainActor.run { self.activeTransfers[transferId] = handle }
                await handleIncomingTransfer(
                    conn, transferId: transferId,
                    onNotification: onNotification,
                    onClose: { conn.cancel() }
                )

            default:
                print("[TransferEngine] Unknown msgType=\(msgType)")
                conn.cancel()
            }
        } catch {
            print("[TransferEngine] handleIncomingTcpConnection error: \(error)")
            conn.cancel()
        }
    }

    // MARK: - Handshake — receiver side

    private func handleIncomingRequest(
        _ conn: NWConnection,
        onNotification: @escaping (String, String) -> Void
    ) async {
        let requestId = Int64.random(in: 0 ... Int64.max)
        var accepted  = false

        do {
            let metaLenData = try await readExact(conn, length: 4)
            let metaLen     = Int(metaLenData.toInt32BE())
            guard metaLen > 0, metaLen < 1_048_576 else { throw TEError.invalidMetadata }

            let metaData = try await readExact(conn, length: metaLen)
            guard let metaStr = String(data: metaData, encoding: .utf8) else {
                throw TEError.invalidMetadata
            }
            let meta       = metaStr.split(separator: "|", omittingEmptySubsequences: false)
            let senderName = meta.count > 0 ? String(meta[0]) : "Thiết bị"
            let totalFiles = meta.count > 1 ? Int(meta[1]) ?? 1 : 1

            let senderIp = peerIP(from: conn)

            // Check BUSY
            let busy = await MainActor.run { self.activeReceiveCount > 0 }
            if busy {
                await MainActor.run {
                    self.incomingRequestSubject.send(
                        TargetDevice(name: senderName, ipAddress: senderIp,
                                     port: 9999, from: .wifi,
                                     isBusy: true, totalFiles: totalFiles,
                                     requestId: requestId)
                    )
                }
                try await sendHandshakeResponse(conn, code: RESPONSE_BUSY)
                conn.cancel()
                return
            }

            // Wait for user accept/reject
            accepted = await withCheckedContinuation { cont in
                Task { @MainActor in
                    self.pendingRequests[requestId] = cont
                    self.incomingRequestSubject.send(
                        TargetDevice(name: senderName, ipAddress: senderIp,
                                     port: 9999, from: .wifi,
                                     isBusy: false, totalFiles: totalFiles,
                                     requestId: requestId)
                    )
                    onNotification("Yêu cầu nhận file",
                                   "\(senderName) muốn gửi \(totalFiles) file")
                }
                // Auto-reject after timeout
                Task {
                    try? await Task.sleep(
                        nanoseconds: UInt64(self.requestTimeoutSec * 1_000_000_000))
                    await MainActor.run {
                        self.pendingRequests.removeValue(forKey: requestId)?
                            .resume(returning: false)
                    }
                }
            }
        } catch {
            print("[TransferEngine] handleIncomingRequest error: \(error)")
            accepted = false
        }

        do {
            try await sendHandshakeResponse(conn, code: accepted ? RESPONSE_ACCEPT : RESPONSE_REJECT)
        } catch {
            print("[TransferEngine] sendHandshakeResponse error: \(error)")
        }
        conn.cancel()
    }

    private func sendHandshakeResponse(_ conn: NWConnection, code: Int32) async throws {
        let data = Data(code.bigEndianBytes)
        try await tcpSend(conn, data: data)
    }

    // MARK: - Send to multiple devices

    func requestSendFileToMultiple(
        devices:          [TargetDevice],
        filePaths:        [String],
        senderName:       String,
        mode:             SendMode = .sequential,
        onEachFileDone:   @escaping (TargetDevice, String, Bool, String?) -> Void = { _, _, _, _ in },
        onEachDeviceDone: @escaping (TargetDevice, [String: Bool]) -> Void        = { _, _ in },
        onAllDone:        @escaping ([String: [String: Bool]]) -> Void            = { _ in }
    ) {
        Task {
            var allResults  = [String: [String: Bool]]()
            var readyToSend = [TargetDevice]()
            let wifiDevices = devices.filter { $0.from == .wifi }
            let btDevices   = devices.filter { $0.from == .bluetooth }

            // PHASE 1: Handshake WiFi devices in parallel
            await withTaskGroup(of: (TargetDevice, Bool, Bool).self) { group in
                for device in wifiDevices {
                    group.addTask {
                        let (accepted, isBusy) = await self.wifiHandshake(
                            device: device, senderName: senderName,
                            totalFiles: filePaths.count)
                        await MainActor.run {
                            self.sendRequestResultSubject.send(
                                SendRequestResult(device: device,
                                                  accepted: accepted,
                                                  isBusy: isBusy))
                        }
                        return (device, accepted, isBusy)
                    }
                }
                for await (device, accepted, isBusy) in group {
                    if accepted {
                        readyToSend.append(device)
                    } else {
                        let reason  = isBusy
                            ? "Thiết bị đang bận nhận file từ người khác"
                            : "Thiết bị từ chối yêu cầu"
                        let results = Dictionary(
                            uniqueKeysWithValues: filePaths.map { ($0, false) })
                        allResults[device.id] = results
                        results.forEach { fp, _ in
                            onEachFileDone(device, fp, false, reason)
                        }
                        onEachDeviceDone(device, results)
                    }
                }
            }

            // BT devices skip handshake — transfer via TCP with discovered IP
            readyToSend.append(contentsOf: btDevices)

            // PHASE 2: Send files
            switch mode {
            case .sequential:
                for device in readyToSend {
                    let results = await self.sendFilesToDevice(
                        device: device, filePaths: filePaths,
                        senderName: senderName, onEachFileDone: onEachFileDone)
                    allResults[device.id] = results
                    onEachDeviceDone(device, results)
                }

            case .parallel:
                await withTaskGroup(of: (String, [String: Bool]).self) { group in
                    for device in readyToSend {
                        group.addTask {
                            let results = await self.sendFilesToDevice(
                                device: device, filePaths: filePaths,
                                senderName: senderName, onEachFileDone: onEachFileDone)
                            onEachDeviceDone(device, results)
                            return (device.id, results)
                        }
                    }
                    for await (id, results) in group {
                        allResults[id] = results
                    }
                }
            }

            onAllDone(allResults)
        }
    }

    // MARK: - WiFi Handshake (private)

    private func wifiHandshake(
        device:     TargetDevice,
        senderName: String,
        totalFiles: Int
    ) async -> (accepted: Bool, isBusy: Bool) {
        let conn = NWConnection(
            host: NWEndpoint.Host(device.ipAddress),
            port: NWEndpoint.Port(rawValue: UInt16(device.port))!,
            using: .tcp)
        do {
            try await tcpConnect(conn, timeoutSec: 10)

            let meta    = "\(senderName)|\(totalFiles)".data(using: .utf8)!
            var payload = Data(MSG_TYPE_REQUEST.bigEndianBytes)
            payload    += Data(Int32(meta.count).bigEndianBytes)
            payload    += meta
            try await tcpSend(conn, data: payload)

            let responseData = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await self.readExact(conn, length: 4) }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64((self.requestTimeoutSec + 5) * 1_000_000_000))
                    throw TEError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            conn.cancel()
            switch responseData.toInt32BE() {
            case RESPONSE_ACCEPT: return (true,  false)
            case RESPONSE_BUSY:   return (false, true)
            default:              return (false, false)
            }
        } catch {
            print("[TransferEngine] wifiHandshake error (\(device.name)): \(error)")
            conn.cancel()
            return (false, false)
        }
    }

    // MARK: - Send files to one device

    private func sendFilesToDevice(
        device:         TargetDevice,
        filePaths:      [String],
        senderName:     String,
        onEachFileDone: @escaping (TargetDevice, String, Bool, String?) -> Void
    ) async -> [String: Bool] {
        var results    = [String: Bool]()
        let totalFiles = filePaths.count
        for (index, filePath) in filePaths.enumerated() {
            let transferId      = Int64.random(in: Int64.min ... Int64.max)
            let (ok, errMsg)    = await sendFileSingleTcp(
                device: device, filePath: filePath, senderName: senderName,
                transferId: transferId, fileIndex: index, totalFiles: totalFiles)
            results[filePath] = ok
            onEachFileDone(device, filePath, ok, errMsg)
        }
        return results
    }

    // MARK: - Send single file via TCP

    private func sendFileSingleTcp(
        device:     TargetDevice,
        filePath:   String,
        senderName: String,
        transferId: Int64,
        fileIndex:  Int,
        totalFiles: Int
    ) async -> (success: Bool, error: String?) {
        let conn   = NWConnection(
            host: NWEndpoint.Host(device.ipAddress),
            port: NWEndpoint.Port(rawValue: UInt16(device.port))!,
            using: .tcp)
        let handle = TransferHandle(connection: conn)
        await MainActor.run { self.activeTransfers[transferId] = handle }

        var state        = TransferState(id: transferId)
        state.isIncoming = false
        state.peerName   = device.name
        state.status     = .connecting
        await MainActor.run { self.emitTransfer(state) }

        do {
            let url      = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw TEError.fileNotFound(filePath)
            }
            let attrs    = try FileManager.default.attributesOfItem(atPath: filePath)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            let fileName = url.lastPathComponent

            state.fileName   = fileName
            state.totalBytes = fileSize
            await MainActor.run { self.emitTransfer(state) }

            try await tcpConnect(conn, timeoutSec: 10)
            state.status = .transferring
            await MainActor.run { self.emitTransfer(state) }

            let metaStr  = "\(fileName)|\(fileSize)|\(senderName)|\(fileIndex)|\(totalFiles)"
            let metaData = metaStr.data(using: .utf8)!
            var header   = Data(MSG_TYPE_FILE.bigEndianBytes)
            header      += Data(Int32(metaData.count).bigEndianBytes)
            header      += metaData
            try await tcpSend(conn, data: header)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }

            var totalSent:       Int64 = 0
            var sinceLastUpdate: Int64 = 0
            var lastUpdate             = Date()

            while true {
                // Check cancellation
                let cancelled = await MainActor.run { self.activeTransfers[transferId] == nil }
                if cancelled { throw TEError.cancelled }

                let chunk = fileHandle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }

                try await tcpSend(conn, data: chunk)
                totalSent         += Int64(chunk.count)
                sinceLastUpdate   += Int64(chunk.count)

                let now   = Date()
                let delta = now.timeIntervalSince(lastUpdate)
                if delta >= 0.5 || totalSent == fileSize {
                    let progress = fileSize > 0 ? Int(totalSent * 100 / fileSize) : 0
                    let speed    = delta > 0
                        ? Double(sinceLastUpdate) / 1_048_576.0 / delta : 0.0
                    var s            = state
                    s.bytesTransferred = totalSent
                    s.progress         = progress
                    s.speedMbps        = speed
                    state              = s
                    await MainActor.run { self.emitTransfer(s) }
                    lastUpdate      = now
                    sinceLastUpdate = 0
                }
            }

            state.status   = .success
            state.progress = 100
            await MainActor.run {
                self.emitTransfer(state)
                self.activeTransfers.removeValue(forKey: transferId)
            }
            conn.cancel()
            scheduleRemoveTransfer(transferId)
            return (true, nil)

        } catch {
            state.status = .failed
            state.error  = error.localizedDescription
            await MainActor.run {
                self.emitTransfer(state)
                self.activeTransfers.removeValue(forKey: transferId)
            }
            conn.cancel()
            scheduleRemoveTransfer(transferId)
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Incoming Transfer (receive file)

    private func handleIncomingTransfer(
        _ conn:          NWConnection,
        transferId:      Int64,
        onNotification:  @escaping (String, String) -> Void,
        onClose:         @escaping () -> Void
    ) async {
        await MainActor.run { self.activeReceiveCount += 1 }

        var state    = TransferState(id: transferId)
        var destURL: URL?

        do {
            let metaLenData = try await readExact(conn, length: 4)
            let metaLen     = Int(metaLenData.toInt32BE())
            guard metaLen > 0, metaLen < 1_048_576 else { throw TEError.invalidMetadata }

            let metaData = try await readExact(conn, length: metaLen)
            guard let metaStr = String(data: metaData, encoding: .utf8) else {
                throw TEError.invalidMetadata
            }
            let parts      = metaStr.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { throw TEError.invalidMetadata }

            let fileName   = String(parts[0])
            let fileSize   = Int64(parts[1]) ?? 0
            let senderName = String(parts[2])
            let fileIndex  = parts.count > 3 ? Int(parts[3]) ?? 0 : 0
            let totalFiles = parts.count > 4 ? Int(parts[4]) ?? 1 : 1

            print("[TransferEngine] Nhận [\(fileIndex+1)/\(totalFiles)] \(fileName) (\(fileSize)B) từ \(senderName)")
            onNotification("Đang nhận file", "\(senderName) gửi: \(fileName)")

            state.fileName   = fileName
            state.totalBytes = fileSize
            state.peerName   = senderName
            state.isIncoming = true
            state.status     = .transferring
            await MainActor.run { self.emitTransfer(state) }

            let url      = try prepareDestinationFile(fileName: fileName)
            destURL      = url
            let fh       = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }

            var totalRead:       Int64 = 0
            var sinceLastUpdate: Int64 = 0
            var lastUpdate             = Date()

            while totalRead < fileSize {
                let toRead = Int(min(Int64(bufferSize), fileSize - totalRead))
                let chunk  = try await readExact(conn, length: toRead)
                
                try fh.write(contentsOf: chunk)
                totalRead         += Int64(chunk.count)
                sinceLastUpdate   += Int64(chunk.count)

                let now   = Date()
                let delta = now.timeIntervalSince(lastUpdate)
                if delta >= 0.5 || totalRead == fileSize {
                    let progress = fileSize > 0 ? Int(totalRead * 100 / fileSize) : 0
                    let speed    = delta > 0
                        ? Double(sinceLastUpdate) / 1_048_576.0 / delta : 0.0
                    var s            = state
                    s.bytesTransferred = totalRead
                    s.progress         = progress
                    s.speedMbps        = speed
                    state              = s
                    await MainActor.run { self.emitTransfer(s) }
                    lastUpdate      = now
                    sinceLastUpdate = 0
                }
            }

            guard totalRead >= fileSize else { throw TEError.streamInterrupted }

            saveToMediaLibraryIfNeeded(url: url)
            state.status   = .success
            state.progress = 100
            await MainActor.run { self.emitTransfer(state) }
            onNotification("Nhận file thành công",
                           "Đã nhận \(fileName) từ \(senderName)")

        } catch {
            print("[TransferEngine] handleIncomingTransfer error: \(error)")
            state.status = .failed
            state.error  = error.localizedDescription
            await MainActor.run { self.emitTransfer(state) }
            if let url = destURL {
                try? FileManager.default.removeItem(at: url)
            }
            onNotification("Lỗi nhận file", "Lỗi khi nhận file")
        }

        await MainActor.run {
            self.activeReceiveCount -= 1
            self.activeTransfers.removeValue(forKey: transferId)
        }
        onClose()
        scheduleRemoveTransfer(transferId)
    }

    // MARK: - File helpers

    private func prepareDestinationFile(fileName: String) throws -> URL {
        let dir = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("SuperTransfer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        var url = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext  = url.pathExtension
            var n    = 1
            repeat {
                url = dir.appendingPathComponent(
                    ext.isEmpty ? "\(base)(\(n))" : "\(base)(\(n)).\(ext)")
                n += 1
            } while FileManager.default.fileExists(atPath: url.path)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    @available(iOS 14, *)
    private func saveToMediaLibraryIfNeeded(url: URL) {
        let ext     = url.pathExtension.lowercased()
        let isImage = ["jpg","jpeg","png","gif","webp","bmp"].contains(ext)
        let isVideo = ["mp4","mkv","mov","3gp","webm","avi"].contains(ext)
        guard isImage || isVideo else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if isImage {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }) { ok, err in
                if ok { print("[TransferEngine] Saved to Photos: \(url.lastPathComponent)") }
                else if let e = err { print("[TransferEngine] Photos error: \(e)") }
            }
        }
    }

    // MARK: - Low-level TCP I/O

    private func tcpConnect(_ conn: NWConnection, timeoutSec: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            cont.resume()
                        case .failed(let err):
                            cont.resume(throwing: err)
                        case .cancelled:
                            cont.resume(throwing: TEError.cancelled)
                        default:
                            break
                        }
                    }
                    conn.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw TEError.timeout
            }
            // Wait for the first task to finish (ready or error)
            try await group.next()
            group.cancelAll()
        }
    }

    private func tcpSend(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let e = error { cont.resume(throwing: e) }
                else             { cont.resume() }
            })
        }
    }

    private func readExact(_ conn: NWConnection, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: length,
                         maximumLength: length) { data, _, _, error in
                if let e = error {
                    cont.resume(throwing: e)
                } else if let d = data, d.count >= length {
                    cont.resume(returning: d)
                } else {
                    cont.resume(throwing: TEError.streamInterrupted)
                }
            }
        }
    }

    // MARK: - Utility

    private func peerIP(from conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint {
            switch host {
            case .ipv4(let addr):
                return "\(addr)"
            case .name(let s, _):
                return s
            default:
                return ""
            }
        }
        return ""
    }
}

// MARK: - CBCentralManagerDelegate

@available(iOS 14, *)
extension TransferEngine: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        Task { @MainActor in
            guard self.isBluetoothScanning else { return }
            central.scanForPeripherals(withServices: [self.bleServiceUUID], options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
        }
    }

    // ManufacturerData format: [0xFF, 0xFF] + UTF-8 IP bytes
    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        var peerIP   = ""
        var peerName = peripheral.name ?? "Thiết bị"

        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfgData.count > 2 {
            let ipBytes = mfgData.dropFirst(2).prefix(while: { $0 != 0 })
            if let ipStr = String(data: ipBytes, encoding: .utf8),
               ipStr.filter({ $0 == "." }).count == 3 {
                peerIP = ipStr
            }
        }
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            peerName = localName
        }
        guard !peerIP.isEmpty else { return }

        let device = TargetDevice(
            name: peerName, ipAddress: peerIP,
            port: 9999, from: .bluetooth,
            address: peripheral.identifier.uuidString)
        Task { @MainActor in self.addBluetoothDevice(device) }
    }
}

// MARK: - CBPeripheralManagerDelegate

@available(iOS 14, *)
extension TransferEngine: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        Task { @MainActor in
            let ip = self.getLocalIpAddress()
            guard ip != "127.0.0.1" else { return }

            // ManufacturerData: company ID [0xFF, 0xFF] + UTF-8 IP
            var mfgBytes: [UInt8] = [0xFF, 0xFF]
            mfgBytes += [UInt8](ip.utf8)
            let mfgData = Data(mfgBytes)

            let advData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey : [self.bleServiceUUID],
                CBAdvertisementDataLocalNameKey    : self.getDeviceName(),
                // Note: iOS strips ManufacturerData on real devices (only works in simulator).
                // The LocalName + ServiceUUID allow the other side to initiate a prompt.
            ]
            _ = mfgData  // suppress unused warning; used in simulator path
            peripheral.startAdvertising(advData)
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService, error: Error?) {}

    nonisolated func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager, error: Error?) {
        if let e = error { print("[TransferEngine] BLE advertise error: \(e)") }
        else             { print("[TransferEngine] BLE advertising started") }
    }
}

// MARK: - TEError

enum TEError: Error, LocalizedError {
    case invalidMetadata
    case fileNotFound(String)
    case streamInterrupted
    case cancelled
    case timeout
    case bluetoothUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidMetadata:      return "Metadata không hợp lệ"
        case .fileNotFound(let p):  return "File không tồn tại: \(p)"
        case .streamInterrupted:    return "Luồng dữ liệu bị gián đoạn"
        case .cancelled:            return "Đã huỷ"
        case .timeout:              return "Hết thời gian chờ"
        case .bluetoothUnavailable: return "Bluetooth không khả dụng"
        }
    }
}

// MARK: - Data / Int32 extensions  (Big-endian, tương thích Java DataOutputStream)

extension Int32 {
    var bigEndianBytes: [UInt8] {
        let v = self.bigEndian
        return [
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >>  8) & 0xFF),
            UInt8( v        & 0xFF),
        ]
    }
}

extension Data {
    func toInt32BE() -> Int32 {
        guard count >= 4 else { return 0 }
        return Int32(bitPattern:
            (UInt32(self[0]) << 24) |
            (UInt32(self[1]) << 16) |
            (UInt32(self[2]) <<  8) |
             UInt32(self[3]))
    }
}
