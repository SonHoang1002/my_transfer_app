import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mytransferapp/core/my_extension.dart';
import 'package:mytransferapp/src/presentation/component/w_find_and_send_sheet.dart';
import 'package:mytransferapp/enum/home_enum.dart';
import 'package:photo_manager/photo_manager.dart';

class SendFileData {
  final int uid;
  final String path;
  final SendFileType type;

  SendFileData({required this.uid, required this.path, required this.type});
}

class MyDAO {
  final ValueNotifier<int> vIndexTabGallery;
  final ValueNotifier<int> vIndexFileTypeFilter;
  final ValueNotifier<List<SendFileData>> vListSelectedFile;

  // Photo Manager
  final ValueNotifier<List<AssetEntity>> vPhotoAssets;
  final ValueNotifier<bool> vIsLoadingMore;

  // Sort & Filter state
  final ValueNotifier<PhotoSortType> vSortType;
  final ValueNotifier<PhotoFilterType> vFilterType;

  bool _hasMorePhotos = true;
  int _currentPage = 0;
  static const int _pageSize = 30;
  AssetPathEntity? _albumPath;

  MyDAO({
    required this.vIndexTabGallery,
    required this.vIndexFileTypeFilter,
    required this.vListSelectedFile,
    required this.vPhotoAssets,
    required this.vIsLoadingMore,
    required this.vSortType,
    required this.vFilterType,
  });

  factory MyDAO.init() {
    return MyDAO(
      vIndexTabGallery: ValueNotifier(0),
      vIndexFileTypeFilter: ValueNotifier(-1),
      vListSelectedFile: ValueNotifier([]),
      vPhotoAssets: ValueNotifier([]),
      vIsLoadingMore: ValueNotifier(false),
      vSortType: ValueNotifier(PhotoSortType.recent),
      vFilterType: ValueNotifier(PhotoFilterType.all),
    );
  }

  void onSend(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return WFindAndSendSheet(myDAO: this);
      },
    );
  }

  List<String> get getlistSendFilePath =>
      vListSelectedFile.value.map((e) => e.path).toList();

  Future<void> loadInitialPhotos() async {
    final result = await PhotoManager.requestPermissionExtend();
    if (!result.isAuth) return;
    await _reloadWithCurrentFilter();
  }

  // Reload lại từ đầu theo filter + sort hiện tại
  Future<void> _reloadWithCurrentFilter() async {
    final filterType = vFilterType.value;
    final sortType = vSortType.value;

    final filterOption = FilterOptionGroup(
      imageOption: const FilterOption(
        sizeConstraint: SizeConstraint(ignoreSize: true),
      ),
      videoOption: const FilterOption(
        sizeConstraint: SizeConstraint(ignoreSize: true),
      ),
      orders: [
        OrderOption(
          type: sortType == PhotoSortType.recent
              ? OrderOptionType.createDate
              : OrderOptionType.updateDate,
          asc: false,
        ),
      ],
    );

    final albums = await PhotoManager.getAssetPathList(
      type: filterType.requestType,
      onlyAll: true,
      filterOption: filterOption,
    );

    if (albums.isEmpty) {
      vPhotoAssets.value = [];
      return;
    }

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

    List<AssetEntity> assets = await _albumPath!.getAssetListRange(
      start: start,
      end: end,
    );

    // Sort theo dung lượng file (file size) - từ lớn đến nhỏ
    // if (vSortType.value == PhotoSortType.largest) {
    //   assets = [...assets]
    //     ..sort((a, b) async {
    //       final aSize = await (await a.file).length();
    //       final bSize = b.originBytes;
    //       return bSize.compareTo(aSize);
    //     });
    // }

    // Check nếu muốn lấy dung lượng file real (có thể dùng thêm)
    // for (var asset in assets) {
    //   final fileSize = await asset.originBytes?.length;
    //   print('File: ${asset.title}, Size: ${fileSize ?? asset.size} bytes');
    // }

    if (assets.length < _pageSize) _hasMorePhotos = false;
    _currentPage++;
    vPhotoAssets.value = [...vPhotoAssets.value, ...assets];
    vIsLoadingMore.value = false;
  }

  // Đổi sort → reload
  Future<void> onChangeSortType(PhotoSortType type) async {
    if (vSortType.value == type) return;
    vSortType.value = type;
    await _reloadWithCurrentFilter();
  }

  // Đổi filter → reload
  Future<void> onChangeFilterType(PhotoFilterType type) async {
    if (vFilterType.value == type) return;
    vFilterType.value = type;
    await _reloadWithCurrentFilter();
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

  void onRemoveAllSelectedFile() {
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
    vSortType.dispose();
    vFilterType.dispose();
  }
}
