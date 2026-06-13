class CoreDevice {
  final String name;
  final String ipAddress;
  CoreDevice({required this.name, required this.ipAddress});

  factory CoreDevice.fromMap(Map m) => CoreDevice(
    name: m['name'] as String? ?? '',
    ipAddress: m['ipAddress'] as String? ?? '',
  );
}
