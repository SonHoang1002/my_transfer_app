import 'package:flutter/material.dart';
import 'package:mytransferapp/enum/home_enum.dart';
import 'package:photo_manager/photo_manager.dart';

extension IntExtension on int {
  Duration get ms => Duration(milliseconds: this);
}

extension PhotoFilterTypeExt on PhotoFilterType {
  String get label {
    switch (this) {
      case PhotoFilterType.all:
        return 'Tất cả';
      case PhotoFilterType.image:
        return 'Ảnh';
      case PhotoFilterType.video:
        return 'Video';
      case PhotoFilterType.audio:
        return 'Âm thanh';
    }
  }

  RequestType get requestType {
    switch (this) {
      case PhotoFilterType.all:
        return RequestType.all;
      case PhotoFilterType.image:
        return RequestType.image;
      case PhotoFilterType.video:
        return RequestType.video;
      case PhotoFilterType.audio:
        return RequestType.audio;
    }
  }

  IconData get icon {
    switch (this) {
      case PhotoFilterType.all:
        return Icons.apps;
      case PhotoFilterType.image:
        return Icons.image_outlined;
      case PhotoFilterType.video:
        return Icons.videocam_outlined;
      case PhotoFilterType.audio:
        return Icons.audiotrack_outlined;
    }
  }
}

String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}
