import 'package:mytransferapp/enum/bluetooth_bond_status.dart';
import 'package:mytransferapp/src/domain/entities/core_device.dart';

class BluetoothDevice extends CoreDevice {
  final BluetoothBondStatus bondState;

  BluetoothDevice({
    required super.ipAddress,
    required super.name,
    required this.bondState,
  });

  factory BluetoothDevice.fromMap(Map m) => BluetoothDevice(
    name: m['name'] as String? ?? '',
    ipAddress: m['ipAddress'] as String? ?? '',
    bondState: switch (m['bondState'] as String? ?? '') {
      'bonded' => BluetoothBondStatus.bonded,
      'bonding' => BluetoothBondStatus.bonding,
      _ => BluetoothBondStatus.none,
    },
  );
}
