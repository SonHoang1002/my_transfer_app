import 'package:custom_sliding_segmented_control/custom_sliding_segmented_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/common/my_color.dart';
import 'package:mytransferapp/common/my_constant.dart';
import 'package:mytransferapp/common/my_extension.dart';
import 'package:mytransferapp/component/skeleton.dart';
import 'package:mytransferapp/dao/home_dao.dart';
import 'package:mytransferapp/enum/home_enum.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final HomeDAO _data = HomeDAO.init();
  final ScrollController _photoScrollController = ScrollController();
  PhotoPermission _permission = PhotoPermission.checking;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAndLoad();
    _photoScrollController.addListener(() {
      final pos = _photoScrollController.position;
      if (pos.maxScrollExtent - pos.pixels < 300) {
        _data.loadMorePhotos();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _permission == PhotoPermission.denied) {
      _checkAndLoad();
    }
  }

  Future<void> _checkAndLoad() async {
    setState(() => _permission = PhotoPermission.checking);
    final result = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (result.isAuth) {
      setState(() => _permission = PhotoPermission.granted);
      await _data.loadInitialPhotos();
    } else if (result == PermissionState.limited) {
      setState(() => _permission = PhotoPermission.limited);
      await _data.loadInitialPhotos();
    } else {
      setState(() => _permission = PhotoPermission.denied);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _photoScrollController.dispose();
    _data.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              _buildDeviceInfor(),
              const SizedBox(height: 12),
              _buildPickerBar(),
              const SizedBox(height: 12),
              _buildFilterChips(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          width: 161,
          height: 44,
          decoration: BoxDecoration(
            color: black005,
            borderRadius: BorderRadius.circular(999),
          ),
          padding: const EdgeInsets.all(5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.only(left: 5),
                child: Text(
                  'iPhone 18',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade900,
                  ),
                ),
              ),
              Container(
                height: 36,
                width: 36,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: black005,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: SvgPicture.asset(
                  "${PATH_ICON}ic_history.svg",
                  height: 24,
                  width: 24,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: black005,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: SvgPicture.asset(
                  "${PATH_ICON}ic_setting.svg",
                  height: 24,
                  width: 24,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDeviceInfor() {
    return ValueListenableBuilder(
      valueListenable: _data.vListSelectedFile,
      builder: (_, value, __) {
        return DeviceInfor(
          listSelectedFile: value,
          onRemove: _data.onRemoveSelectedFile,
          onCancel: _data.onCancel,
          onSend: _data.onSend,
        );
      },
    );
  }

  Widget _buildPickerBar() {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(40),
        child: Container(
          decoration: BoxDecoration(color: black005),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 300,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Center(
                  child: ValueListenableBuilder(
                    valueListenable: _data.vIndexTabGallery,
                    builder: (context, value, child) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: CustomSlidingSegmentedControl<int>(
                          children: {
                            0: _buildTabItem('Photos'),
                            1: _buildTabItem('Collections'),
                          },
                          clipBehavior: Clip.hardEdge,
                          onValueChanged: (int? idx) {
                            _data.onChangeIndexTabGallery(idx!);
                          },
                          padding: 5,
                          thumbDecoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          decoration: BoxDecoration(
                            color: black005,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // ── Sort + Filter row ────────────────────────────────────
              _buildSortFilterRow(),
              const SizedBox(height: 8),
              _buildGridview(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sort + Filter ──────────────────────────────────────────────────
  Widget _buildSortFilterRow() {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          // Sort chips
          ValueListenableBuilder<PhotoSortType>(
            valueListenable: _data.vSortType,
            builder: (_, sortType, __) => Row(
              children: [
                _buildSortChip(
                  label: 'Gần đây',
                  icon: Icons.access_time_rounded,
                  isActive: sortType == PhotoSortType.recent,
                  onTap: () => _data.onChangeSortType(PhotoSortType.recent),
                ),
                const SizedBox(width: 8),
                _buildSortChip(
                  label: 'Lớn nhất',
                  icon: Icons.arrow_downward_rounded,
                  isActive: sortType == PhotoSortType.largest,
                  onTap: () => _data.onChangeSortType(PhotoSortType.largest),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Divider
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(vertical: 5),
            color: Colors.grey.shade300,
          ),
          const SizedBox(width: 8),
          // Filter type chips
          ValueListenableBuilder<PhotoFilterType>(
            valueListenable: _data.vFilterType,
            builder: (_, filterType, __) => Row(
              children: PhotoFilterType.values.map((f) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _buildFilterChip(
                    label: f.label,
                    icon: f.icon,
                    isActive: filterType == f,
                    onTap: () => _data.onChangeFilterType(f),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortChip({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? black : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: isActive ? black : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isActive ? Colors.white : Colors.grey.shade600,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isActive ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? Colors.blue.shade600 : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isActive ? Colors.blue.shade600 : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isActive ? Colors.white : Colors.grey.shade600,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isActive ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabItem(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: black,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildGridview() {
    if (_permission == PhotoPermission.checking) {
      return Expanded(child: _buildSkeletonGrid());
    }

    if (_permission == PhotoPermission.denied) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 12),
              Text(
                'Cần quyền truy cập thư viện ảnh',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () async {
                  final result = await PhotoManager.requestPermissionExtend();
                  if (result.isAuth || result == PermissionState.limited) {
                    _checkAndLoad();
                  } else {
                    PhotoManager.openSetting();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade600,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Cấp quyền truy cập',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Expanded(
      child: ValueListenableBuilder<List<AssetEntity>>(
        valueListenable: _data.vPhotoAssets,
        builder: (context, assets, _) {
          if (assets.isEmpty) {
            return ValueListenableBuilder<bool>(
              valueListenable: _data.vIsLoadingMore,
              builder: (_, loading, __) =>
                  loading ? _buildSkeletonGrid() : const SizedBox.shrink(),
            );
          }

          return ValueListenableBuilder<List<SendFileData>>(
            valueListenable: _data.vListSelectedFile,
            builder: (context, selectedFiles, _) {
              return GridView.builder(
                controller: _photoScrollController,
                scrollDirection: Axis.vertical,
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1,
                ),
                itemCount: assets.length + 1,
                itemBuilder: (context, index) {
                  if (index == assets.length) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: _data.vIsLoadingMore,
                      builder: (_, loading, __) => loading
                          ? const Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    );
                  }
                  final asset = assets[index];
                  final isSelected = selectedFiles.any(
                    (e) => e.uid.toString() == asset.id,
                  );
                  return _PhotoGridItem(
                    asset: asset,
                    isSelected: isSelected,
                    onTap: () => _data.onTogglePhoto(asset),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSkeletonGrid() {
    return GridView.builder(
      scrollDirection: Axis.vertical,
      padding: const EdgeInsets.all(12),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: 12,
      itemBuilder: (_, __) => SkeletonItem(),
    );
  }

  Widget _buildFilterChips() {
    return Flex(
      direction: Axis.horizontal,
      children: [
        _buildQuickActionCard(
          avatar: "ic_file.svg",
          label: "File",
          color: black005,
        ),
        const SizedBox(width: 12),
        _buildQuickActionCard(
          avatar: "ic_gallery.svg",
          label: "Folder",
          color: black005,
        ),
        const SizedBox(width: 12),
        _buildQuickActionCard(
          avatar: "ic_paragraph.svg",
          label: "Text",
          color: black005,
        ),
      ],
    );
  }

  Widget _buildQuickActionCard({
    required String avatar,
    required String label,
    required Color color,
  }) {
    return Flexible(
      flex: 1,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          // mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset("$PATH_ICON$avatar", height: 24, width: 24),
            SizedBox(width: 10),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _PhotoGridItem extends StatelessWidget {
  final AssetEntity asset;
  final bool isSelected;
  final VoidCallback onTap;

  const _PhotoGridItem({
    required this.asset,
    required this.isSelected,
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
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey.shade200,
                child: Icon(
                  Icons.broken_image_outlined,
                  color: Colors.grey.shade400,
                  size: 32,
                ),
              ),
            ),

            // Overlay tối khi selected
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: isSelected ? 1.0 : 0.0,
              child: Container(
                color: Colors.black.withOpacity(0.4),
                alignment: Alignment.center,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.blue.shade600,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 16),
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
                    color: Colors.black.withAlpha(60),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    formatDuration(asset.videoDuration),
                    style: const TextStyle(color: Colors.white, fontSize: 10),
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
  //         Icon(config.$1, size: 10, color: Colors.white),
  //         const SizedBox(width: 3),
  //         Text(
  //           config.$3,
  //           style: const TextStyle(
  //             color: Colors.white,
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
  //         return (Icons.gif_box_outlined, Colors.purple, 'GIF');
  //       }
  //       return null; // ảnh thường không cần label
  //     case AssetType.video:
  //       return (Icons.videocam_rounded, Colors.red.shade700, 'VIDEO');
  //     case AssetType.audio:
  //       return (Icons.audiotrack_rounded, Colors.orange.shade700, 'AUDIO');
  //     case AssetType.other:
  //       return (Icons.insert_drive_file_outlined, Colors.grey.shade700, 'FILE');
  //   }
  // }
}

class DeviceInfor extends StatefulWidget {
  final List<SendFileData> listSelectedFile;
  final void Function(int id) onRemove;
  final VoidCallback? onCancel;
  final VoidCallback? onSend;

  const DeviceInfor({
    super.key,
    required this.listSelectedFile,
    required this.onRemove,
    this.onCancel,
    this.onSend,
  });

  @override
  State<DeviceInfor> createState() => _DeviceInforState();
}

class _DeviceInforState extends State<DeviceInfor>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _heightAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _headerPaddingAnimation;
  late Animation<double> _headerFontSizeAnimation;
  late Animation<double> _iconOpacityAnimation;

  static const double _collapsedHeight = 118; // Khi không có file
  static const double _expandedHeight = 280; // Khi có file (mở rộng)
  static const double _headerHeight = 61; // Chiều cao header khi có file

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
    _headerPaddingAnimation = Tween<double>(begin: 27, end: 8).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Animation cho font size của header
    _headerFontSizeAnimation = Tween<double>(begin: 20, end: 16).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Animation cho opacity của icon edit (biến mất khi có file)
    _iconOpacityAnimation = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Mở rộng nếu có file
    if (widget.listSelectedFile.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _animationController.forward();
      });
    }
  }

  @override
  void didUpdateWidget(DeviceInfor oldWidget) {
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
              // Header Row - thay đổi animation
              Container(
                height: _headerHeight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "Device Info",
                      style: TextStyle(
                        fontSize: _headerFontSizeAnimation.value,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Opacity(
                      opacity: _iconOpacityAnimation.value,
                      child: SvgPicture.asset(
                        "${PATH_ICON}ic_edit.svg",
                        height: 24,
                        width: 24,
                      ),
                    ),
                  ],
                ),
              ),

              // File List Section (chỉ hiển thị khi có file)
              if (widget.listSelectedFile.isNotEmpty)
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    children: [
                      const SizedBox(height: 16),

                      // Horizontal File List
                      SizedBox(
                        height: 80,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.listSelectedFile.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 12),
                          itemBuilder: (context, index) {
                            final file = widget.listSelectedFile[index];
                            return _buildFileItem(file);
                          },
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Action Buttons
                      FadeTransition(
                        opacity: _fadeAnimation,
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildActionButton(
                                label: "Cancel",
                                icon: Icons.close,
                                color: Colors.grey,
                                onPressed: widget.onCancel,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildActionButton(
                                label: "Send",
                                icon: Icons.send,
                                color: Colors.blue,
                                onPressed: widget.onSend,
                              ),
                            ),
                          ],
                        ),
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

  Widget _buildFileItem(SendFileData file) {
    return Container(
      width: 70,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: black005, blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // File Icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _getFileColor(file).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _getFileIcon(file),
                  color: _getFileColor(file),
                  size: 24,
                ),
              ),
              const SizedBox(height: 4),
              // File Name
              Text(
                _getFileName(file.path),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // File Size
              // Text(
              //   _formatFileSize(file.),
              //   style: TextStyle(fontSize: 8, color: Colors.grey.shade500),
              // ),
            ],
          ),
          // Remove Button
          Positioned(
            right: 4,
            top: 4,
            child: GestureDetector(
              onTap: () => widget.onRemove(file.uid),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 12, color: Colors.white),
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
    required Color color,
    VoidCallback? onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
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
        return Colors.blue;
      case 'mp4':
      case 'mov':
        return Colors.purple;
      case 'pdf':
        return Colors.red;
      case 'doc':
      case 'docx':
        return Colors.blue.shade700;
      case 'zip':
      case 'rar':
        return Colors.orange;
      default:
        return Colors.grey;
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
