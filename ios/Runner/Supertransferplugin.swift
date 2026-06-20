import Flutter
import UIKit
import Combine
import UserNotifications
import CoreBluetooth

@available(iOS 14, *)
@MainActor
final class SuperTransferPlugin: NSObject, FlutterPlugin {

    static let chMethod      = "com.supertransfer/method"
    static let chTransfer    = "com.supertransfer/event.transfer"
    static let chWifiDevices = "com.supertransfer/event.wifi_devices"
    static let chBtDevices   = "com.supertransfer/event.bt_devices"
    static let chIncoming    = "com.supertransfer/event.incoming_request"

    private let engine = TransferEngine.shared
    private var cancellables = Set<AnyCancellable>()

    private var transferSink:    FlutterEventSink?
    private var wifiDevicesSink: FlutterEventSink?
    private var btDevicesSink:   FlutterEventSink?
    private var incomingReqSink: FlutterEventSink?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance  = SuperTransferPlugin()
        let messenger = registrar.messenger()

        FlutterMethodChannel(name: chMethod, binaryMessenger: messenger)
            .setMethodCallHandler(instance.handle(_:result:))

        FlutterEventChannel(name: chTransfer, binaryMessenger: messenger)
            .setStreamHandler(instance.makeTransferHandler())
        FlutterEventChannel(name: chWifiDevices, binaryMessenger: messenger)
            .setStreamHandler(instance.makeWifiDevicesHandler())
        FlutterEventChannel(name: chBtDevices, binaryMessenger: messenger)
            .setStreamHandler(instance.makeBtDevicesHandler())
        FlutterEventChannel(name: chIncoming, binaryMessenger: messenger)
            .setStreamHandler(instance.makeIncomingRequestHandler())

