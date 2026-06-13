import 'package:mytransferapp/src/domain/entities/device_entity/core_device.dart';

class CurrentDevice extends CoreDevice {
  final int port;
  final int lastSeen;

  CurrentDevice({
    required super.name,
    required super.ipAddress,
    required this.port,
    required this.lastSeen,
  });

  factory CurrentDevice.fromMap(Map m) => CurrentDevice(
    ipAddress: m['ipAddress'] as String? ?? '',
    name: m['name'] as String? ?? '',
    port: m['port'] as int? ?? 0,
    lastSeen: m['lastSeen'] as int? ?? 0,
  );
}
