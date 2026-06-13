import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mytransferapp/enum/transfer_status.dart';
import 'package:mytransferapp/src/domain/entities/transfer_state.dart';

class WTransferProgressSheet extends StatefulWidget {
  final Stream<List<TransferState>> transferStream;

  const WTransferProgressSheet({super.key, required this.transferStream});

  @override
  State<WTransferProgressSheet> createState() => _WTransferProgressSheetState();
}

class _WTransferProgressSheetState extends State<WTransferProgressSheet> {
  late StreamSubscription<List<TransferState>> _sub;
  List<TransferState> _transfers = [];
  bool _everHadData = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.transferStream.listen((data) {
      if (!mounted) return;
      setState(() => _transfers = data);

      if (data.isNotEmpty) _everHadData = true;

      // Tất cả transfer đã biến mất (xong hoặc fail) -> tự đóng sheet
      if (_everHadData && data.isEmpty) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) Navigator.of(context).pop();
        });
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Đang truyền file',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (_transfers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Hoàn tất')),
              )
            else
              ..._transfers.map(_buildItem),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(TransferState t) {
    final progress = (t.progress.clamp(0, 100)) / 100.0;
    final directionLabel = t.isIncoming ? 'Nhận từ' : 'Gửi đến';

    Color statusColor;
    switch (t.status) {
      case 'SUCCESS':
        statusColor = Colors.green;
        break;
      case 'FAILED':
        statusColor = Colors.red;
        break;
      default:
        statusColor = Colors.blue;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$directionLabel ${t.peerName}',
            style: const TextStyle(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            t.fileName,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              color: statusColor,
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_statusText(t), style: TextStyle(fontSize: 12, color: statusColor)),
              if (t.status == 'TRANSFERRING')
                Text(
                  '${t.speedMbps.toStringAsFixed(2)} MB/s',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusText(TransferState t) {
    switch (t.status) {
      case TransferStatus.connecting:
        return 'Đang kết nối...';
      case TransferStatus.transferring:
        return '${t.progress}%';
      case TransferStatus.success:
        return 'Hoàn tất';
      case TransferStatus.failed:
        return 'Lỗi: ${t.error}';
      default:
        return "Idle";
    }
  }
}