class TransferEngineState {
  final bool isWifiScanning;
  final bool isBluetoothScanning;
  final bool isReceiving;
  final bool isAdvertising;

  const TransferEngineState({
    required this.isWifiScanning,
    required this.isBluetoothScanning,
    required this.isReceiving,
    required this.isAdvertising,
  });

  factory TransferEngineState.fromMap(Map m) => TransferEngineState(
    isWifiScanning: m['isWifiScanning'] as bool? ?? false,
    isBluetoothScanning: m['isBluetoothScanning'] as bool? ?? false,
    isReceiving: m['isReceiving'] as bool? ?? false,
    isAdvertising: m['isAdvertising'] as bool? ?? false,
  );
}
