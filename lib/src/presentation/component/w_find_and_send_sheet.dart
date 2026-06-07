import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:mytransferapp/core/my_color.dart';
import 'package:mytransferapp/core/my_constant.dart';
import 'package:mytransferapp/dao/home_dao.dart';
import 'package:mytransferapp/src/data/datasources/native/transfer_service.dart';
import 'package:mytransferapp/src/domain/entities/wifi_device.dart';

class WFindAndSendSheet extends StatefulWidget {
  const WFindAndSendSheet({super.key, required MyDAO myDAO});

  @override
  State<WFindAndSendSheet> createState() => _WFindAndSendSheetState();
}

class _WFindAndSendSheetState extends State<WFindAndSendSheet> {
  late Stream<List<WifiDevice>> deviceSub;
  @override
  void initState() {
    deviceSub = TransferService.instance.wifiDevicesStream;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: transparent,
      body: Container(
        height: 500,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
        ),
        padding: EdgeInsets.only(top: 10, left: 5, right: 5),
        child: Column(
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
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: black02,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Center(
                    child: SvgPicture.asset(
                      "${PATH_ICON}ic_close.svg",
                      height: 24,
                      width: 24,
                    ),
                  ),
                ),
              ],
            ),
            Container(
              height: 111,
              width: double.infinity,
              color: red,
              child: StreamBuilder(
                stream: deviceSub,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return SizedBox();
                  }
                  List<WifiDevice> wifiDevices = snapshot.data!;
                  return ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 100,
                    itemBuilder: (context, index) {
                      // final data = wifiDevices[index];
                      return _buildDeviceItem(
                        // data
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceItem(
    // WifiDevice data
  ) {
    return Container(
      width: 66,
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: grey,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          Text("data.name data.ipAddress"),
        ],
      ),
    );
  }
}
