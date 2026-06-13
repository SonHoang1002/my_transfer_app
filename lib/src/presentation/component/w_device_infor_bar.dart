import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/core/my_color.dart';
import 'package:mytransferapp/core/my_constant.dart';
import 'package:mytransferapp/dao/home_dao.dart';
import 'package:mytransferapp/main.dart';
import 'package:mytransferapp/src/domain/entities/device_entity/current_device.dart';
import 'package:mytransferapp/src/domain/entities/device_entity/target_device.dart';

class WDeviceInfor extends StatefulWidget {
  final List<SendFileData> listSelectedFile;
  final MyDAO data;

  const WDeviceInfor({
    super.key,
    required this.listSelectedFile,
    required this.data,
  });

  @override
  State<WDeviceInfor> createState() => _WDeviceInforState();
}

class _WDeviceInforState extends State<WDeviceInfor>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _heightAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _headerPaddingAnimation;
  late Animation<double> _iconOpacityAnimation;

  static const double _collapsedHeight = 118;
  static const double _expandedHeight = 229;

  List<SendFileData> get reverseListSelectedFile =>
      widget.listSelectedFile.reversed.toList();

  late CurrentDevice currentDevice;

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Animation chiều cao tổng thể
    _heightAnimation =
        Tween<double>(begin: _collapsedHeight, end: _expandedHeight).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        );

    // Animation fade cho nội dung bên dưới
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.2, 0.6, curve: Curves.easeIn),
      ),
    );

    // Animation cho padding của header (thu nhỏ khi có file)
    _headerPaddingAnimation =
        Tween<double>(
          begin: (_heightAnimation.value - 61) / 2,
          end: 10,
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        );

    // Animation cho opacity của icon edit (biến mất khi có file)
    _iconOpacityAnimation = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Mở rộng nếu có file
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.listSelectedFile.isNotEmpty) {
        _animationController.forward();
      }
      currentDevice = await transferInstance.getCurrentDeviceInfo();
      setState(() {
        _isLoading = false;
      });
    });
  }

  @override
  void didUpdateWidget(WDeviceInfor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Xử lý animation khi danh sách thay đổi
    if (widget.listSelectedFile.isNotEmpty &&
        !_animationController.isAnimating) {
      if (_animationController.status != AnimationStatus.forward) {
        _animationController.forward();
      }
    } else if (widget.listSelectedFile.isEmpty &&
        !_animationController.isAnimating) {
      if (_animationController.status != AnimationStatus.reverse) {
        _animationController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return Container(
          width: 370,
          height: _heightAnimation.value,
          decoration: BoxDecoration(
            color: black005,
            borderRadius: BorderRadius.circular(40),
          ),
          padding: EdgeInsets.all(_headerPaddingAnimation.value),
          child: Column(
            children: [
              Container(
                height: 61,
                decoration: BoxDecoration(
                  color: black.withValues(
                    alpha: (1 - _iconOpacityAnimation.value) * 0.05,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: _isLoading
                    ? Center(child: CircularProgressIndicator())
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          Text(
                            currentDevice.name,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: black,
                            ),
                          ),

                          // const SizedBox(width: 10),
                          // Opacity(
                          //   opacity: _iconOpacityAnimation.value,
                          //   child: SvgPicture.asset(
                          //     "${PATH_ICON}ic_edit.svg",
                          //     height: 24,
                          //     width: 24,
                          //   ),
                          // ),
                        ],
                      ),
              ),

              // File List Section (chỉ hiển thị khi có file)
              if (widget.listSelectedFile.isNotEmpty)
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    children: [
                      SizedBox(height: 16),
                      SizedBox(
                        height: 68,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.listSelectedFile.length,
                          itemBuilder: (context, index) {
                            final fileData = widget.listSelectedFile[index];
                            int indexSelected = widget.listSelectedFile
                                .indexWhere(
                                  (element) => element.uid == fileData.uid,
                                );
                            return _buildFileItem(fileData, indexSelected);
                          },
                        ),
                      ),
                      SizedBox(height: 16),
                      Flex(
                        direction: Axis.horizontal,
                        children: [
                          Flexible(
                            child: _buildActionButton(
                              label: "Cancel",
                              icon: Icons.close,
                              bgColor: black01,
                              textColor: black,
                              onPressed: widget.data.onRemoveAllSelectedFile,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: _buildActionButton(
                              label: "Demo",
                              icon: Icons.send,
                              bgColor: black,
                              textColor: white,
                              onPressed: () {
                                widget.data.onDemo(context);
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: _buildActionButton(
                              label: "Send",
                              icon: Icons.send,
                              bgColor: black,
                              textColor: white,
                              onPressed: () {
                                widget.data.onSend(context);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFileItem(SendFileData fileData, int indexSelected) {
    return SizedBox(
      height: 68,
      width: 68,
      child: Stack(
        children: [
          Positioned(
            bottom: 0,
            left: 0,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: grey,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  "${indexSelected + 1}",
                  style: TextStyle(color: white),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              onTap: () => widget.data.onRemoveSelectedFile(fileData.uid),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: black,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Center(
                  child: Container(
                    width: 13.33,
                    height: 3.33,
                    decoration: BoxDecoration(
                      color: white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color bgColor,
    Color? textColor,
    VoidCallback? onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 48,
        width: 171,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icon(icon, color: white, size: 18),
            // const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w600,
                fontSize: 17,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFileIcon(SendFileData file) {
    final extension = file.path.split('.').last.toLowerCase();
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'heic':
        return Icons.image;
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return Icons.video_library;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(SendFileData file) {
    final extension = file.path.split('.').last.toLowerCase();
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return blue;
      case 'mp4':
      case 'mov':
        return purple;
      case 'pdf':
        return red;
      case 'doc':
      case 'docx':
        return blue.shade700;
      case 'zip':
      case 'rar':
        return orange;
      default:
        return grey;
    }
  }

  String _getFileName(String path) {
    final name = path.split('/').last;
    if (name.length > 12) {
      return '${name.substring(0, 10)}...';
    }
    return name;
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null || bytes == 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    var size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }
}
