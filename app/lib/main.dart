import 'package:flutter/material.dart';

import 'replay_home.dart';
import 'splash_screen.dart';

void main() {
  runApp(const RePlayApp());
}

class RePlayApp extends StatelessWidget {
  const RePlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RePlay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFFE8664A)),
      home: const SplashScreen(next: ReplayHome()),
    );
  }
}
