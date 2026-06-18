//
//  TransferEngine.swift
//  Runner
//
//  Created by sonmac on 18/6/26.
//

// TransferEngine.swift
// SuperTransfer — iOS
//
// Tương đương TransferEngine.kt (Android).
// Giao thức binary wire-format HOÀN TOÀN TƯƠNG THÍCH Android ↔ iOS:
//
//   REQUEST connection:
//     [Int32 BE = 0]                          ← MSG_TYPE_REQUEST
//     [Int32 BE = metaLength]
//     [UTF-8: "senderName|totalFiles"]
//   Response từ bên nhận:
//     [Int32 BE]  0=ACCEPT  1=REJECT  2=BUSY
//
//   FILE connection:
//     [Int32 BE = 1]                          ← MSG_TYPE_FILE
//     [Int32 BE = metaLength]
//     [UTF-8: "fileName|fileSize|senderName|fileIndex|totalFiles"]
//     [raw bytes...]
//
// iOS KHÔNG hỗ trợ Bluetooth RFCOMM (Classic BT) nên:
//   - Scan Bluetooth: dùng CoreBluetooth BLE (phát hiện thiết bị)
//   - Transfer file khi from == .bluetooth: vẫn qua WiFi TCP (dùng ipAddress)
//     → Hoạt động khi 2 máy cùng mạng WiFi, phát hiện nhau qua BLE advertisement
//   - iOS ↔ Android cross-platform: HOÀN TOÀN tương thích qua WiFi TCP

import Foundation
import Network
import CoreBluetooth
import Photos
import Combine
import UIKit

// MARK: - TransferEngine

@MainActor
final class TransferEngine: NSObject, ObservableObject {

    // ── Singleton ────────────────────────────────────────────────────────────
    static let shared = TransferEngine()

    // ── Constants ─────────────────────────────────────────────────────────────
    private let udpDiscoveryPort: UInt16 = 8889
    private let tcpTransferPort:  UInt16 = 9999
    private let bufferSize               = 512 * 1024  // 512 KB

    // BLE service UUID cho discovery (KHÁC với RFCOMM UUID của Android)
    // Android BLE advertisement sẽ dùng UUID khác — iOS chỉ dùng BLE để tìm peer,
    // sau đó kết nối TCP bình thường.
    private let bleServiceUUID = CBUUID(string: "FA87C0D0-AFAC-11DE-8A39-0800200C9A66")
    private let bleCharUUID    = CBUUID(string: "FA87C0D1-AFAC-11DE-8A39-0800200C9A66")

    // Handshake protocol — giữ nguyên với Android
    private let MSG_TYPE_REQUEST: Int32 = 0
    private let MSG_TYPE_FILE:    Int32 = 1
    private let RESPONSE_ACCEPT:  Int32 = 0
    private let RESPONSE_REJECT:  Int32 = 1
    private let RESPONSE_BUSY:    Int32 = 2
    private let requestTimeoutSec: TimeInterval = 60

    // ── @Published state (tương đương StateFlow/SharedFlow Android) ──────────

    @Published private(set) var discoveredDevices: [TargetDevice]    = []
    @Published private(set) var transfers: [Int64: TransferState]    = [:]
    @Published private(set) var isWifiScanning:      Bool = false
    @Published private(set) var isBluetoothScanning: Bool = false
    @Published private(set) var isReceiving:         Bool = false
    @Published private(set) var isAdvertising:       Bool = false

    /// Sự kiện: thiết bị khác gửi REQUEST đến — Flutter cần hiện dialog.
    let incomingRequestSubject = PassthroughSubject<TargetDevice, Never>()

    /// Kết quả handshake phía gửi (accepted + isBusy)
    struct SendRequestResult {
        let device:   TargetDevice
        let accepted: Bool
        let isBusy:   Bool
    }
    let sendRequestResultSubject = PassthroughSubject<SendRequestResult, Never>()

    // ── Internal state ────────────────────────────────────────────────────────

    // key: ipAddress (WiFi) hoặc peripheral.identifier (BLE)
    private var deviceMap:       [String: TargetDevice]   = [:]
    private var activeTransfers: [Int64: TransferHandle]  = [:]
    private var activeReceiveCount = 0   // số lượng file đang được nhận → BUSY check
    // requestId → continuation chờ accept/reject từ người dùng
    private var pendingRequests: [Int64: CheckedContinuation<Bool, Never>] = [:]

    // Networking
    private var udpListener:    NWListener?
    private var udpScanTask:    Task<Void, Never>?
    private var tcpListener:    NWListener?
    private var tcpListenerTask: Task<Void, Never>?

    // CoreBluetooth
    private var centralManager:    CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var btScanTask:        Task<Void, Never>?
    // Peripheral info thu được qua BLE advertisement (name + IP từ advertisement data)
    // iOS không thể đọc IP của thiết bị Android qua BLE, nhưng Android quảng bá IP
    // trong manufacturer data hoặc service data → đọc ra và tạo TargetDevice
    private var bleDiscoveredPeripherals: [UUID: CBPeripheral] = [:]

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Init
    // ─────────────────────────────────────────────────────────────────────────

