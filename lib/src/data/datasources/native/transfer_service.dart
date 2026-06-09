import 'dart:async';
import 'package:flutter/services.dart';
import 'package:mytransferapp/src/domain/entities/bluetooth_device.dart';
import 'package:mytransferapp/src/domain/entities/network_info.dart';
import 'package:mytransferapp/src/domain/entities/transfer_state.dart';
import 'package:mytransferapp/src/domain/entities/wifi_device.dart';

class TransferService {
  TransferService._();
  static final TransferService instance = TransferService._();

  // ── Channels ────────────────────────────────────────────────────────
  static const _method = MethodChannel('com.supertransfer/method');
  static const _chTransfer = EventChannel('com.supertransfer/event.transfer');
  static const _chWifi = EventChannel('com.supertransfer/event.wifi_devices');
  static const _chBluetooth = EventChannel(
    'com.supertransfer/event.bt_devices',
  );

  // ── Streams (lazy broadcast) ─────────────────────────────────────────
  Stream<TransferState?> get transferStream =>
      _chTransfer.receiveBroadcastStream().map((e) {
        if (e == null) return null;
        return TransferState.fromMap(Map<String, dynamic>.from(e as Map));
      });

  /// Emit toàn bộ danh sách WiFi devices mỗi khi có thay đổi
  Stream<List<WifiDevice>> get wifiDevicesStream =>
      _chWifi.receiveBroadcastStream().map((e) {
        final list = e as List? ?? [];
        return list
            .map((d) => WifiDevice.fromMap(Map<String, dynamic>.from(d as Map)))
            .toList();
      });

  /// Emit từng Bluetooth device khi scan tìm được
  Stream<BluetoothDevice> get bluetoothDeviceStream => _chBluetooth
      .receiveBroadcastStream()
      .map((e) => BluetoothDevice.fromMap(Map<String, dynamic>.from(e as Map)));

  // ── Network info ─────────────────────────────────────────────────────
  /// Bật server nhận file (gọi tự động khi mở app bên Android,
  /// nhưng Flutter cũng có thể gọi lại nếu cần)
  Future<void> startReceiveServer() =>
      _method.invokeMethod('startReceiveServer');
      
  Future<String> getLocalIpAddress() async =>
      await _method.invokeMethod<String>('getLocalIpAddress') ?? '';

  Future<String> getDeviceName() async =>
      await _method.invokeMethod<String>('getDeviceName') ?? '';

  Future<NetworkInfo> getNetworkInfo() async {
    final map = await _method.invokeMapMethod<String, dynamic>(
      'getNetworkInfo',
    );
    return NetworkInfo.fromMap(map ?? {});
  }

  // ── Permission ────────────────────────────────────────────────────────

  Future<bool> checkPermissions() async =>
      await _method.invokeMethod<bool>('checkPermissions') ?? false;

  /// Trả về true nếu user cấp đủ quyền
  Future<bool> requestPermissions() async =>
      await _method.invokeMethod<bool>('requestPermissions') ?? false;

  // ── WiFi scan ─────────────────────────────────────────────────────────

  /// Bắt đầu scan — kết quả realtime qua [wifiDevicesStream]
  Future<void> startWifiScan({int timeoutMs = 10000}) {
    final data = {"timeoutMs": timeoutMs};
    return _method.invokeMethod('startWifiScan', data);
  }

  Future<void> stopWifiScan() => _method.invokeMethod('stopWifiScan');

  // ── Bluetooth ─────────────────────────────────────────────────────────

  Future<bool> checkBluetoothEnabled() async =>
      await _method.invokeMethod<bool>('checkBluetoothEnabled') ?? false;

  /// Mở dialog hệ thống yêu cầu bật BT
  Future<void> requestEnableBluetooth() =>
      _method.invokeMethod('requestEnableBluetooth');

  /// Bắt đầu scan BT — kết quả realtime qua [bluetoothDeviceStream]
  Future<void> startBluetoothScan({int timeoutMs = 10000}) {
    final data = {"timeoutMs": timeoutMs};
    return _method.invokeMethod('startBluetoothScan', data);
  }

  Future<void> stopBluetoothScan() => _method.invokeMethod('stopBluetoothScan');

  // ── Transfer ──────────────────────────────────────────────────────────

  Future<void> stopReceiveServer() => _method.invokeMethod('stopReceiveServer');

  /// Gửi file qua WiFi đến [ipAddress]
  /// [filePath] là content URI hoặc absolute path
  /// Tiến trình theo dõi qua [transferStream]
  Future<void> sendFileToIpAddress({
    required String ipAddress,
    required String filePath,
  }) => _method.invokeMethod('sendFileToIpAddress', {
    'ipAddress': ipAddress,
    'filePath': filePath,
  });

  /// Gửi file qua Bluetooth (mở share sheet hệ thống)
  Future<void> sendFileViaBluetooth({required String filePath}) =>
      _method.invokeMethod('sendFileViaBluetooth', {'filePath': filePath});

  Future<void> cancelTransfer() => _method.invokeMethod('cancelTransfer');

  // ── Utility ───────────────────────────────────────────────────────────

  Future<void> openFile({required String filePath, required String fileName}) =>
      _method.invokeMethod('openFile', {
        'filePath': filePath,
        'fileName': fileName,
      });

  Future<void> openHotspotSettings() =>
      _method.invokeMethod('openHotspotSettings');

  Future<void> openWifiSettings() => _method.invokeMethod('openWifiSettings');

  Future<void> openBluetoothSettings() =>
      _method.invokeMethod('openBluetoothSettings');
}
