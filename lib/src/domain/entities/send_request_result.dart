
import 'package:mytransferapp/src/domain/entities/device_entity/target_device.dart';

class SendRequestResult {
  final String name;
  final String ipAddress;
  final int port;
  final ScanMode from;
  final bool accepted;

  SendRequestResult({
    required this.name,
    required this.ipAddress,
    required this.port,
    required this.from,
    required this.accepted,
  });

  factory SendRequestResult.fromMap(Map<String, dynamic> map) {
    return SendRequestResult(
      name: map['name'] as String,
      ipAddress: map['ipAddress'] as String,
      port: map['port'] as int,
      from: ScanMode.values[map['fromIndex'] as int],
      accepted: map['accepted'] as bool,
    );
  }
}