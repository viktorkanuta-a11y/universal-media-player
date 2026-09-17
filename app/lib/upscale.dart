import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

String? _selectedPath;

void _message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Выбор картинки
Future<void> pickImage(BuildContext context) async {
  final group = XTypeGroup(
    label: 'Картинки',
    extensions: ['jpg', 'jpeg', 'png', 'webp'],
  );
  final file = await openFile(acceptedTypeGroups: [group]);
  if (file == null || !context.mounted) return;
  _selectedPath = file.path;
  _message(context, 'Выбрано: ${file.name}');
}

/// Запуск увеличения
Future<void> runUpscale(
  BuildContext context,
  String widthText,
  String heightText,
  double quality,
) async {
  final input = _selectedPath;
  if (input == null) {
    _message(context, 'Сначала нажми на зону и выбери картинку');
    return;
  }
  final name = input.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
  final location = await getSaveLocation(suggestedName: '${name}_replay.png');
  if (location == null || !context.mounted) return;
  var output = location.path;
  if (!output.toLowerCase().endsWith('.png')) output = '$output.png';

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Увеличиваю… Большая картинка — до нескольких минут.')),
        ],
      ),
    ),
  );
  try {
    final passes = await _passes(input, widthText, heightText, quality);
    await _upscale(input, output, passes);
    final size = await _pngSize(output);
    if (!context.mounted) return;
    Navigator.of(context).pop();
    _message(context, 'Готово: ${size.$1}×${size.$2} px → $output');
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop();
    _message(context, 'Ошибка: $e');
  }
}

/// Сколько проходов x4: 1 или 2 (x16)
Future<int> _passes(String input, String w, String h, double quality) async {
  double meters = 0;
  for (final t in [w, h]) {
    final v = double.tryParse(t.replaceAll(',', '.')) ?? 0;
    if (v > meters) meters = v;
  }
  if (meters <= 0) return 1;
  final codec = await ui.instantiateImageCodec(await File(input).readAsBytes());
  final frame = await codec.getNextFrame();
  final w0 = frame.image.width;
  final h0 = frame.image.height;
  frame.image.dispose();
  final longSide = w0 > h0 ? w0 : h0;
  final ppi = 72 + quality * 78; // от 72 до 150
  final target = meters * 39.37 * ppi;
  return longSide * 4 >= target ? 1 : 2;
}

Future<void> _upscale(String input, String output, int passes) async {
  final contents = File(Platform.resolvedExecutable).parent.parent.path;
  final engine = '$contents/Resources/engine';
  final temp = await Directory.systemTemp.createTemp('replay');
  var current = input;
  for (var i = 1; i <= passes; i++) {
    final out = i == passes ? output : '${temp.path}/pass$i.png';
    final result = await Process.run('$engine/realesrgan-ncnn-vulkan', [
      '-i', current, '-o', out,
      '-n', 'realesrgan-x4plus', '-s', '4', '-m', '$engine/models',
    ]);
    if (!await File(out).exists()) {
      throw Exception('движок не создал файл (код ${result.exitCode}) ${result.stderr}');
    }
    current = out;
  }
}

/// Размер PNG из заголовка, без загрузки всей картинки
Future<(int, int)> _pngSize(String path) async {
  final file = await File(path).open();
  final b = await file.read(24);
  await file.close();
  int u32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return (u32(16), u32(20));
}
