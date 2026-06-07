import 'package:mytransferapp/src/domain/entities/core_device.dart';

class WifiDevice extends CoreDevice {
  final int port;
  final int lastSeen;

  WifiDevice({
    required super.ipAddress,
    required super.name,
    required this.port,
    required this.lastSeen,
  });

  factory WifiDevice.fromMap(Map m) => WifiDevice(
    name: m['name'] as String? ?? '',
    ipAddress: m['ipAddress'] as String? ?? '',
    port: m['port'] as int? ?? 9999,
    lastSeen: (m['lastSeen'] as num?)?.toInt() ?? 0,
  );
}
