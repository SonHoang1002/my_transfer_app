enum TransferStatus { idle, connecting, transferring, success, failed }

extension TransferStatusParsing on TransferStatus {
  static TransferStatus fromRaw(String? raw) {
    switch (raw) {
      case 'CONNECTING':
        return TransferStatus.connecting;
      case 'TRANSFERRING':
        return TransferStatus.transferring;
      case 'SUCCESS':
        return TransferStatus.success;
      case 'FAILED':
        return TransferStatus.failed;
      default:
        return TransferStatus.idle;
    }
  }

  bool get isFinished =>
      this == TransferStatus.success || this == TransferStatus.failed;
}

