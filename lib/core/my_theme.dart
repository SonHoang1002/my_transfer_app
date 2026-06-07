import 'package:flutter/material.dart';
import 'package:mytransferapp/core/my_color.dart';


class MyThemes {
  static final lightTheme = ThemeData(
    bottomAppBarTheme: const BottomAppBarThemeData(),
    tabBarTheme: const TabBarThemeData(),
    primaryColor: primaryLight,
    disabledColor: white.withValues(alpha: 0.6),
    // input back ground
    appBarTheme: const AppBarTheme(
      foregroundColor: adaptiveLight,
      backgroundColor: backgroundLight,
      surfaceTintColor: labelLight,
      shadowColor: paleBlueLight,
    ),
    chipTheme: const ChipThemeData(backgroundColor: strokeLight),
    scaffoldBackgroundColor: background2Light,
    badgeTheme: const BadgeThemeData(backgroundColor: black005),
    sliderTheme: const SliderThemeData(inactiveTrackColor: black01),
    dialogTheme: const DialogThemeData(backgroundColor: menuBackgroundLight),
    cardColor: yellowLight,
    // step rectangle home color
    searchViewTheme: const SearchViewThemeData(backgroundColor: black),
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: black),
      displayMedium: TextStyle(color: black05),
      titleLarge: TextStyle(color: white),
      titleSmall: TextStyle(color: gray50Light),
      labelSmall: TextStyle(color: white08),
      labelMedium: TextStyle(color: black005),
      labelLarge: TextStyle(color: black),
      bodyMedium: TextStyle(color: adaptive2Light),
      headlineSmall: TextStyle(color: fixedBlackLight),
      headlineMedium: TextStyle(color: fixedWhiteLight),
    ),
    iconTheme: const IconThemeData(color: black07),
    buttonTheme: const ButtonThemeData(),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => const TextStyle(color: white),
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      shadowColor: gray5Light,
      surfaceTintColor: gray30Light,
      color: gray70Light,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: imageSizeRulerLight,
    ),
    dividerTheme: const DividerThemeData(color: gray10Light),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color.fromRGBO(245, 250, 255, 1),
    ),
    dividerColor: dividerLight,
    bottomNavigationBarTheme:
        const BottomNavigationBarThemeData(backgroundColor: white005),
    unselectedWidgetColor: white.withValues(alpha: 0.6),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: white,
      indicatorColor: redLight,
    ),
    canvasColor: black003,
    popupMenuTheme: const PopupMenuThemeData(
      color: Color.fromRGBO(255, 255, 255, 1),
    ),
    listTileTheme: const ListTileThemeData(
      selectedTileColor: redLight,
      iconColor: gray10Light,
      selectedColor: photoSizeBGLight,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      prefixIconColor: gray40Light,
    ),
  );

  static final darkTheme = ThemeData(
    bottomAppBarTheme: const BottomAppBarThemeData(),
    appBarTheme: const AppBarTheme(
      foregroundColor: adaptiveDark,
      backgroundColor: backgroundDark,
      surfaceTintColor: labelDark,
      shadowColor: paleBlueDark,
    ),
    chipTheme: const ChipThemeData(backgroundColor: strokeDark),

    scaffoldBackgroundColor: background2Dark,
    badgeTheme: const BadgeThemeData(backgroundColor: white005),
    sliderTheme: const SliderThemeData(inactiveTrackColor: white01),
    dialogTheme: const DialogThemeData(backgroundColor: menuBackgroundDark),
    cardColor: yellowDark,
    tabBarTheme: const TabBarThemeData(),
    primaryColor: primaryDark,
    disabledColor: black.withValues(alpha: 0.6),
    // button theme
    searchViewTheme: const SearchViewThemeData(),
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: white),
      displayMedium: TextStyle(color: white05),
      bodySmall: TextStyle(color: white),
      titleLarge: TextStyle(color: black),
      titleSmall: TextStyle(color: gray50Dark),
      labelSmall: TextStyle(color: black08),
      labelMedium: TextStyle(color: white01),
      labelLarge: TextStyle(),
      bodyMedium: TextStyle(color: adaptive2Dark),
      headlineSmall: TextStyle(color: fixedBlackDark),
      headlineMedium: TextStyle(color: fixedWhiteDark),
    ),
    iconTheme: const IconThemeData(color: white07),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => const TextStyle(color: white),
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      shadowColor: gray5Dark,
      surfaceTintColor: gray30Dark,
      color: gray70Dark,
    ),
    dividerTheme: const DividerThemeData(color: gray10Dark),
    listTileTheme: const ListTileThemeData(
      selectedTileColor: redDark,
      iconColor: gray10Dark,
      selectedColor: photoSizeBGDark,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: imageSizeRulerDark,
    ), // greyDark2,
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color.fromRGBO(35, 35, 35, 1),
    ),
    dividerColor: dividerDark,
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: grey.withValues(alpha: 0.1)),
    unselectedWidgetColor: grey.withValues(alpha: 0.6),

    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: black,
      indicatorColor: redDark,
    ),
    canvasColor: white08,
    popupMenuTheme: const PopupMenuThemeData(
      color: Color.fromRGBO(65, 65, 65, 1),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      prefixIconColor: gray40Dark,
    ),
  );
}
