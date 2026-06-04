import 'dart:math';

import 'package:custom_sliding_segmented_control/custom_sliding_segmented_control.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/common/my_color.dart';
import 'package:mytransferapp/common/my_constant.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

enum SendFileType { file, folder, text }

class SendFileData {
  final int uid;
  final String path;
  final SendFileType type;

  SendFileData({required this.uid, required this.path, required this.type});
}

class HomeDAO {
  final ValueNotifier<int> vIndexTabGallery;
  final ValueNotifier<int> vIndexFileTypeFilter;
  final ValueNotifier<List<SendFileData>> vListSelectedFile;

  // Photo Manager (chỉ data, KHÔNG có ScrollController)
  final ValueNotifier<List<AssetEntity>> vPhotoAssets;
  final ValueNotifier<bool> vIsLoadingMore;
  bool _hasMorePhotos = true;
  int _currentPage = 0;
  static const int _pageSize = 30;
  AssetPathEntity? _albumPath;

  HomeDAO({
    required this.vIndexTabGallery,
    required this.vIndexFileTypeFilter,
    required this.vListSelectedFile,
    required this.vPhotoAssets,
    required this.vIsLoadingMore,
  });

  factory HomeDAO.init() {
    return HomeDAO(
      vIndexTabGallery: ValueNotifier(0),
      vIndexFileTypeFilter: ValueNotifier(-1),
      vListSelectedFile: ValueNotifier([]),
      vPhotoAssets: ValueNotifier([]),
      vIsLoadingMore: ValueNotifier(false),
    );
  }

  Future<void> loadInitialPhotos() async {
    final result = await PhotoManager.requestPermissionExtend();
    if (!result.isAuth) return; // không mở setting tự động, để UI xử lý
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (albums.isEmpty) return;
    _albumPath = albums.first;
    _currentPage = 0;
    _hasMorePhotos = true;
    vPhotoAssets.value = [];
    await loadMorePhotos();
  }

  Future<void> loadMorePhotos() async {
    if (!_hasMorePhotos || vIsLoadingMore.value || _albumPath == null) return;
    vIsLoadingMore.value = true;
    final start = _currentPage * _pageSize;
    final end = start + _pageSize;
    final assets = await _albumPath!.getAssetListRange(start: start, end: end);
    if (assets.length < _pageSize) _hasMorePhotos = false;
    _currentPage++;
    vPhotoAssets.value = [...vPhotoAssets.value, ...assets];
    vIsLoadingMore.value = false;
  }

  void onChangeIndexTabGallery(int idx) {
    if (vIndexTabGallery.value == idx) return;
    vIndexTabGallery.value = idx;
  }

  void onChangeIndexFileTypeFilter(int idx) {
    if (vIndexFileTypeFilter.value == idx) return;
    vIndexFileTypeFilter.value = idx;
  }

  bool isSelected(AssetEntity asset) =>
      vListSelectedFile.value.any((e) => e.uid.toString() == asset.id);

  void onTogglePhoto(AssetEntity asset) {
    if (isSelected(asset)) {
      vListSelectedFile.value = vListSelectedFile.value
          .where((e) => e.uid.toString() != asset.id)
          .toList();
    } else {
      vListSelectedFile.value = [
        ...vListSelectedFile.value,
        SendFileData(
          uid: int.tryParse(asset.id) ?? asset.hashCode,
          path: asset.id,
          type: SendFileType.file,
        ),
      ];
    }
  }

  void onRemoveSelectedFile(int uid) {
    vListSelectedFile.value = vListSelectedFile.value
        .where((e) => e.uid != uid)
        .toList();
  }

  void onRemoveAllSelectedFile(int idx) {
    vListSelectedFile.value = [];
  }

  void onAddSelectedFile(String path, SendFileType type) {
    vListSelectedFile.value = [
      ...vListSelectedFile.value,
      SendFileData(
        uid: DateTime.now().millisecondsSinceEpoch,
        path: path,
        type: type,
      ),
    ];
  }

  void dispose() {
    vPhotoAssets.dispose();
    vIsLoadingMore.dispose();
    vIndexTabGallery.dispose();
    vIndexFileTypeFilter.dispose();
    vListSelectedFile.dispose();
  }
}

