import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/core/my_color.dart';
import 'package:mytransferapp/core/my_constant.dart';
import 'package:mytransferapp/main.dart';
import 'package:mytransferapp/src/domain/entities/device_infor.dart';
import 'package:mytransferapp/src/domain/entities/network_info.dart';
import 'package:mytransferapp/src/domain/entities/wifi_device.dart';

class WRequestSheet extends StatefulWidget {
  final DeviceInfo deviceInfor;
  final void Function() onAccept;
  final void Function() onCancel;
  const WRequestSheet({
    super.key,
    required this.deviceInfor,
    required this.onAccept,
    required this.onCancel,
  });

  @override
  State<WRequestSheet> createState() => _WRequestSheetState();
}

class _WRequestSheetState extends State<WRequestSheet> {
  late NetworkInfo networkInfo;
  bool _isLoading = true;
  @override
  void initState() {
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
                      "Request",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: black,
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
              ],
            ),
            _buildInfo(),
            _buildButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo() {
    return Column(
      children: [
        Text(
          "${widget.deviceInfor.name}send you 11000 items",
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            color: black,
          ),
        ),
        Text(
          "11000 items",
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: black02,
          ),
        ),
      ],
    );
  }

  Widget _buildButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildButton(
          title: "Cancel",
          bgColor: black02,
          textColor: black,
          onTap: widget.onCancel,
        ),
        SizedBox(width: 16),
        _buildButton(title: "Accept", bgColor: black, onTap: widget.onAccept),
      ],
    );
  }

  Widget _buildButton({
    required String title,
    required Color bgColor,
    required VoidCallback onTap,
    Color textColor = white,
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
              color: textColor,
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
