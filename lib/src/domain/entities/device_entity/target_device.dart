import 'package:mytransferapp/src/domain/entities/device_entity/core_device.dart';

enum ScanMode { WIFI, BLUETOOTH }

class TargetDevice extends CoreDevice {
  final int port;
  final ScanMode from;
  final int lastSeen;
  final String? address;
  final String? bondState;
  final int totalFiles;
  final int? requestId;

  TargetDevice({
    required super.name,
    required super.ipAddress,
    required this.port,
    required this.from,
    required this.lastSeen,
    required this.address,
    required this.bondState,
    this.totalFiles = 0,
    this.requestId,
  });

  String get getScanModeLabel {
    if (from == ScanMode.WIFI) {
      return "W";
    } else {
      return "B";
    }
  }

  // Kiểm tra thiết bị còn hoạt động không (trong vòng 10 giây)
  bool get isAlive {
    const timeoutMs = 10000;
    return DateTime.now().millisecondsSinceEpoch - lastSeen < timeoutMs;
  }

  // Định dạng thời gian lastSeen
  String get formattedLastSeen {
    final now = DateTime.now();
    final lastSeenDate = DateTime.fromMillisecondsSinceEpoch(lastSeen);
    final diff = now.difference(lastSeenDate);

    if (diff.inSeconds < 60) {
      return "Vừa xong";
    } else if (diff.inMinutes < 60) {
      return "${diff.inMinutes} phút trước";
    } else if (diff.inHours < 24) {
      return "${diff.inHours} giờ trước";
    } else {
      return "${diff.inDays} ngày trước";
    }
  }

  // Kiểm tra có requestId không
  bool get hasRequestId => requestId != null;

  // Kiểm tra có file để gửi không
  bool get hasFilesToSend => totalFiles > 0;

  // Format số lượng file
  String get totalFilesFormatted {
    if (totalFiles == 0) return "Không có file";
    if (totalFiles == 1) return "1 file";
    return "$totalFiles files";
  }

  factory TargetDevice.fromMap(Map m) => TargetDevice(
    ipAddress: m['ipAddress'] as String? ?? '',
    name: m['name'] as String? ?? '',
    port: m['port'] as int? ?? 0,
    from: ScanMode.values[m['fromIndex'] as int? ?? 0],
    lastSeen: m['lastSeen'] as int? ?? 0,
    address: m['address'] as String?,
    bondState: m['bondState'] as String?,
    totalFiles: m['totalFiles'] as int? ?? 0,
    requestId: m['requestId'] as int?,
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'ipAddress': ipAddress,
    'port': port,
    'fromIndex': from.index,
    'lastSeen': lastSeen,
    'address': address,
    'bondState': bondState,
    'totalFiles': totalFiles,
    'requestId': requestId,
  };

  @override
  String toString() {
    return 'TargetDevice{'
        'name: $name, '
        'ipAddress: $ipAddress, '
        'port: $port, '
        'from: ${from.name}, '
        'lastSeen: $lastSeen (${formattedLastSeen}), '
        'isAlive: $isAlive, '
        'address: $address, '
        'bondState: $bondState, '
        'totalFiles: $totalFiles, '
        'requestId: $requestId'
        '}';
  }

  static TargetDevice createDemo() {
    return TargetDevice(
      name: "Demo Name",
      ipAddress: "192.168.232.32",
      port: 10000,
      from: ScanMode.WIFI,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
      address: "Demo Address",
      bondState: "Demo BondState",
      totalFiles: 5,
      requestId: null,
    );
  }

  // Copy với các giá trị mới
  TargetDevice copyWith({
    String? name,
    String? ipAddress,
    int? port,
    ScanMode? from,
    int? lastSeen,
    String? address,
    String? bondState,
    int? totalFiles,
    int? requestId,
  }) {
    return TargetDevice(
      name: name ?? this.name,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      from: from ?? this.from,
      lastSeen: lastSeen ?? this.lastSeen,
      address: address ?? this.address,
      bondState: bondState ?? this.bondState,
      totalFiles: totalFiles ?? this.totalFiles,
      requestId: requestId ?? this.requestId,
    );
  }
}
