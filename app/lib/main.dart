import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'replay_home.dart';
import 'splash_screen.dart';
import 'upscale.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RePlayApp());
}

class RePlayApp extends StatefulWidget {
  const RePlayApp({super.key});

  @override
  State<RePlayApp> createState() => _RePlayAppState();
}

class _RePlayAppState extends State<RePlayApp> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    // Закрытие окна: остановить движок и отпустить запрет сна
    _listener = AppLifecycleListener(
      onExitRequested: () async {
        stopUpscale();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

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
