import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'services/api_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final api = ApiClient(prefs);
  runApp(TeleDriveApp(api: api));
}

class TeleDriveApp extends StatelessWidget {
  const TeleDriveApp({super.key, required this.api});
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE50914);
    return MaterialApp(
      title: 'TeleDrive Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: red, secondary: red, surface: Color(0xFF141414)),
        cardColor: const Color(0xFF141414),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, elevation: 0),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF171717),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: red)),
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(api: api),
    );
  }
}
