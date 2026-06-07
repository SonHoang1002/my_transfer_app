import 'package:mytransferapp/enum/transfer_status.dart';

class TransferState {
  final int id;
  final String fileName;
  final int totalBytes;
  final int bytesTransferred;
  final int progress; // 0–100
  final double speedMbps;
  final bool isIncoming;
  final String peerName;
  final TransferStatus status;
  final String? error;

  const TransferState({
    required this.id,
    required this.fileName,
    required this.totalBytes,
    required this.bytesTransferred,
    required this.progress,
    required this.speedMbps,
    required this.isIncoming,
    required this.peerName,
    required this.status,
    this.error,
  });

  factory TransferState.fromMap(Map m) => TransferState(
        id: m['id'] as int? ?? 0,
        fileName: m['fileName'] as String? ?? '',
        totalBytes: (m['totalBytes'] as num?)?.toInt() ?? 0,
        bytesTransferred: (m['bytesTransferred'] as num?)?.toInt() ?? 0,
        progress: m['progress'] as int? ?? 0,
        speedMbps: (m['speedMbps'] as num?)?.toDouble() ?? 0.0,
        isIncoming: m['isIncoming'] as bool? ?? false,
        peerName: m['peerName'] as String? ?? '',
        status: _parseStatus(m['status'] as String? ?? ''),
        error: (m['error'] as String?)?.isEmpty == true ? null : m['error'] as String?,
      );

  static TransferStatus _parseStatus(String s) => switch (s) {
        'CONNECTING'   => TransferStatus.connecting,
        'TRANSFERRING' => TransferStatus.transferring,
        'SUCCESS'      => TransferStatus.success,
        'FAILED'       => TransferStatus.failed,
        _              => TransferStatus.idle,
      };

  double get progressFraction => progress / 100.0;

  String get fileSizeFormatted => _readableSize(totalBytes);
  String get transferredFormatted => _readableSize(bytesTransferred);

  static String _readableSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (bytes == 0) ? 0 : (bytes.bitLength - 1) ~/ 10;
    final val = bytes / (1 << (i * 10));
    return '${val.toStringAsFixed(1)} ${units[i]}';
  }
}

