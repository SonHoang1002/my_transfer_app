import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/core/my_color.dart';
import 'package:mytransferapp/core/my_constant.dart';
import 'package:mytransferapp/dao/home_dao.dart';
import 'package:mytransferapp/main.dart';
import 'package:mytransferapp/src/domain/entities/network_info.dart';
import 'package:mytransferapp/src/domain/entities/transfer_state.dart';
import 'package:mytransferapp/src/domain/entities/wifi_device.dart';

class WFindAndSendSheet extends StatefulWidget {
  final MyDAO myDAO;
  const WFindAndSendSheet({super.key, required this.myDAO});

  @override
  State<WFindAndSendSheet> createState() => _WFindAndSendSheetState();
}

class _WFindAndSendSheetState extends State<WFindAndSendSheet> {
  late Stream<List<WifiDevice>> deviceSub;
  late NetworkInfo networkInfo;
  bool _isLoading = true, _requesting = false;

  ValueNotifier<List<WifiDevice>> vListRequestWifiDevice = ValueNotifier([]);
  late Stream<TransferState?> listTransferState;
  @override
  void initState() {
    deviceSub = transferInstance.wifiDevicesStream;
    listTransferState = transferInstance.transferStream;
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      networkInfo = await transferInstance.getNetworkInfo();
      transferInstance.startWifiScan();
      setState(() {
        _isLoading = false;
      });
    });
  }

  @override
  void dispose() {
    transferInstance.stopWifiScan();
    super.dispose();
  }

  Future<void> _onRequest() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
    });
    transferInstance.requestSendFileToMultiple(
      devices: vListRequestWifiDevice,
      listFilePath: widget.myDAO.getlistSendFilePath,
    );
    
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: transparent,
      body: Container(
        height: 500,
        decoration: BoxDecoration(
          color: white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        padding: EdgeInsets.only(
          top: 20,
          left: 10,
          right: 10,
          bottom: MediaQuery.viewPaddingOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Send to",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: black,
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: black005,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: InkWell(
                        onTap: () async {
                          await transferInstance.stopWifiScan();
                          await transferInstance.startWifiScan();
                        },
                        child: Text("Refresh", style: TextStyle(color: black)),
                      ),
                    ),
                    Container(
                      height: 44,
                      width: 44,
                      decoration: BoxDecoration(
                        color: black02,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).pop();
                        },
                        child: Center(
                          child: SvgPicture.asset(
                            "${PATH_ICON}ic_close.svg",
                            height: 24,
                            width: 24,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                Container(
                  height: 111,
                  width: double.infinity,
                  color: transparent,
                  child: _isLoading
                      ? CircularProgressIndicator()
                      : StreamBuilder(
                          stream: deviceSub,
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return SizedBox();
                            }
                            List<WifiDevice> wifiDevices = snapshot.data!.where(
                              (element) {
                                return element.ipAddress !=
                                    networkInfo.ipAddress;
                              },
                            ).toList();
                            return ValueListenableBuilder(
                              valueListenable: vListRequestWifiDevice,
                              builder: (context, value, _) {
                                return ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: wifiDevices.length,
                                  itemBuilder: (context, index) {
                                    final data = wifiDevices[index];
                                    final indexSelected = value.indexWhere(
                                      (element) =>
                                          element.ipAddress == data.ipAddress,
                                    );
                                    return _buildDeviceItem(
                                      data: data,
                                      onTap: () {
                                        if (_requesting) return;
                                        if (indexSelected != -1) {
                                          vListRequestWifiDevice.value =
                                              vListRequestWifiDevice.value
                                                  .where(
                                                    (element) =>
                                                        element.ipAddress !=
                                                        data.ipAddress,
                                                  )
                                                  .toList();
                                          return;
                                        }
                                        vListRequestWifiDevice.value = [
                                          ...vListRequestWifiDevice.value,
                                          data,
                                        ];
                                      },
                                      indexSelected: indexSelected,
                                    );
                                  },
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
            _buildRequestButton(),
            // _buildAcceptedDeviceAndConfirm(),
            // _buildTransferProgress(),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestButton() {
    return ValueListenableBuilder(
      valueListenable: vListRequestWifiDevice,
      builder: (context, value, _) {
        return vListRequestWifiDevice.value.isEmpty
            ? SizedBox()
            : _buildButton(
                title: _requesting ? "Requesting" : "Request",
                bgColor: _requesting ? black02 : black,
                onTap: _onRequest,
              );
      },
    );
  }

  Widget _buildAcceptedDeviceAndConfirm() {
    return StreamBuilder(
      stream: listTransferState,
      builder: (context, snapshot) {
        // if (!snapshot.hasData) {
        //   return SizedBox();
        // }
        final listTransferState = snapshot.data;

        return Column(
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(29),
                color: black02,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "${widget.myDAO.vListSelectedFile.value.length} items",
                        style: TextStyle(
                          color: black,
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      ValueListenableBuilder(
                        valueListenable: vListRequestWifiDevice,
                        builder: (context, value, child) {
                          return Text(
                            "${vListRequestWifiDevice.value.length} Devices",
                            style: TextStyle(
                              color: black,
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  Text(
                    "${widget.myDAO.vListSelectedFile.value.length} items",
                    style: TextStyle(
                      color: black02,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            _buildButton(title: "Confirm", bgColor: black, onTap: () {}),
          ],
        );
      },
    );
  }

  Widget _buildTransferProgress() {
    return StreamBuilder(
      stream: listTransferState,
      builder: (context, snapshot) {
        return Container(
          padding: EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(29),
            color: black02,
          ),
          child: Column(
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "${widget.myDAO.vListSelectedFile.value.length} items",
                        style: TextStyle(
                          color: black,
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      ValueListenableBuilder(
                        valueListenable: vListRequestWifiDevice,
                        builder: (context, value, child) {
                          return Text(
                            "${vListRequestWifiDevice.value.length} Devices",
                            style: TextStyle(
                              color: black,
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  Text(
                    "${widget.myDAO.vListSelectedFile.value.length} items",
                    style: TextStyle(
                      color: black02,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16),
              _buildTransferProgressBar(),
              SizedBox(height: 16),
              _buildButton(title: "Stop", bgColor: black02, onTap: () {}),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTransferProgressBar() {
    return Stack(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: black02,
          ),
        ),
      ],
    );
  }

  Widget _buildButton({
    required String title,
    required Color bgColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 370,
        height: 48,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              color: white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceItem({
    required WifiDevice data,
    required void Function() onTap,
    required int indexSelected,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 66,
        margin: EdgeInsets.symmetric(horizontal: 5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(color: grey),
                  ),
                  Positioned.fill(
                    child: Opacity(
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
                  ),
                ],
              ),
            ),
            Text(
              data.name,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: black,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