        instance.startServices()
    }

    private func startServices() {
        Task { @MainActor in
            if #available(iOS 14.0, *) {
                engine.startTcpServer { title, body in
                    SuperTransferPlugin.showLocalNotification(title: title, body: body)
                }
            } else {
                print("⚠️ startTcpServer requires iOS 14.0+, skipping...")
            }
            engine.startAdvertising()
            engine.startBluetoothAdvertising()
        }
    }

    // MARK: - MethodChannel
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        Task { @MainActor in
            switch call.method {
            case "getCurrentDeviceInfo":
                result([
                    "ipAddress"       : self.engine.getLocalIpAddress(),
                    "deviceName"      : self.engine.getDeviceName(),
                    "isWifiConnected" : self.isWifiConnected(),
                ] as [String: Any])

            case "getTransferEngineStatus":
                result(self.engine.getTransferEngineStatus())

            case "checkPermissions":
                result(true)

            case "requestPermissions":
                result(true)

            case "startWifiScan":
                let ms = args?["timeoutMs"] as? Int ?? 30_000
                self.engine.startWifiScanning(timeoutMs: ms)
                result(nil)

            case "stopWifiScan":
                self.engine.stopWifiScanning()
                result(nil)

            case "checkBluetoothEnabled":
                if #available(iOS 13.1, *) {
                    result(CBCentralManager.authorization != .denied)
                } else {
                    result(true)
                }

            case "requestEnableBluetooth":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            case "startBluetoothScan":
                let ms = args?["timeoutMs"] as? Int ?? 30_000
                self.engine.startBluetoothScan(timeoutMs: ms)
                result(nil)

            case "stopBluetoothScan":
                self.engine.stopBluetoothScan()
                result(nil)

            case "startReceiveServer":
                if #available(iOS 14.0, *) {
                    self.engine.startTcpServer { title, body in
                        SuperTransferPlugin.showLocalNotification(title: title, body: body)
                    }
                } else {
                    print("⚠️ startTcpServer requires iOS 14.0+")
                }
                result(nil)

            case "stopReceiveServer":
                self.engine.stopTcpServer()
                result(nil)

            case "requestSendFileToMultiple":
                guard
                    let rawDevices   = args?["devices"]      as? [[String: Any]],
                    let listFilePath = args?["listFilePath"]  as? [String],
                    !rawDevices.isEmpty, !listFilePath.isEmpty
                else {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "devices và listFilePath bắt buộc",
                                        details: nil))
                    return
                }
                let modeStr = args?["mode"] as? String ?? "SEQUENTIAL"
                let mode: SendMode = modeStr == "PARALLEL" ? .parallel : .sequential
                let devices = rawDevices.compactMap { TargetDevice.fromMap($0) }
                guard !devices.isEmpty else {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "Không parse được danh sách thiết bị",
                                        details: nil))
                    return
                }

                self.engine.requestSendFileToMultiple(
                    devices:    devices,
                    filePaths:  listFilePath,
                    senderName: self.engine.getDeviceName(),
                    mode:       mode
                ) { allResults in
                    let output: [[String: Any]] = devices.compactMap { device in
                        guard let fileResults = allResults[device.id] else { return nil }
                        return [
                            "name"      : device.name,
                            "ipAddress" : device.ipAddress,
                            "files"     : fileResults.map { fp, ok in
                                ["filePath": fp, "success": ok] as [String: Any]
                            },
                        ]
                    }
                    result(output)
                }

            case "acceptRequest":
                guard let rid = (args?["requestId"] as? NSNumber)?.int64Value else {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "requestId bắt buộc", details: nil))
                    return
                }
                self.engine.acceptRequest(rid)
                result(nil)

            case "cancelRequest":
                guard let rid = (args?["requestId"] as? NSNumber)?.int64Value else {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "requestId bắt buộc", details: nil))
                    return
                }
                self.engine.cancelRequest(rid)
                result(nil)

            case "cancelTransfer":
                let tid = (args?["transferId"] as? NSNumber)?.int64Value
                self.engine.cancelActiveTransfer(tid)
                result(nil)

            case "openFile":
                guard let path = args?["filePath"] as? String else {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "filePath bắt buộc", details: nil))
                    return
                }
                self.openFile(path: path)
                result(nil)

            case "openWifiSettings", "openHotspotSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            case "openBluetoothSettings":
                let urlStr = "App-Prefs:root=Bluetooth"
                if let url = URL(string: urlStr), UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - EventChannel stream handlers

    private func makeTransferHandler() -> BlockStreamHandler {
        BlockStreamHandler(
            onListen: { [weak self] sink in
                guard let self else { return }

                self.transferSink = sink

                let current = Array(
                    self.engine.transfers.values.map { $0.toMap() }
                )

                sink(current)

                let cancellable = self.engine.$transfers
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] map in
                        let list = Array(
                            map.values.map { $0.toMap() }
                        )

                        self?.transferSink?(list)
                    }

                cancellable.store(in: &self.cancellables)
            },
            onCancel: { [weak self] in
                self?.transferSink = nil
            }
        )
    }

    private func makeWifiDevicesHandler() -> BlockStreamHandler {
        BlockStreamHandler(
            onListen: { [weak self] sink in
                guard let self else { return }
                self.wifiDevicesSink = sink
                
                // ✅ FIX: Tạo cancellable riêng
                let cancellable = self.engine.$discoveredDevices
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] devices in
                        let list = devices
                            .filter { $0.from == .wifi }
                            .map { $0.toMap() }
                        self?.wifiDevicesSink?(list)
                    }
                cancellable.store(in: &self.cancellables)
            },
            onCancel: { [weak self] in
                self?.wifiDevicesSink = nil
            }
        )
    }

    private func makeBtDevicesHandler() -> BlockStreamHandler {
        BlockStreamHandler(
            onListen: { [weak self] sink in
                guard let self else { return }
                self.btDevicesSink = sink
                
                // ✅ FIX: Tạo cancellable riêng
                let cancellable = self.engine.$discoveredDevices
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] devices in
                        devices.filter { $0.from == .bluetooth }
                            .forEach { self?.btDevicesSink?($0.toMap()) }
                    }
                cancellable.store(in: &self.cancellables)
            },
            onCancel: { [weak self] in
                self?.btDevicesSink = nil
            }
        )
    }

    private func makeIncomingRequestHandler() -> BlockStreamHandler {
        BlockStreamHandler(
            onListen: { [weak self] sink in
                guard let self else { return }
                self.incomingReqSink = sink
                
                // ✅ FIX: Tạo cancellable riêng
                let cancellable = self.engine.incomingRequestSubject
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] device in
                        self?.incomingReqSink?(device.toMap())
                    }
                cancellable.store(in: &self.cancellables)
            },
            onCancel: { [weak self] in
                self?.incomingReqSink = nil
            }
        )
    }

    // MARK: - Helpers

    private func isWifiConnected() -> Bool {
        let ip = engine.getLocalIpAddress()
        return ip != "127.0.0.1" && !ip.isEmpty
    }

    private func openFile(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows
            .first?.rootViewController
        else { return }

        let vc = UIDocumentInteractionController(url: url)
        vc.delegate = root as? UIDocumentInteractionControllerDelegate
        if !vc.presentPreview(animated: true) {
            vc.presentOptionsMenu(from: .zero, in: root.view, animated: true)
        }
        objc_setAssociatedObject(root, "docIC_\(path.hashValue)", vc,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func showLocalNotification(title: String, body: String) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        content.sound     = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}

// MARK: - BlockStreamHandler

private final class BlockStreamHandler: NSObject, FlutterStreamHandler {

    private let onListenBlock: (@escaping FlutterEventSink) -> Void
    private let onCancelBlock: () -> Void

    init(
        onListen: @escaping (@escaping FlutterEventSink) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onListenBlock = onListen
        self.onCancelBlock = onCancel
        super.init()
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        onListenBlock(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancelBlock()
        return nil
    }
}