// ── Permission state ───────────────────────────────────────────────────
enum _PhotoPermission { checking, granted, denied, limited }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final HomeDAO _data = HomeDAO.init();
  final ScrollController _photoScrollController = ScrollController();

  // Trạng thái quyền riêng, không vào DAO
  _PhotoPermission _permission = _PhotoPermission.checking;

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

  // Khi user quay lại app sau khi cấp quyền trong Settings → load lại
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _permission == _PhotoPermission.denied) {
      _checkAndLoad();
    }
  }

  Future<void> _checkAndLoad() async {
    setState(() => _permission = _PhotoPermission.checking);
    final result = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (result.isAuth) {
      setState(() => _permission = _PhotoPermission.granted);
      await _data.loadInitialPhotos();
    } else if (result == PermissionState.limited) {
      setState(() => _permission = _PhotoPermission.limited);
      await _data.loadInitialPhotos();
    } else {
      setState(() => _permission = _PhotoPermission.denied);
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

  Widget _buildQuickActionCard({
    required IconData icon,
    required String label,
    required MaterialColor color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.shade50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.shade100),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: color.shade700),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color.shade700,
              ),
            ),
          ],
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
    return Container(
      width: 370,
      height: 118,
      decoration: BoxDecoration(
        color: black005,
        borderRadius: BorderRadius.circular(40),
      ),
      padding: const EdgeInsets.all(5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            "Device Info",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: black,
            ),
          ),
          const SizedBox(width: 10),
          SvgPicture.asset("${PATH_ICON}ic_edit.svg", height: 24, width: 24),
        ],
      ),
    );
  }

  Widget _buildPickerBar() {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: black005,
          borderRadius: BorderRadius.circular(40),
        ),
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
                          borderRadius: BorderRadius.circular(
                            20,
                          ), // Rounded corners
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
            const SizedBox(height: 12),
            _buildGridview(),
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

  // ── GridView với đủ 3 trạng thái: checking / denied / loaded ─────────
  Widget _buildGridview() {
    // 1. Đang kiểm tra quyền → skeleton shimmer
    if (_permission == _PhotoPermission.checking) {
      return Expanded(child: _buildSkeletonGrid());
    }

    // 2. Bị từ chối → nút yêu cầu quyền
    if (_permission == _PhotoPermission.denied) {
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
                  // Thử xin lại; nếu vĩnh viễn từ chối → mở Settings
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

    // 3. Đã có quyền → hiển thị ảnh (chờ load xong mới show grid)
    return Expanded(
      child: ValueListenableBuilder<List<AssetEntity>>(
        valueListenable: _data.vPhotoAssets,
        builder: (context, assets, _) {
          // Đang load lần đầu (chưa có ảnh nào) → skeleton
          if (assets.isEmpty) {
            return ValueListenableBuilder<bool>(
              valueListenable: _data.vIsLoadingMore,
              builder: (_, loading, __) =>
                  loading ? _buildSkeletonGrid() : const SizedBox.shrink(),
            );
          }

          // Đã có ảnh → hiển thị grid
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

  // Skeleton shimmer khi đang load
  Widget _buildSkeletonGrid() {
    return GridView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: 10,
      itemBuilder: (_, __) => _SkeletonItem(),
    );
  }

  Widget _buildFilterChips() {
    return Row(
      children: [
        _buildQuickActionCard(
          icon: Icons.insert_drive_file,
          label: 'File',
          color: Colors.blue,
        ),
        const SizedBox(width: 12),
        _buildQuickActionCard(
          icon: Icons.folder,
          label: 'Folder',
          color: Colors.orange,
        ),
        const SizedBox(width: 12),
        _buildQuickActionCard(
          icon: Icons.description,
          label: 'Text',
          color: Colors.purple,
        ),
      ],
    );
  }
}

// ── Skeleton item ──────────────────────────────────────────────────────
class _SkeletonItem extends StatefulWidget {
  @override
  State<_SkeletonItem> createState() => _SkeletonItemState();
}

class _SkeletonItemState extends State<_SkeletonItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(color: Colors.grey.shade300),
      ),
    );
  }
}

// ── Photo grid item ────────────────────────────────────────────────────
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

            // Video duration badge
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
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _formatDuration(asset.videoDuration),
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
