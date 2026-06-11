import 'dart:async';

import 'package:custom_sliding_segmented_control/custom_sliding_segmented_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/core/my_color.dart';
import 'package:mytransferapp/core/my_constant.dart';
import 'package:mytransferapp/core/my_extension.dart';
import 'package:mytransferapp/enum/photo_permission_status.dart';
import 'package:mytransferapp/main.dart';
import 'package:mytransferapp/src/domain/entities/device_infor.dart';
import 'package:mytransferapp/src/domain/entities/network_info.dart';
import 'package:mytransferapp/src/presentation/component/w_request_sheet.dart';
import 'package:mytransferapp/src/presentation/component/w_skeleton.dart';
import 'package:mytransferapp/src/presentation/component/w_device_infor_bar.dart';
import 'package:mytransferapp/src/presentation/component/w_media_card_item.dart';
import 'package:mytransferapp/dao/home_dao.dart';
import 'package:mytransferapp/enum/home_enum.dart';
import 'package:photo_manager/photo_manager.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final MyDAO _data = MyDAO.init();
  final ScrollController _photoScrollController = ScrollController();
  PhotoPermission _permission = PhotoPermission.checking;
  StreamSubscription<DeviceInfo>? _incomingRequestSub;
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
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      transferInstance.requestPermissions();
      _listenIncomingRequest();
    });
  }

  void _listenIncomingRequest() {
    _incomingRequestSub = transferInstance.incomingRequestStream.listen((
      deviceInfor
    ) {
      if (!mounted) return;
      _showRequestSheet(deviceInfor);
    });
  }

  // ✅ Mở request sheet khi có request đến
  void _showRequestSheet(DeviceInfo deviceInfor) {
    // Tránh mở nhiều sheet cùng lúc nếu nhiều request đến
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: transparent,
      isDismissible: false, // user phải chọn Accept hoặc Cancel
      builder: (_) => WRequestSheet(
        deviceInfor: deviceInfor,
        onAccept: () {
          Navigator.of(context).pop();
        },
        onCancel: () {
          Navigator.of(context).pop();
          transferInstance.cancelTransfer();
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingRequestSub?.cancel();
    _photoScrollController.dispose();
    transferInstance.stopReceiveServer();
    _data.dispose();
    super.dispose();
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: white,
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
                    color: grey.shade900,
                  ),
                ),
              ),
              Container(
                height: 36,
                width: 36,
                decoration: BoxDecoration(
                  color: white,
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
      builder: (_, value, _) {
        return WDeviceInfor(listSelectedFile: value, data: _data);
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
                width: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Center(
                  child: ValueListenableBuilder(
                    valueListenable: _data.vIndexTabGallery,
                    builder: (context, value, child) {
                      return CustomSlidingSegmentedControl<int>(
                        children: {
                          0: _buildTabItem('Photos'),
                          1: _buildTabItem('Collections'),
                        },
                        clipBehavior: Clip.hardEdge,
                        onValueChanged: (int? idx) {
                          _data.onChangeIndexTabGallery(idx!);
                        },
                        padding: 8,
                        thumbDecoration: BoxDecoration(
                          color: white,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        decoration: BoxDecoration(
                          color: black005,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        customSegmentSettings: CustomSegmentSettings(
                          borderRadius: BorderRadius.circular(999),
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
            builder: (_, sortType, _) => Row(
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
            color: grey.shade300,
          ),
          const SizedBox(width: 8),
          // Filter type chips
          ValueListenableBuilder<PhotoFilterType>(
            valueListenable: _data.vFilterType,
            builder: (_, filterType, _) => Row(
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
          color: isActive ? black : white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: isActive ? black : grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isActive ? white : grey.shade600),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isActive ? white : grey.shade700,
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
          color: isActive ? blue.shade600 : white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: isActive ? blue.shade600 : grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isActive ? white : grey.shade600),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isActive ? white : grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabItem(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(999)),
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
                color: grey.shade400,
              ),
              const SizedBox(height: 12),
              Text(
                'Cần quyền truy cập thư viện ảnh',
                style: TextStyle(fontSize: 14, color: grey.shade600),
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
                    color: blue.shade600,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Cấp quyền truy cập',
                    style: TextStyle(
                      color: white,
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
              builder: (_, loading, _) =>
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
                      builder: (_, loading, _) => loading
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
                  final indexSelected = selectedFiles.indexWhere(
                    (e) => e.uid.toString() == asset.id,
                  );
                  return WMediaCardItem(
                    asset: asset,
                    indexSelected: indexSelected,
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
      itemBuilder: (_, _) => WSkeleton(),
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset("$PATH_ICON$avatar", height: 24, width: 24),
            SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
