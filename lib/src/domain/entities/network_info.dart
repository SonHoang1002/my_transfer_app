class NetworkInfo {
  final String ipAddress;
  final String deviceName;
  final bool isWifiConnected;

  const NetworkInfo({
    required this.ipAddress,
    required this.deviceName,
    required this.isWifiConnected,
  });

  factory NetworkInfo.fromMap(Map m) => NetworkInfo(
        ipAddress: m['ipAddress'] as String? ?? '',
        deviceName: m['deviceName'] as String? ?? '',
        isWifiConnected: m['isWifiConnected'] as bool? ?? false,
      );
}
