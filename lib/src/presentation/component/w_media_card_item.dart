import 'package:flutter/material.dart';
import 'package:mytransferapp/core/my_color.dart';
import 'package:mytransferapp/core/my_extension.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

class WMediaCardItem extends StatelessWidget {
  final AssetEntity asset;
  final int indexSelected;
  final VoidCallback onTap;

  const WMediaCardItem({
    super.key,
    required this.asset,
    required this.indexSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail
            AssetEntityImage(
              asset,
              isOriginal: false,
              thumbnailSize: const ThumbnailSize.square(200),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: grey.shade200,
                child: Icon(
                  Icons.broken_image_outlined,
                  color: grey.shade400,
                  size: 32,
                ),
              ),
            ),

            // Overlay tối khi selected
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: indexSelected != -1 ? 1.0 : 0.0,
              child: Container(
                color: black.withOpacity(0.4),
                alignment: Alignment.center,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: blue.shade600,
                    shape: BoxShape.circle,
                    border: Border.all(color: white, width: 2),
                  ),
                  // const Icon(Icons.check, color: white, size: 16),
                  child: Center(
                    child: Text(
                      "${indexSelected + 1}",
                      style: TextStyle(color: white),
                    ),
                  ),
                ),
              ),
            ),

            // Positioned(top: 5, left: 5, child: _buildTypeLabel(asset)),

            // Video duration badge (góc dưới phải)
            if (asset.type == AssetType.video)
              Positioned(
                bottom: 5,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: black.withAlpha(60),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    formatDuration(asset.videoDuration),
                    style: const TextStyle(color: white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Widget _buildTypeLabel(AssetEntity asset) {
  //   final config = _typeLabelConfig(asset);
  //   if (config == null) return const SizedBox.shrink();
  //   return Container(
  //     padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
  //     decoration: BoxDecoration(
  //       color: config.$2.withOpacity(0.85),
  //       borderRadius: BorderRadius.circular(4),
  //     ),
  //     child: Row(
  //       mainAxisSize: MainAxisSize.min,
  //       children: [
  //         Icon(config.$1, size: 10, color: white),
  //         const SizedBox(width: 3),
  //         Text(
  //           config.$3,
  //           style: const TextStyle(
  //             color: white,
  //             fontSize: 9,
  //             fontWeight: FontWeight.w600,
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }
  // // Returns (icon, color, label) cho từng loại asset
  // (IconData, Color, String)? _typeLabelConfig(AssetEntity asset) {
  //   switch (asset.type) {
  //     case AssetType.image:
  //       // Chỉ hiện label nếu không phải ảnh thường (GIF, etc.)
  //       final ext = (asset.title ?? '').split('.').last.toLowerCase();
  //       if (ext == 'gif') {
  //         return (Icons.gif_box_outlined, purple, 'GIF');
  //       }
  //       return null; // ảnh thường không cần label
  //     case AssetType.video:
  //       return (Icons.videocam_rounded, red.shade700, 'VIDEO');
  //     case AssetType.audio:
  //       return (Icons.audiotrack_rounded, orange.shade700, 'AUDIO');
  //     case AssetType.other:
  //       return (Icons.insert_drive_file_outlined, grey.shade700, 'FILE');
  //   }
  // }
}
