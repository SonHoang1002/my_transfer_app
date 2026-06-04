import 'package:flutter/material.dart';
import 'package:mytransferapp/screen/home.dart'; 

class MyRoutes {
  static String get initialRoute => ROUTE_HOME;

  // ignore: non_constant_identifier_names
  static String get ROUTE_FIND_DEVICE => '/findDevice';

  // ignore: non_constant_identifier_names
  static String get ROUTE_HOME => '/';

  // ignore: non_constant_identifier_names
  static String get DEMO_ROUTE_HOME => '/demo_home';

  static Map<String, Widget Function(BuildContext)> get routes => {
    ROUTE_HOME: (context) =>  HomeScreen(), 
  };
}