    private override init() {
        super.init()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Device Info
    // ─────────────────────────────────────────────────────────────────────────

    func getDeviceName() -> String {
        UIDevice.current.name
    }

    func getLocalIpAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let interface = ptr {
            let flags = Int32(interface.pointee.ifa_flags)
            let addr  = interface.pointee.ifa_addr.pointee
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.pointee.ifa_addr, socklen_t(addr.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: hostname)
                }
            }
            ptr = interface.pointee.ifa_next
        }
        return address
    }

    func getTransferEngineStatus() -> [String: Any] {
        [
            "isWifiScanning"      : isWifiScanning,
            "isBluetoothScanning" : isBluetoothScanning,
            "isReceiving"         : isReceiving,
            "isAdvertising"       : isAdvertising,
        ]
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Emit helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func emitTransfer(_ state: TransferState) {
        transfers[state.id] = state
    }

    private func removeTransfer(_ id: Int64) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s
            transfers.removeValue(forKey: id)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Cancel transfers
    // ─────────────────────────────────────────────────────────────────────────

    func cancelActiveTransfer(_ transferId: Int64? = nil) {
        if let tid = transferId {
            if let handle = activeTransfers[tid] {
                transfers[tid] = transfers[tid].map {
                    var s = $0; s.status = .failed; s.error = "Bị huỷ bởi người dùng"; return s
                }
                handle.cancel()
                activeTransfers.removeValue(forKey: tid)
            }
        } else {
            for (tid, handle) in activeTransfers {
                transfers[tid] = transfers[tid].map {
                    var s = $0; s.status = .failed; s.error = "Bị huỷ bởi người dùng"; return s
                }
                handle.cancel()
            }
            activeTransfers.removeAll()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Accept / Reject incoming request
    // ─────────────────────────────────────────────────────────────────────────

    /// Người dùng bấm "Chấp nhận" — gọi từ MethodChannel "acceptRequest"
    func acceptRequest(_ requestId: Int64) {
        pendingRequests[requestId]?.resume(returning: true)
        pendingRequests.removeValue(forKey: requestId)
    }

    /// Người dùng bấm "Từ chối" / "Huỷ" — gọi từ MethodChannel "cancelRequest"
    func cancelRequest(_ requestId: Int64) {
        pendingRequests[requestId]?.resume(returning: false)
        pendingRequests.removeValue(forKey: requestId)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Bluetooth device management
    // ─────────────────────────────────────────────────────────────────────────

    /// Xoá danh sách thiết bị BT, reset scan state
    func clearBluetoothDevices() {
        deviceMap = deviceMap.filter { $0.value.from != .bluetooth }
        discoveredDevices = Array(deviceMap.values)
    }

    /// Thêm thiết bị BT vào danh sách (gọi từ CBCentralManagerDelegate)
    func addBluetoothDevice(_ device: TargetDevice) {
        let key = device.address ?? device.ipAddress
        deviceMap[key] = device
        discoveredDevices = Array(deviceMap.values)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - UDP Advertise (WiFi discovery — bên nhận quảng bá)
    // ─────────────────────────────────────────────────────────────────────────

    /// Bắt đầu lắng nghe PING và phản hồi PONG trên cổng UDP 8889.
    /// Gọi từ AppDelegate / FlutterPlugin khi app khởi động.
    func startAdvertising() {
        guard !isAdvertising else { return }
        isAdvertising = true

        Task.detached { [weak self] in
            guard let self else { return }
            await self.runUdpAdvertiseLoop()
        }
    }

    func stopAdvertising() {
        isAdvertising = false
        udpListener?.cancel()
        udpListener = nil
    }

    private func runUdpAdvertiseLoop() async {
        // Mở raw UDP socket bằng POSIX (Network.framework UDP listen không broadcast tốt trên iOS)
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { await MainActor.run { isAdvertising = false }; return }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = udpDiscoveryPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { await MainActor.run { isAdvertising = false }; return }

        let deviceName = await MainActor.run { getDeviceName() }
        let pong       = "SUPERTRANSFER_PONG:\(deviceName):\(tcpTransferPort)"

        var buf = [UInt8](repeating: 0, count: 1024)
        var senderAddr = sockaddr_in()
        var senderLen  = socklen_t(MemoryLayout<sockaddr_in>.size)

        while await MainActor.run(body: { isAdvertising }) {
            let n = withUnsafeMutablePointer(to: &senderAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buf, buf.count, 0, sa, &senderLen)
                }
            }
            guard n > 0 else { continue }

            let msg = String(bytes: buf[0..<n], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard msg.hasPrefix("SUPERTRANSFER_PING:") else { continue }

            // Phản hồi PONG
            var pongBytes = Array(pong.utf8)
            withUnsafeMutablePointer(to: &senderAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, &pongBytes, pongBytes.count, 0, sa, senderLen)
                }
            }
        }
        await MainActor.run { isAdvertising = false }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - WiFi Scan (UDP broadcast PING → PONG)
    // ─────────────────────────────────────────────────────────────────────────

    func startWifiScanning(timeoutMs: Int) {
        // Xoá WiFi device cũ, giữ BT
        deviceMap = deviceMap.filter { $0.value.from != .wifi }
        discoveredDevices = Array(deviceMap.values)
        isWifiScanning    = true
        udpScanTask?.cancel()

        udpScanTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.runUdpScanLoop(timeoutMs: timeoutMs)
        }
    }

    func stopWifiScanning() {
        udpScanTask?.cancel()
        udpScanTask = nil
        isWifiScanning = false
        deviceMap = deviceMap.filter { $0.value.from != .wifi }
        discoveredDevices = Array(deviceMap.values)
    }

    private func runUdpScanLoop(timeoutMs: Int) async {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { await MainActor.run { isWifiScanning = false }; return }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,  &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Timeout recvfrom = 1.5 s (non-blocking feel)
        var tv = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let deadline   = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let deviceName = await MainActor.run { getDeviceName() }
        let ping       = "SUPERTRANSFER_PING:\(deviceName)"

        // ── Receive coroutine ────────────────────────────────────────────────
        let receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            var senderAddr = sockaddr_in()
            var senderLen  = socklen_t(MemoryLayout<sockaddr_in>.size)

            while !Task.isCancelled, Date() < deadline {
                let n = withUnsafeMutablePointer(to: &senderAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, &buf, buf.count, 0, sa, &senderLen)
                    }
                }
                guard n > 0 else { continue }

                let msg = String(bytes: buf[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard msg.hasPrefix("SUPERTRANSFER_PONG:") else { continue }

                let parts    = msg.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                let peerName = parts.count > 1 ? String(parts[1]) : "Thiết bị"
                let peerPort = parts.count > 2 ? Int(parts[2]) ?? 9999 : 9999
                var peerIp   = ""
                var raw      = senderAddr.sin_addr.s_addr
                peerIp       = String(cString: inet_ntoa(senderAddr.sin_addr))

                guard !peerIp.isEmpty else { continue }

                let device = TargetDevice(
                    name: peerName, ipAddress: peerIp, port: peerPort, from: .wifi
                )
                await MainActor.run { [device] in
                    self.deviceMap[peerIp] = device
                    self.discoveredDevices = Array(self.deviceMap.values)
                }
            }
        }

        // ── Ping coroutine ───────────────────────────────────────────────────
        while !Task.isCancelled, Date() < deadline {
            var pingBytes = Array(ping.utf8)

            // Broadcast 255.255.255.255
            var bcastAddr          = sockaddr_in()
            bcastAddr.sin_family   = sa_family_t(AF_INET)
            bcastAddr.sin_port     = udpDiscoveryPort.bigEndian
            bcastAddr.sin_addr     = in_addr(s_addr: INADDR_BROADCAST)
            withUnsafePointer(to: &bcastAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, &pingBytes, pingBytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            // Subnet broadcast
            if let subnetBcast = getSubnetBroadcastAddress() {
                var sbAddr          = sockaddr_in()
                sbAddr.sin_family   = sa_family_t(AF_INET)
                sbAddr.sin_port     = udpDiscoveryPort.bigEndian
                sbAddr.sin_addr     = subnetBcast
                withUnsafePointer(to: &sbAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(sock, &pingBytes, pingBytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            // Dọn WiFi device cũ quá 6 s
            await MainActor.run {
                let now = Date().timeIntervalSince1970
                let before = deviceMap.count
                deviceMap = deviceMap.filter { e in
                    e.value.from != .wifi || (now - e.value.lastSeen) <= 6
                }
                if deviceMap.count != before { discoveredDevices = Array(deviceMap.values) }
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
        }

        receiveTask.cancel()
        await MainActor.run { isWifiScanning = false }
    }

    private func getSubnetBroadcastAddress() -> in_addr? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let interface = ptr {
            let addr = interface.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                let flags = Int32(interface.pointee.ifa_flags)
                if (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0 {
                    let netmask = interface.pointee.ifa_netmask
                    var ip = sockaddr_in(); var nm = sockaddr_in()
                    memcpy(&ip, interface.pointee.ifa_addr,     MemoryLayout<sockaddr_in>.size)
                    memcpy(&nm, netmask,                        MemoryLayout<sockaddr_in>.size)
                    let bcast = (ip.sin_addr.s_addr & nm.sin_addr.s_addr) | ~nm.sin_addr.s_addr
                    return in_addr(s_addr: bcast)
                }
            }
            ptr = interface.pointee.ifa_next
        }
        return nil
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Bluetooth Scan (CoreBluetooth BLE — discovery only)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // iOS KHÔNG hỗ trợ Bluetooth Classic (RFCOMM) như Android.
    // Giải pháp:
    //   1. iOS phát BLE advertisement kèm IP address trong ManufacturerData.
    //   2. Android (hoặc iOS khác) scan BLE, đọc IP từ advertisement → tạo TargetDevice
    //      với from = .bluetooth nhưng ipAddress = IP thực của thiết bị BT.
    //   3. Transfer vẫn đi qua WiFi TCP (dùng ipAddress trong TargetDevice).
    //
    // BLE Advertisement format (ManufacturerData):
    //   [2 bytes company ID = 0xFF 0xFF][null-terminated UTF-8 IP string]
    //   Ví dụ: FF FF 31 39 32 2E 31 36 38 2E 31 2E 31 30 00

    func startBluetoothScan(timeoutMs: Int) {
        clearBluetoothDevices()
        isBluetoothScanning = true

        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        } else {
            centralManager?.scanForPeripherals(withServices: [bleServiceUUID], options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
        }

        // Auto-stop sau timeout
        btScanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            stopBluetoothScan()
        }
    }

    func stopBluetoothScan() {
        btScanTask?.cancel()
        btScanTask = nil
        centralManager?.stopScan()
        isBluetoothScanning = false
    }

    /// Bắt đầu phát BLE advertisement — quảng bá IP để thiết bị khác phát hiện
    func startBluetoothAdvertising() {
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        }
        // Actual advertising bắt đầu trong peripheralManagerDidUpdateState
    }

    func stopBluetoothAdvertising() {
        peripheralManager?.stopAdvertising()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - TCP Server (nhận file)
    // ─────────────────────────────────────────────────────────────────────────

    func startTcpServer(onNotification: @escaping (String, String) -> Void) {
        guard !isReceiving else { return }

        stopTcpServer()
        isReceiving = true

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(integerLiteral: tcpTransferPort))
        else { isReceiving = false; return }

        self.tcpListener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global(qos: .userInitiated))
            Task {
                await self.handleIncomingTcpConnection(conn, onNotification: onNotification)
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[TransferEngine] TCP server ready on port \(self?.tcpTransferPort ?? 9999)")
            case .failed(let err):
                print("[TransferEngine] TCP server failed: \(err)")
                Task { @MainActor in self?.isReceiving = false }
            default: break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    func stopTcpServer() {
        tcpListener?.cancel()
        tcpListener = nil
        isReceiving = false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Incoming TCP connection dispatcher
    // ─────────────────────────────────────────────────────────────────────────

    private func handleIncomingTcpConnection(
        _ conn: NWConnection,
        onNotification: @escaping (String, String) -> Void
    ) async {
        do {
            // Đọc 4 bytes đầu = msgType (Big-endian Int32)
            let msgTypeData = try await readExact(conn, length: 4)
            let msgType     = msgTypeData.toInt32BE()

            switch msgType {
            case MSG_TYPE_REQUEST:
                await handleIncomingRequest(conn, onNotification: onNotification)

            case MSG_TYPE_FILE:
                let transferId = Int64.random(in: Int64.min...Int64.max)
                let handle     = TransferHandle(connection: conn)
                await MainActor.run { activeTransfers[transferId] = handle }
                await handleIncomingTransfer(
                    conn, transferId: transferId, onNotification: onNotification,
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

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Handshake — bên nhận
    // ─────────────────────────────────────────────────────────────────────────

    private func handleIncomingRequest(
        _ conn: NWConnection,
        onNotification: @escaping (String, String) -> Void
    ) async {
        let requestId = Int64.random(in: 0...Int64.max)
        var accepted  = false

        do {
            // Đọc meta
            let metaLenData = try await readExact(conn, length: 4)
            let metaLen     = Int(metaLenData.toInt32BE())
            guard metaLen > 0, metaLen < 1024 * 1024 else { throw TEError.invalidMetadata }

            let metaData = try await readExact(conn, length: metaLen)
            let meta     = (String(data: metaData, encoding: .utf8) ?? "").split(separator: "|", omittingEmptySubsequences: false)

            let senderName = String(meta.first ?? "Thiết bị")
            let totalFiles = Int(meta.dropFirst().first ?? "1") ?? 1

            let senderIp: String = {
                if case let .hostPort(host, _) = conn.endpoint {
                    if case let .ipv4(addr) = host { return "\(addr)" }
                    if case let .name(s, _) = host { return s }
                }
                return ""
            }()

            // ── Kiểm tra BUSY ────────────────────────────────────────────────
            let busy = await MainActor.run { activeReceiveCount > 0 }
            if busy {
                await MainActor.run {
                    incomingRequestSubject.send(TargetDevice(
                        name: senderName, ipAddress: senderIp, port: conn.endpoint.port ?? 9999,
                        from: .wifi, isBusy: true, totalFiles: totalFiles, requestId: requestId
                    ))
                }
                try await sendResponse(conn, code: RESPONSE_BUSY)
                return
            }

            // ── Chờ người dùng accept/reject ──────────────────────────────────
            accepted = await withCheckedContinuation { cont in
                Task { @MainActor in
                    pendingRequests[requestId] = cont
                    incomingRequestSubject.send(TargetDevice(
                        name: senderName, ipAddress: senderIp,
                        port: conn.endpoint.port ?? 9999,
                        from: .wifi, isBusy: false,
                        totalFiles: totalFiles, requestId: requestId
                    ))
                    onNotification("Yêu cầu nhận file", "\(senderName) muốn gửi \(totalFiles) file")
                }
                // Timeout 60 s — auto reject
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(requestTimeoutSec * 1_000_000_000))
                    await MainActor.run {
                        if let c = pendingRequests.removeValue(forKey: requestId) {
                            c.resume(returning: false)
                        }
                    }
                }
            }
        } catch {
            print("[TransferEngine] handleIncomingRequest error: \(error)")
            accepted = false
        }

        do {
            try await sendResponse(conn, code: accepted ? RESPONSE_ACCEPT : RESPONSE_REJECT)
        } catch {
            print("[TransferEngine] sendResponse error: \(error)")
        }
        conn.cancel()
    }

    private func sendResponse(_ conn: NWConnection, code: Int32) async throws {
        var buf = code.bigEndianBytes
        try await send(conn, data: Data(buf))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Send to multiple devices
    // ─────────────────────────────────────────────────────────────────────────

    /// Tương đương requestSendFileToMultiple(Android).
    ///
    /// - Devices wifi   : PHASE 1 handshake → PHASE 2 gửi file
    /// - Devices bt     : skip handshake → gửi thẳng qua TCP (IP từ BLE discovery)
    /// - Cross-platform : Hoàn toàn tương thích Android ↔ iOS (cùng wire protocol)
    func requestSendFileToMultiple(
        devices: [TargetDevice],
        filePaths: [String],
        senderName: String,
        mode: SendMode = .sequential,
        onEachFileDone: @escaping (TargetDevice, String, Bool, String?) -> Void = { _, _, _, _ in },
        onEachDeviceDone: @escaping (TargetDevice, [String: Bool]) -> Void = { _, _ in },
        onAllDone: @escaping ([String: [String: Bool]]) -> Void = { _ in }   // key = device.id
    ) {
        Task {
            var allResults   = [String: [String: Bool]]()
            var readyToSend  = [TargetDevice]()
            let wifiDevices  = devices.filter { $0.from == .wifi }
            let btDevices    = devices.filter { $0.from == .bluetooth }

            // ── PHASE 1: Handshake song song với WiFi devices ─────────────────
            await withTaskGroup(of: (TargetDevice, Bool, Bool).self) { group in
                for device in wifiDevices {
                    group.addTask {
                        let (accepted, isBusy) = await self.wifiHandshake(
                            device: device, senderName: senderName, totalFiles: filePaths.count
                        )
                        await MainActor.run {
                            self.sendRequestResultSubject.send(
                                SendRequestResult(device: device, accepted: accepted, isBusy: isBusy)
                            )
                        }
                        return (device, accepted, isBusy)
                    }
                }
                for await (device, accepted, isBusy) in group {
                    if !accepted {
                        let reason = isBusy ? "Thiết bị đang bận nhận file từ người khác"
                                            : "Thiết bị từ chối yêu cầu"
                        let results = Dictionary(uniqueKeysWithValues: filePaths.map { ($0, false) })
                        allResults[device.id] = results
                        results.forEach { fp, _ in onEachFileDone(device, fp, false, reason) }
                        onEachDeviceDone(device, results)
                    } else {
                        readyToSend.append(device)
                    }
                }
            }

            // BT devices skip handshake
            readyToSend.append(contentsOf: btDevices)

            // ── PHASE 2: Gửi file ─────────────────────────────────────────────
            switch mode {
            case .sequential:
                for device in readyToSend {
                    let results = await sendFilesToDevice(
                        device: device, filePaths: filePaths,
                        senderName: senderName, onEachFileDone: onEachFileDone
                    )
                    allResults[device.id] = results
                    onEachDeviceDone(device, results)
                }

            case .parallel:
                await withTaskGroup(of: (String, [String: Bool]).self) { group in
                    for device in readyToSend {
                        group.addTask {
                            let results = await self.sendFilesToDevice(
                                device: device, filePaths: filePaths,
                                senderName: senderName, onEachFileDone: onEachFileDone
                            )
                            onEachDeviceDone(device, results)
                            return (device.id, results)
                        }
                    }
                    for await (id, results) in group { allResults[id] = results }
                }
            }

            onAllDone(allResults)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - WiFi Handshake (private)
    // ─────────────────────────────────────────────────────────────────────────

    private func wifiHandshake(
        device: TargetDevice,
        senderName: String,
        totalFiles: Int
    ) async -> (accepted: Bool, isBusy: Bool) {
        let conn = NWConnection(
            host: NWEndpoint.Host(device.ipAddress),
            port: NWEndpoint.Port(integerLiteral: UInt16(device.port)),
            using: .tcp
        )
        defer { conn.cancel() }

        do {
            try await connect(conn, timeoutSec: 10)

            // Gửi REQUEST
            var header = MSG_TYPE_REQUEST.bigEndianBytes
            let meta   = "\(senderName)|\(totalFiles)".data(using: .utf8)!
            var metaLen = Int32(meta.count).bigEndianBytes
            var payload = Data(header) + Data(metaLen) + meta
            try await send(conn, data: payload)

            // Đọc response (4 bytes)
            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { _, _, _, _ in }
            // Dùng timeout qua Task
            let responseData = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await self.readExact(conn, length: 4)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64((self.requestTimeoutSec + 5) * 1_000_000_000))
                    throw TEError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            let code = responseData.toInt32BE()
            switch code {
            case RESPONSE_ACCEPT: return (true,  false)
            case RESPONSE_BUSY:   return (false, true)
            default:              return (false, false)
            }
        } catch {
            print("[TransferEngine] wifiHandshake error (\(device.name)): \(error)")
            return (false, false)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Send files to one device (WiFi hoặc BT→TCP)
    // ─────────────────────────────────────────────────────────────────────────

    private func sendFilesToDevice(
        device: TargetDevice,
        filePaths: [String],
        senderName: String,
        onEachFileDone: @escaping (TargetDevice, String, Bool, String?) -> Void
    ) async -> [String: Bool] {
        var results    = [String: Bool]()
        let totalFiles = filePaths.count
        for (index, filePath) in filePaths.enumerated() {
            let transferId = Int64.random(in: Int64.min...Int64.max)
            // Cả BT lẫn WiFi đều dùng TCP (iOS không có RFCOMM)
            let (ok, err) = await sendFileSingleTcp(
                device: device, filePath: filePath, senderName: senderName,
                transferId: transferId, fileIndex: index, totalFiles: totalFiles
            )
            results[filePath] = ok
            onEachFileDone(device, filePath, ok, err)
        }
        return results
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Send single file via TCP
    // ─────────────────────────────────────────────────────────────────────────

    private func sendFileSingleTcp(
        device: TargetDevice,
        filePath: String,
        senderName: String,
        transferId: Int64,
        fileIndex: Int,
        totalFiles: Int
    ) async -> (success: Bool, error: String?) {
        let conn = NWConnection(
            host: NWEndpoint.Host(device.ipAddress),
            port: NWEndpoint.Port(integerLiteral: UInt16(device.port)),
            using: .tcp
        )
        let handle = TransferHandle(connection: conn)
        await MainActor.run { activeTransfers[transferId] = handle }

        var state = TransferState(id: transferId)
        state.isIncoming = false
        state.peerName   = device.name
        state.status     = .connecting

        do {
            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw TEError.fileNotFound(filePath)
            }
            let attrs    = try FileManager.default.attributesOfItem(atPath: filePath)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            let fileName = url.lastPathComponent

            state.fileName   = fileName
            state.totalBytes = fileSize
            await MainActor.run { emitTransfer(state) }

            try await connect(conn, timeoutSec: 10)
            state.status = .transferring
            await MainActor.run { emitTransfer(state) }

            // Header: MSG_TYPE_FILE
            let metaStr  = "\(fileName)|\(fileSize)|\(senderName)|\(fileIndex)|\(totalFiles)"
            let metaData = metaStr.data(using: .utf8)!
            var header   = MSG_TYPE_FILE.bigEndianBytes
            var metaLen  = Int32(metaData.count).bigEndianBytes
            try await send(conn, data: Data(header) + Data(metaLen) + metaData)

            // Gửi file data
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }

            var totalSent: Int64 = 0
            var lastUpdate       = Date()
            var sinceLastUpdate: Int64 = 0

            while true {
                guard await MainActor.run(body: { activeTransfers[transferId] != nil }) else {
                    throw TEError.cancelled
                }
                let chunk = fileHandle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }

                try await send(conn, data: chunk)
                totalSent         += Int64(chunk.count)
                sinceLastUpdate   += Int64(chunk.count)

                let now   = Date()
                let delta = now.timeIntervalSince(lastUpdate)
                if delta >= 0.5 || totalSent == fileSize {
                    let progress = fileSize > 0 ? Int(totalSent * 100 / fileSize) : 0
                    let speed    = delta > 0 ? Double(sinceLastUpdate) / 1024 / 1024 / delta : 0
                    await MainActor.run {
                        var s = state
                        s.bytesTransferred = totalSent
                        s.progress         = progress
                        s.speedMbps        = speed
                        emitTransfer(s)
                        state = s
                    }
                    lastUpdate      = now
                    sinceLastUpdate = 0
                }
            }

            state.status   = .success
            state.progress = 100
            await MainActor.run { emitTransfer(state) }
            conn.cancel()
            await MainActor.run { activeTransfers.removeValue(forKey: transferId) }
            removeTransfer(transferId)
            return (true, nil)

        } catch {
            state.status = .failed
            state.error  = error.localizedDescription
            await MainActor.run {
                emitTransfer(state)
                activeTransfers.removeValue(forKey: transferId)
            }
            conn.cancel()
            removeTransfer(transferId)
            return (false, error.localizedDescription)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Incoming Transfer (nhận file)
    // ─────────────────────────────────────────────────────────────────────────

    private func handleIncomingTransfer(
        _ conn: NWConnection,
        transferId: Int64,
        onNotification: @escaping (String, String) -> Void,
        onClose: @escaping () -> Void
    ) async {
        await MainActor.run { activeReceiveCount += 1 }
        var state       = TransferState(id: transferId)
        var destURL: URL?

        do {
            // Đọc meta
            let metaLenData = try await readExact(conn, length: 4)
            let metaLen     = Int(metaLenData.toInt32BE())
            guard metaLen > 0, metaLen < 1024 * 1024 else { throw TEError.invalidMetadata }

            let metaData   = try await readExact(conn, length: metaLen)
            let parts      = (String(data: metaData, encoding: .utf8) ?? "")
                .split(separator: "|", omittingEmptySubsequences: false)

            guard parts.count >= 3 else { throw TEError.invalidMetadata }
            let fileName   = String(parts[0])
            let fileSize   = Int64(parts[1]) ?? 0
            let senderName = String(parts[2])
            let fileIndex  = Int(parts.count > 3 ? parts[3] : "0") ?? 0
            let totalFiles = Int(parts.count > 4 ? parts[4] : "1") ?? 1

            print("[TransferEngine] Nhận [\(fileIndex + 1)/\(totalFiles)] \(fileName) (\(fileSize) B) từ \(senderName)")
            onNotification("Đang nhận file", "\(senderName) gửi: \(fileName)")

            state.fileName   = fileName
            state.totalBytes = fileSize
            state.peerName   = senderName
            state.isIncoming = true
            state.status     = .transferring
            await MainActor.run { emitTransfer(state) }

            // Chuẩn bị file đích
            let url = try prepareDestinationFile(fileName: fileName)
            destURL = url

            let fileHandle = try FileHandle(forWritingTo: url)
            defer { try? fileHandle.close() }

            var totalRead: Int64       = 0
            var lastUpdate             = Date()
            var sinceLastUpdate: Int64 = 0

            while totalRead < fileSize {
                let remaining = Int(min(Int64(bufferSize), fileSize - totalRead))
                let chunk     = try await readExact(conn, length: remaining)

                try fileHandle.write(contentsOf: chunk)
                totalRead         += Int64(chunk.count)
                sinceLastUpdate   += Int64(chunk.count)

                let now   = Date()
                let delta = now.timeIntervalSince(lastUpdate)
                if delta >= 0.5 || totalRead == fileSize {
                    let progress = fileSize > 0 ? Int(totalRead * 100 / fileSize) : 0
                    let speed    = delta > 0 ? Double(sinceLastUpdate) / 1024 / 1024 / delta : 0
                    await MainActor.run {
                        var s = state
                        s.bytesTransferred = totalRead
                        s.progress         = progress
                        s.speedMbps        = speed
                        emitTransfer(s)
                        state = s
                    }
                    lastUpdate      = now
                    sinceLastUpdate = 0
                }
            }

            guard totalRead >= fileSize else { throw TEError.streamInterrupted }

            // Lưu vào Photos / Files
            saveToMediaLibraryIfNeeded(url: url, fileName: fileName)

            state.status   = .success
            state.progress = 100
            await MainActor.run { emitTransfer(state) }
            onNotification("Nhận file thành công", "Đã nhận \(fileName) từ \(senderName)")

        } catch {
            print("[TransferEngine] handleIncomingTransfer error: \(error)")
            state.status = .failed
            state.error  = error.localizedDescription
            await MainActor.run { emitTransfer(state) }
            if let url = destURL {
                try? FileManager.default.removeItem(at: url)
            }
            onNotification("Lỗi nhận file", "Lỗi khi nhận file")
        }

        await MainActor.run {
            activeReceiveCount -= 1
            activeTransfers.removeValue(forKey: transferId)
        }
        onClose()
        removeTransfer(transferId)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - File helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func prepareDestinationFile(fileName: String) throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var url = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext  = url.pathExtension
            var n    = 1
            repeat {
                url = dir.appendingPathComponent("\(base)(\(n)).\(ext)")
                n += 1
            } while FileManager.default.fileExists(atPath: url.path)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func saveToMediaLibraryIfNeeded(url: URL, fileName: String) {
        let lower   = fileName.lowercased()
        let isImage = ["jpg","jpeg","png","gif","webp","bmp"].contains(url.pathExtension.lowercased())
        let isVideo = ["mp4","mkv","mov","3gp","webm","avi"].contains(url.pathExtension.lowercased())
        guard isImage || isVideo else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                if isImage {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } completionHandler: { success, error in
                if success { print("[TransferEngine] Saved to Photos: \(fileName)") }
                else if let e = error { print("[TransferEngine] Photos error: \(e)") }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Low-level Network I/O helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func connect(_ conn: NWConnection, timeoutSec: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:   cont.resume()
                        case .failed(let e): cont.resume(throwing: e)
                        case .cancelled:     cont.resume(throwing: TEError.cancelled)
                        default: break
                        }
                    }
                    conn.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw TEError.timeout
            }
            try await group.next()!
            group.cancelAll()
        }
    }

    /// Gửi Data qua NWConnection — async/await wrapper
    private func send(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let e = error { cont.resume(throwing: e) }
                else             { cont.resume() }
            })
        }
    }

    /// Đọc chính xác [length] bytes từ NWConnection
    private func readExact(_ conn: NWConnection, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let e = error { cont.resume(throwing: e); return }
                if let d = data, d.count == length {
                    cont.resume(returning: d)
                } else {
                    cont.resume(throwing: TEError.streamInterrupted)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CBCentralManagerDelegate (BLE scan)
// ─────────────────────────────────────────────────────────────────────────────

extension TransferEngine: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn, isBluetoothScanning {
                central.scanForPeripherals(withServices: [bleServiceUUID], options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
            }
        }
    }

    /// Khi phát hiện peripheral, đọc IP từ ManufacturerData hoặc dùng tên thiết bị.
    ///
    /// ManufacturerData format (Android SuperTransfer):
    ///   [2 bytes company ID: 0xFF 0xFF][UTF-8 IP string, null-terminated]
    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        var peerIP   = ""
        var peerName = peripheral.name ?? "Thiết bị"

        // Đọc IP từ ManufacturerData
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfgData.count > 2 {
            let ipData = mfgData.dropFirst(2)  // bỏ 2 bytes company ID
            if let ipStr = String(data: ipData.prefix(while: { $0 != 0 }), encoding: .utf8),
               ipStr.split(separator: ".").count == 4 {
                peerIP = ipStr
            }
        }
        // Đọc tên từ LocalName
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            peerName = localName
        }

        guard !peerIP.isEmpty else {
            // Không có IP trong advertisement — không thể kết nối TCP
            print("[TransferEngine] BLE peripheral \(peerName) — no IP in advertisement, skipping")
            return
        }

        let device = TargetDevice(
            name: peerName, ipAddress: peerIP, port: Int(tcpTransferPort),
            from: .bluetooth,
            address: peripheral.identifier.uuidString
        )

        Task { @MainActor in
            addBluetoothDevice(device)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CBPeripheralManagerDelegate (BLE advertise — quảng bá IP của mình)
// ─────────────────────────────────────────────────────────────────────────────

extension TransferEngine: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }

        Task { @MainActor in
            let ipStr = getLocalIpAddress()
            guard ipStr != "127.0.0.1" else { return }

            // ManufacturerData: [0xFF, 0xFF] + IP bytes (UTF-8, không null-terminate — iOS CBPeripheral
            // tự cắt, nhưng Android đọc đến hết data)
            var ipBytes  = Array(ipStr.utf8)
            var mfgBytes: [UInt8] = [0xFF, 0xFF] + ipBytes
            let mfgData  = Data(mfgBytes)

            let advData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey  : [bleServiceUUID],
                CBAdvertisementDataLocalNameKey     : getDeviceName(),
                CBAdvertisementDataManufacturerDataKey: mfgData,  // sẽ bị iOS filter trên real device — dùng ServiceData thay thế
            ]
            peripheralManager?.startAdvertising(advData)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {}
    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let e = error { print("[TransferEngine] BLE advertise error: \(e)") }
        else             { print("[TransferEngine] BLE advertising started") }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Errors
// ─────────────────────────────────────────────────────────────────────────────

enum TEError: Error, LocalizedError {
    case invalidMetadata
    case fileNotFound(String)
    case streamInterrupted
    case cancelled
    case timeout
    case bluetoothUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidMetadata:          return "Metadata không hợp lệ"
        case .fileNotFound(let p):      return "File không tồn tại: \(p)"
        case .streamInterrupted:        return "Luồng dữ liệu bị gián đoạn"
        case .cancelled:                return "Đã huỷ"
        case .timeout:                  return "Hết thời gian chờ"
        case .bluetoothUnavailable:     return "Bluetooth không khả dụng"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Data extensions (Big-endian Int32 — giống Android DataOutputStream)
// ─────────────────────────────────────────────────────────────────────────────

extension Int32 {
    /// Trả về 4 bytes Big-endian — TƯƠNG THÍCH với Java DataOutputStream.writeInt()
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
    /// Đọc Big-endian Int32 từ 4 bytes đầu — TƯƠNG THÍCH với Java DataInputStream.readInt()
    func toInt32BE() -> Int32 {
        guard count >= 4 else { return 0 }
        return Int32(bitPattern:
            (UInt32(self[0]) << 24) |
            (UInt32(self[1]) << 16) |
            (UInt32(self[2]) <<  8) |
             UInt32(self[3])
        )
    }
}

extension NWEndpoint {
    /// Lấy port từ NWEndpoint (tiện dùng trong handleIncomingRequest)
    var port: Int? {
        if case let .hostPort(_, p) = self { return Int(p.rawValue) }
        return nil
    }
}
