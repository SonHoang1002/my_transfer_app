import 'package:flutter/services.dart';
import 'package:mytransferapp/enum/send_mode_status.dart';
import 'package:mytransferapp/src/domain/entities/device_entity/current_device.dart';
import 'package:mytransferapp/src/domain/entities/device_entity/target_device.dart';
import 'package:mytransferapp/src/domain/entities/send_request_result.dart';
import 'package:mytransferapp/src/domain/entities/transfer_engine_state.dart';
import 'package:mytransferapp/src/domain/entities/transfer_state.dart';

class TransferService {
  TransferService._();

  static final TransferService instance = TransferService._();

  // ─────────────────────────────────────────────
  // Channels
  // ─────────────────────────────────────────────

  static const _method = MethodChannel('com.supertransfer/method');

  static const _chTransfer = EventChannel('com.supertransfer/event.transfer');

  static const _chWifi = EventChannel('com.supertransfer/event.wifi_devices');

  static const _chIncomingRequest = EventChannel(
    'com.supertransfer/event.incoming_request',
  );
  static const EventChannel _chSendRequestResult = EventChannel(
    'com.supertransfer/event.send_request_result',
  );

  // Stream<Map<String, dynamic>> get btDevicesStream =>
  //     _chBtDevices.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));

  Stream<SendRequestResult> get sendRequestResultStream =>
      _chSendRequestResult.receiveBroadcastStream().map((e) {
        return SendRequestResult.fromMap(Map<String, dynamic>.from(e as Map));
      });

  // ─────────────────────────────────────────────
  // Event Streams
  // ─────────────────────────────────────────────

  Stream<List<TransferState>> get transferStream =>
      _chTransfer.receiveBroadcastStream().map((event) {
        final list = event as List? ?? [];

        return list
            .map(
              (e) => TransferState.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      });

  Stream<List<TargetDevice>> get wifiDevicesStream =>
      _chWifi.receiveBroadcastStream().map((event) {
        final list = event as List? ?? [];
        return list.map((e) {
          print("wifiDevicesStream item = $e");
          return TargetDevice.fromMap(Map<String, dynamic>.from(e as Map));
        }).toList();
      });

  // Stream<BluetoothDevice> get bluetoothDeviceStream =>
  //     _chBluetooth.receiveBroadcastStream().map(
  //           (event) => BluetoothDevice.fromMap(
  //             Map<String, dynamic>.from(event as Map),
  //           ),
  //         );

  Stream<TargetDevice> get incomingRequestStream =>
      _chIncomingRequest.receiveBroadcastStream().map((e) {
        print("incomingRequestStream item = $e");
        return TargetDevice.fromMap(Map<String, dynamic>.from(e as Map));
      });

  // ─────────────────────────────────────────────
  // Device Info
  // ─────────────────────────────────────────────

  Future<CurrentDevice> getCurrentDeviceInfo() async {
    final map = await _method.invokeMapMethod<String, dynamic>(
      'getCurrentDeviceInfo',
    );

    return CurrentDevice.fromMap(map ?? {});
  }

  Future<TransferEngineState> getTransferEngineStatus() async {
    final map = await _method.invokeMapMethod<String, dynamic>(
      'getTransferEngineStatus',
    );

    return TransferEngineState.fromMap(map ?? {});
  }

  // ─────────────────────────────────────────────
  // Permissions
  // ─────────────────────────────────────────────

  Future<bool> checkPermissions() async {
    return await _method.invokeMethod<bool>('checkPermissions') ?? false;
  }

  Future<bool> requestPermissions() async {
    return await _method.invokeMethod<bool>('requestPermissions') ?? false;
  }

  // ─────────────────────────────────────────────
  // WiFi Scan
  // ─────────────────────────────────────────────

  Future<void> startWifiScan({int timeoutMs = 10000}) {
    return _method.invokeMethod('startWifiScan', {'timeoutMs': timeoutMs});
  }

  Future<void> stopWifiScan() {
    return _method.invokeMethod('stopWifiScan');
  }

  // ─────────────────────────────────────────────
  // Bluetooth
  // ─────────────────────────────────────────────

  Future<bool> checkBluetoothEnabled() async {
    return await _method.invokeMethod<bool>('checkBluetoothEnabled') ?? false;
  }

  Future<void> requestEnableBluetooth() {
    return _method.invokeMethod('requestEnableBluetooth');
  }

  Future<void> startBluetoothScan({int timeoutMs = 10000}) {
    return _method.invokeMethod('startBluetoothScan', {'timeoutMs': timeoutMs});
  }

  Future<void> stopBluetoothScan() {
    return _method.invokeMethod('stopBluetoothScan');
  }

  // ─────────────────────────────────────────────
  // Transfer Service
  // ─────────────────────────────────────────────

  Future<void> startReceiveServer() {
    return _method.invokeMethod('startReceiveServer');
  }

  Future<void> stopReceiveServer() {
    return _method.invokeMethod('stopReceiveServer');
  }

  // ─────────────────────────────────────────────
  // Send Files
  // ─────────────────────────────────────────────

  Future<dynamic> requestSendFileToMultiple({
    required List<TargetDevice> devices,
    required List<String> listFilePath,
    SendMode mode = SendMode.SEQUENTIAL,
  }) async {
    return _method.invokeMethod('requestSendFileToMultiple', {
      'devices': devices.map((e) => e.toMap()).toList(),
      'listFilePath': listFilePath,
      'sendMode': mode.name.toUpperCase(),
    });
  }

  Future<void> sendFileViaBluetooth({required String filePath}) {
    return _method.invokeMethod('sendFileViaBluetooth', {'filePath': filePath});
  }

  Future<void> cancelTransfer({int? transferId}) {
    return _method.invokeMethod('cancelTransfer', {'transferId': transferId});
  }

  Future<void> acceptRequest(int requestId) async {
    try {
      await _method.invokeMethod('acceptRequest', {'requestId': requestId});
    } catch (e) {
      print('acceptRequest error: $e');
    }
  }

  Future<void> cancelRequest(int requestId) async {
    try {
      await _method.invokeMethod('cancelRequest', {'requestId': requestId});
    } catch (e) {
      print('cancelRequest error: $e');
    }
  }
  // ─────────────────────────────────────────────
  // Utility
  // ─────────────────────────────────────────────

  Future<void> openFile({required String filePath, required String fileName}) {
    return _method.invokeMethod('openFile', {
      'filePath': filePath,
      'fileName': fileName,
    });
  }

  Future<void> openHotspotSettings() {
    return _method.invokeMethod('openHotspotSettings');
  }

  Future<void> openWifiSettings() {
    return _method.invokeMethod('openWifiSettings');
  }

  Future<void> openBluetoothSettings() {
    return _method.invokeMethod('openBluetoothSettings');
  }
}
