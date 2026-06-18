//
//  Supertransferplugin.swift
//  Runner
//
//  Created by sonmac on 18/6/26.
//

// SuperTransferPlugin.swift
// SuperTransfer — iOS
//
// Bridge giữa Flutter (Dart) ↔ TransferEngine (Swift).
// Tương đương MainActivity.kt (Android) — cùng channel name, cùng API contract.
//
// Đăng ký trong AppDelegate.swift:
//   SuperTransferPlugin.register(with: registrar)
// hoặc với FlutterPluginRegistrant nếu dùng plugin package.

import Flutter
import UIKit
import CoreBluetooth

// MARK: - SuperTransferPlugin

final class SuperTransferPlugin: NSObject, FlutterPlugin {

    // ── Channel names — PHẢI khớp chính xác với Android ─────────────────────
    static let chMethod       = "com.supertransfer/method"
    static let chTransfer     = "com.supertransfer/event.transfer"
    static let chWifiDevices  = "com.supertransfer/event.wifi_devices"
    static let chBtDevices    = "com.supertransfer/event.bt_devices"
    static let chIncoming     = "com.supertransfer/event.incoming_request"

    private let engine = TransferEngine.shared

    // Event sinks
    private var transferSink:      FlutterEventSink?
    private var wifiDevicesSink:   FlutterEventSink?
    private var btDevicesSink:     FlutterEventSink?
    private var incomingReqSink:   FlutterEventSink?

    // Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // ── Registration ──────────────────────────────────────────────────────────

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SuperTransferPlugin()
        let messenger = registrar.messenger()

        // MethodChannel
        let methodChannel = FlutterMethodChannel(name: chMethod, binaryMessenger: messenger)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        // EventChannels
        FlutterEventChannel(name: chTransfer,    binaryMessenger: messenger)
            .setStreamHandler(instance.makeTransferStreamHandler())
        FlutterEventChannel(name: chWifiDevices, binaryMessenger: messenger)
            .setStreamHandler(instance.makeWifiDevicesStreamHandler())
        FlutterEventChannel(name: chBtDevices,   binaryMessenger: messenger)
            .setStreamHandler(instance.makeBtDevicesStreamHandler())
        FlutterEventChannel(name: chIncoming,    binaryMessenger: messenger)
            .setStreamHandler(instance.makeIncomingRequestStreamHandler())

