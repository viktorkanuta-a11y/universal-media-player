import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

String? _selectedPath;
Process? _engine;
bool _canceled = false;

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

/// Остановить движок (кнопка «Отмена», закрытие программы)
void stopUpscale() {
  _canceled = true;
  _engine?.kill();
  _engine = null;
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

  final name = input.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
  final location = await getSaveLocation(suggestedName: '${name}_replay.png');
  if (location == null || !context.mounted) return;
  var output = location.path;
  if (!output.toLowerCase().endsWith('.png')) output = '$output.png';

  _canceled = false;
  final status = ValueNotifier<String>('Готовлю…');
  final started = DateTime.now();
  final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    status.value = status.value; // перерисовка времени
  });

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      content: ValueListenableBuilder<String>(
        valueListenable: status,
        builder: (_, text, __) {
          final sec = DateTime.now().difference(started).inSeconds;
          final time = '${(sec ~/ 60).toString().padLeft(2, '0')}:'
              '${(sec % 60).toString().padLeft(2, '0')}';
          return Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text('$text\nИдёт $time')),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            stopUpscale();
            Navigator.of(dialogContext).pop();
          },
          child: const Text('Отмена'),
        ),
      ],
    ),
  );

  Directory? temp;
  try {
    _keepAwake(true);
    final src = await _imageSize(input);
    final dpi = 72 + (quality * 228).round(); // 72…300
    final k = _scale(src, widthText, heightText, dpi);
    final targetW = (src.$1 * k).round();
    final targetH = (src.$2 * k).round();

    temp = await Directory.systemTemp.createTemp('replay');
    var current = input;

    if (k > 4) {
      status.value = 'Проход 1 из 2 · нужен размер $targetW×$targetH px';
      current = await _engineRun(current, '${temp.path}/p1.png', status, 1, 2);
      // ужимаем до четверти цели, чтобы второй проход дал ровно цель,
      // а не картинку в 16 раз
      current = await _resize(current, '${temp.path}/p1_fit.png',
          (targetW / 4).round(), (targetH / 4).round());
      status.value = 'Проход 2 из 2';
      current = await _engineRun(current, '${temp.path}/p2.png', status, 2, 2);
    } else if (k > 1) {
      status.value = 'Увеличиваю · нужен размер $targetW×$targetH px';
      current = await _engineRun(current, '${temp.path}/p1.png', status, 1, 1);
    }

    status.value = 'Подгоняю под размер печати';
    final now = await _imageSize(current);
    if ((now.$1 - targetW).abs() > 1 || (now.$2 - targetH).abs() > 1) {
      current = await _resize(current, output, targetW, targetH);
    } else {
      await File(current).copy(output);
    }

    if (!context.mounted) return;
    Navigator.of(context).pop();
    await _done(context, output, targetW, targetH, dpi);
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop();
    if (!_canceled) _message(context, 'Ошибка: $e');
  } finally {
    ticker.cancel();
    _keepAwake(false);
    _engine = null;
    if (temp != null && await temp.exists()) {
      await temp.delete(recursive: true);
    }
  }
}

/// Во сколько раз увеличить, чтобы хватило на размер печати
double _scale((int, int) src, String w, String h, int dpi) {
  double need = 0;
  final mw = double.tryParse(w.replaceAll(',', '.')) ?? 0;
  final mh = double.tryParse(h.replaceAll(',', '.')) ?? 0;
  if (mw > 0) {
    final k = (mw * 39.3701 * dpi) / src.$1;
    if (k > need) need = k;
  }
  if (mh > 0) {
    final k = (mh * 39.3701 * dpi) / src.$2;
    if (k > need) need = k;
  }
  if (need <= 0) return 4; // поля пустые — просто x4
  if (need > 16) return 16; // дальше движок не тянет
  return need;
}

/// Один прогон движка x4 с процентами
Future<String> _engineRun(
  String input,
  String output,
  ValueNotifier<String> status,
  int pass,
  int total,
) async {
  final dir = _engineDir();
  final exe = Platform.isWindows
      ? '$dir/realesrgan-ncnn-vulkan.exe'
      : '$dir/realesrgan-ncnn-vulkan';

  final process = await Process.start(exe, [
    '-i', input, '-o', output,
    '-n', 'realesrgan-x4plus', '-s', '4', '-m', '$dir/models',
  ]);
  _engine = process;

  final percent = RegExp(r'(\d+[.,]?\d*)%');
  process.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
    final match = percent.allMatches(chunk).lastOrNull;
    if (match != null) {
      status.value = 'Проход $pass из $total · ${match.group(1)}%';
    }
  });

  final code = await process.exitCode;
  _engine = null;
  if (_canceled) throw Exception('отменено');
  if (!await File(output).exists()) {
    throw Exception('движок не создал файл (код $code)');
  }
  return output;
}

/// Где лежит движок внутри программы
String _engineDir() {
  final exe = File(Platform.resolvedExecutable);
  if (Platform.isWindows) {
    return '${exe.parent.path}/engine';
  }
  return '${exe.parent.parent.path}/Resources/engine';
}

/// Точная подгонка размера
Future<String> _resize(String input, String output, int w, int h) async {
  final codec = await ui.instantiateImageCodec(
    await File(input).readAsBytes(),
    targetWidth: w,
    targetHeight: h,
  );
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  if (data == null) throw Exception('не получилось подогнать размер');
  await File(output).writeAsBytes(data.buffer.asUint8List());
  return output;
}

/// Размер картинки в пикселях
Future<(int, int)> _imageSize(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  final frame = await codec.getNextFrame();
  final size = (frame.image.width, frame.image.height);
  frame.image.dispose();
  return size;
}

/// Окно «Готово» с кнопкой «Открыть папку»
Future<void> _done(
  BuildContext context,
  String path,
  int w,
  int h,
  int dpi,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Готово'),
      content: Text('$w×$h px, $dpi dpi\n\nФайл: $path'),
      actions: [
        TextButton(
          onPressed: () => _showInFolder(path),
          child: const Text('Открыть папку'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

void _showInFolder(String path) {
  if (Platform.isWindows) {
    Process.run('explorer', ['/select,${path.replaceAll('/', r'\')}']);
  } else {
    Process.run('open', ['-R', path]);
  }
}

/// Не давать компьютеру уснуть, пока идёт работа
Process? _caffeinate;

void _keepAwake(bool on) {
  try {
    if (Platform.isMacOS) {
      if (on) {
        Process.start('caffeinate', ['-dims']).then((p) => _caffeinate = p);
      } else {
        _caffeinate?.kill();
        _caffeinate = null;
      }
    } else if (Platform.isWindows) {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final setState = kernel32.lookupFunction<Uint32 Function(Uint32),
          int Function(int)>('SetThreadExecutionState');
      // ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
      setState(on ? 0x80000003 : 0x80000000);
    }
  } catch (_) {
    // не вышло — работаем дальше, это не ошибка обработки
  }
}
