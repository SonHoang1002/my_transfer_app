import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:mytransferapp/my_app.dart';
import 'package:mytransferapp/src/data/datasources/native/transfer_service.dart'; 


TransferService transferInstance = TransferService.instance;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('vi')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('vi'),
      child: const MyApp(),
    ),
  );
}
