import 'package:flutter/material.dart';

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
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RePlay')),
      body: const Center(
        child: Text(
          'RePlay работает',
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}
