class DeviceInfo {
  final String name;
  final String ipAddress;
  final int port;
  final int lastSeen;
  DeviceInfo({
    required this.name,
    required this.ipAddress,
    required this.lastSeen,
    required this.port,
  });

  factory DeviceInfo.fromMap(Map m) => DeviceInfo(
    ipAddress: m['ipAddress'] as String? ?? '',
    name: m['name'] as String? ?? '',
    port: m['port'] as int? ?? 0,
    lastSeen: m['lastSeen'] as int? ?? 0,
  );
}