        // Tự động khởi động server khi plugin load (giống onCreate Android)
        instance.startServices()
    }

    // ── Start/Stop services ───────────────────────────────────────────────────

    private func startServices() {
        Task { @MainActor in
            engine.startTcpServer { title, body in
                // Notification — dùng UNUserNotificationCenter
                SuperTransferPlugin.showLocalNotification(title: title, body: body)
            }
            engine.startAdvertising()
        }
    }

    // ── MethodChannel handler ─────────────────────────────────────────────────

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        Task { @MainActor in
            switch call.method {

            // ── Device info ────────────────────────────────────────────────
            case "getCurrentDeviceInfo":
                result([
                    "ipAddress"      : engine.getLocalIpAddress(),
                    "deviceName"     : engine.getDeviceName(),
                    "isWifiConnected": isWifiConnected(),
                ])

            case "getTransferEngineStatus":
                result(engine.getTransferEngineStatus())

            // ── Permissions ────────────────────────────────────────────────
            case "checkPermissions":
                // iOS: quyền được kiểm tra riêng từng loại — trả về true cho compat
                result(true)

            case "requestPermissions":
                // iOS xử lý permission theo từng API (PHPhotoLibrary, CBCentralManager...)
                result(true)

            // ── WiFi scan ──────────────────────────────────────────────────
            case "startWifiScan":
                let timeoutMs = args?["timeoutMs"] as? Int ?? 30000
                engine.startWifiScanning(timeoutMs: timeoutMs)
                result(nil)

            case "stopWifiScan":
                engine.stopWifiScanning()
                result(nil)

            // ── Bluetooth ──────────────────────────────────────────────────
            case "checkBluetoothEnabled":
                // CoreBluetooth không cho phép kiểm tra trực tiếp — trả về best-effort
                result(CBCentralManager.authorization != .denied)

            case "requestEnableBluetooth":
                // iOS không có API bật BT theo lập trình — redirect Settings
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            case "startBluetoothScan":
                let timeoutMs = args?["timeoutMs"] as? Int ?? 30000
                engine.startBluetoothScan(timeoutMs: timeoutMs)
                result(nil)

            case "stopBluetoothScan":
                engine.stopBluetoothScan()
                result(nil)

            // ── Transfer server ────────────────────────────────────────────
            case "startReceiveServer":
                engine.startTcpServer { title, body in
                    SuperTransferPlugin.showLocalNotification(title: title, body: body)
                }
                result(nil)

            case "stopReceiveServer":
                engine.stopTcpServer()
                result(nil)

            // ── Send files ─────────────────────────────────────────────────
            case "requestSendFileToMultiple":
                guard
                    let rawDevices  = args?["devices"]      as? [[String: Any]],
                    let listFilePath = args?["listFilePath"] as? [String]
                else {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "devices và listFilePath là bắt buộc",
                                        details: nil))
                    return
                }

                let modeStr = args?["mode"] as? String ?? "SEQUENTIAL"
                let mode: SendMode = modeStr == "PARALLEL" ? .parallel : .sequential
                let senderName = engine.getDeviceName()

                let devices = rawDevices.compactMap { TargetDevice.fromMap($0) }
                if devices.isEmpty {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "Không parse được danh sách thiết bị",
                                        details: nil))
                    return
                }

                engine.requestSendFileToMultiple(
                    devices: devices,
                    filePaths: listFilePath,
                    senderName: senderName,
                    mode: mode,
                    onAllDone: { allResults in
                        // Chuyển sang format giống Android để Flutter không cần xử lý khác
                        let output = devices.compactMap { device -> [String: Any]? in
                            guard let fileResults = allResults[device.id] else { return nil }
                            return [
                                "name"      : device.name,
                                "ipAddress" : device.ipAddress,
                                "files"     : fileResults.map { fp, ok in
                                    ["filePath": fp, "success": ok]
                                }
                            ]
                        }
                        result(output)
                    }
                )

            // ── Accept / Reject request ────────────────────────────────────
            case "acceptRequest":
                guard let requestId = (args?["requestId"] as? NSNumber)?.int64Value else {
                    result(FlutterError(code: "INVALID_ARGS", message: "requestId bắt buộc", details: nil))
                    return
                }
                engine.acceptRequest(requestId)
                result(nil)

            case "cancelRequest":
                guard let requestId = (args?["requestId"] as? NSNumber)?.int64Value else {
                    result(FlutterError(code: "INVALID_ARGS", message: "requestId bắt buộc", details: nil))
                    return
                }
                engine.cancelRequest(requestId)
                result(nil)

            // ── Cancel transfer ────────────────────────────────────────────
            case "cancelTransfer":
                let transferId = (args?["transferId"] as? NSNumber)?.int64Value
                engine.cancelActiveTransfer(transferId)
                result(nil)

            // ── Utility ────────────────────────────────────────────────────
            case "openFile":
                guard let filePath = args?["filePath"] as? String else {
                    result(FlutterError(code: "INVALID_ARGS", message: "filePath bắt buộc", details: nil))
                    return
                }
                openFile(path: filePath)
                result(nil)

            case "openWifiSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            case "openBluetoothSettings":
                if let url = URL(string: "App-Prefs:root=Bluetooth") {
                    UIApplication.shared.open(url)
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            case "openHotspotSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - EventChannel StreamHandlers
    // ─────────────────────────────────────────────────────────────────────────

    // Transfers — phát list mỗi khi transfers Map thay đổi
    private func makeTransferStreamHandler() -> FlutterStreamHandler {
        makeHandler(
            onListen: { [weak self] sink in
                self?.transferSink = sink
                // Phát ngay giá trị hiện tại
                let current = (self?.engine.transfers.values.map { $0.toMap() }) ?? []
                sink(current)
                // Subscribe Combine publisher
                self?.engine.$transfers
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] map in
                        self?.transferSink?(Array(map.values.map { $0.toMap() }))
                    }
                    .store(in: &(self!.cancellables))
            },
            onCancel: { [weak self] in self?.transferSink = nil }
        )
    }

    // WiFi devices
    private func makeWifiDevicesStreamHandler() -> FlutterStreamHandler {
        makeHandler(
            onListen: { [weak self] sink in
                self?.wifiDevicesSink = sink
                self?.engine.$discoveredDevices
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] devices in
                        let list = devices
                            .filter { $0.from == .wifi }
                            .map { $0.toMap() }
                        self?.wifiDevicesSink?(list)
                    }
                    .store(in: &(self!.cancellables))
            },
            onCancel: { [weak self] in self?.wifiDevicesSink = nil }
        )
    }

    // BT devices — emit từng device (giống Android push từng device qua btReceiver)
    private func makeBtDevicesStreamHandler() -> FlutterStreamHandler {
        makeHandler(
            onListen: { [weak self] sink in
                self?.btDevicesSink = sink
                self?.engine.$discoveredDevices
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] devices in
                        devices.filter { $0.from == .bluetooth }
                            .forEach { self?.btDevicesSink?($0.toMap()) }
                    }
                    .store(in: &(self!.cancellables))
            },
            onCancel: { [weak self] in self?.btDevicesSink = nil }
        )
    }

    // Incoming request — emit từng request
    private func makeIncomingRequestStreamHandler() -> FlutterStreamHandler {
        makeHandler(
            onListen: { [weak self] sink in
                self?.incomingReqSink = sink
                self?.engine.incomingRequestSubject
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] device in
                        self?.incomingReqSink?(device.toMap())
                    }
                    .store(in: &(self!.cancellables))
            },
            onCancel: { [weak self] in self?.incomingReqSink = nil }
        )
    }

    /// Factory helper để tránh boilerplate tạo FlutterStreamHandler
    private func makeHandler(
        onListen: @escaping (FlutterEventSink) -> Void,
        onCancel: @escaping () -> Void
    ) -> FlutterStreamHandler {
        let handler = BlockStreamHandler()
        handler.onListenBlock = onListen
        handler.onCancelBlock = onCancel
        return handler
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func isWifiConnected() -> Bool {
        // Dùng Network.framework path monitor — đơn giản check local IP != loopback
        let ip = engine.getLocalIpAddress()
        return ip != "127.0.0.1" && !ip.isEmpty
    }

    private func openFile(path: String) {
        let url = URL(fileURLWithPath: path)
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows
                .first?.rootViewController
            else { return }

            let vc = UIDocumentInteractionController(url: url)
            vc.presentPreview(animated: true)
            // Giữ reference để tránh deallocate
            objc_setAssociatedObject(root, "docInteraction", vc, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    static func showLocalNotification(title: String, body: String) {
        let content         = UNMutableNotificationContent()
        content.title       = title
        content.body        = body
        content.sound       = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - BlockStreamHandler (helper)

private final class BlockStreamHandler: NSObject, FlutterStreamHandler {
    var onListenBlock: ((FlutterEventSink) -> Void)?
    var onCancelBlock: (() -> Void)?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListenBlock?(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancelBlock?()
        return nil
    }
}
