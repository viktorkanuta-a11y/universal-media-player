import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

String? _selectedPath;
Process? _engine;
bool _canceled = false;

/// Что показать в зоне: имя и размер выбранной картинки (null — не выбрана)
final ValueNotifier<String?> selectedInfo = ValueNotifier<String?>(null);

/// Итог больше этого — предупреждаем (в памяти 4 байта на пиксель)
const int _bigPixels = 500000000;

void _message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

String _baseName(String path) =>
    _fileName(path).replaceAll(RegExp(r'\.[^.]+$'), '');

/// Выбор картинки через окно Проводника
Future<void> pickImage(BuildContext context) async {
  final group = XTypeGroup(
    label: 'Картинки',
    extensions: ['jpg', 'jpeg', 'png', 'webp'],
  );
  final file = await openFile(acceptedTypeGroups: [group]);
  if (file == null || !context.mounted) return;
  await selectImage(context, file.path);
}

/// Выбрать картинку по пути (из Проводника или перетаскиванием)
Future<void> selectImage(BuildContext context, String path) async {
  final ext = path.split('.').last.toLowerCase();
  if (!['jpg', 'jpeg', 'png', 'webp'].contains(ext)) {
    _message(context,
        'Этот формат пока не читаю. Можно: jpg, png, webp (TIFF — в следующей версии)');
    return;
  }
  _selectedPath = path;
  final name = _fileName(path);
  selectedInfo.value = '$name\nчитаю размер…';
  try {
    final info = await readImageInfo(path);
    var text = '$name\n${info.describe()}';
    final seen = await _decoderSize(path);
    if (seen.$1 != info.w || seen.$2 != info.h) {
      text += '\n⚠ Программа видит ${seen.$1}×${seen.$2} px — '
          'для расчёта беру размер из файла';
    }
    if (_selectedPath == path) selectedInfo.value = text;
  } catch (e) {
    if (_selectedPath == path) {
      selectedInfo.value = '$name\nразмер прочитать не удалось';
    }
  }
}

/// Остановить движок (кнопка «Отмена», закрытие программы)
void stopUpscale() {
  _canceled = true;
  _engine?.kill();
  _engine = null;
}

// ───────────────────────── чтение размера ─────────────────────────

class ImgInfo {
  ImgInfo(this.w, this.h, this.format, this.cmyk, this.bytes);

  final int w;
  final int h;
  final String format;
  final bool cmyk;
  final int bytes;

  double get mp => w * h / 1e6;

  String describe() {
    final mb = (bytes / 1048576).round();
    return '$w×$h px (${mp.toStringAsFixed(mp < 10 ? 1 : 0)} МП) · '
        '$format${cmyk ? ' CMYK' : ''} · $mb МБ';
  }
}

/// Размер читаем из заголовка файла (PNG, JPEG), иначе — через Flutter
Future<ImgInfo> readImageInfo(String path) async {
  final file = File(path);
  final bytes = await file.length();
  final raf = await file.open();
  Uint8List head;
  try {
    head = await raf.read(2 * 1024 * 1024);
  } finally {
    await raf.close();
  }
  if (head.length > 24 && head[0] == 0x89 && head[1] == 0x50) {
    final bd = ByteData.sublistView(head);
    return ImgInfo(bd.getUint32(16), bd.getUint32(20), 'PNG', false, bytes);
  }
  if (head.length > 4 && head[0] == 0xFF && head[1] == 0xD8) {
    var i = 2;
    while (i + 9 < head.length) {
      if (head[i] != 0xFF) {
        i++;
        continue;
      }
      final m = head[i + 1];
      if (m == 0xFF) {
        i++;
        continue;
      }
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = (head[i + 2] << 8) | head[i + 3];
      final isSof =
          m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
      if (isSof) {
        final h = (head[i + 5] << 8) | head[i + 6];
        final w = (head[i + 7] << 8) | head[i + 8];
        final comps = head[i + 9];
        return ImgInfo(w, h, 'JPEG', comps == 4, bytes);
      }
      i += 2 + len;
    }
  }
  final size = await _decoderSize(path);
  return ImgInfo(
      size.$1, size.$2, path.split('.').last.toUpperCase(), false, bytes);
}

/// Размер, который видит Flutter (без полного разворота картинки)
Future<(int, int)> _decoderSize(String path) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(
      await File(path).readAsBytes());
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    return size;
  } finally {
    buffer.dispose();
  }
}

// ───────────────────────── план работы ─────────────────────────

class _Plan {
  _Plan({
    required this.enhance,
    required this.targetW,
    required this.targetH,
    required this.passes,
    required this.inputMp,
    required this.smallW,
    required this.smallH,
    required this.sourceMp,
    required this.text,
  });

  final bool enhance;
  final int targetW;
  final int targetH;
  final int passes; // 0 — движок не нужен
  final double inputMp; // сколько мегапикселей на входе у движка за все проходы
  final int smallW; // «Улучшить»: размер уменьшенной копии
  final int smallH;
  final double sourceMp;
  final String text;

  String get title => enhance ? 'Улучшить — что будет' : 'Увеличить — что будет';
}

String _gb(num pixels) => (pixels * 4 / 1e9).toStringAsFixed(1);

_Plan _planUpscale(ImgInfo info, String wText, String hText, int dpi) {
  final k = _scale((info.w, info.h), wText, hText, dpi);
  final tw = (info.w * k).round();
  final th = (info.h * k).round();
  final passes = k > 4 ? 2 : (k > 1 ? 1 : 0);
  var inputMp = 0.0;
  if (passes == 2) {
    inputMp = info.mp + (tw / 4) * (th / 4) / 1e6;
  } else if (passes == 1) {
    inputMp = info.mp;
  }
  final mw = double.tryParse(wText.replaceAll(',', '.')) ?? 0;
  final mh = double.tryParse(hText.replaceAll(',', '.')) ?? 0;

  final b = StringBuffer();
  b.writeln('Файл: ${info.describe()}');
  if (mw > 0 || mh > 0) {
    final needW = (mw * 39.3701 * dpi).round();
    final needH = (mh * 39.3701 * dpi).round();
    b.writeln('Печать: ${mw > 0 ? mw : '—'} × ${mh > 0 ? mh : '—'} м '
        'при $dpi dpi → нужно ${mw > 0 ? '$needW' : '—'}×'
        '${mh > 0 ? '$needH' : '—'} px');
  } else {
    b.writeln('Размер печати не задан — увеличу в 4 раза.');
  }
  if (passes == 0) {
    b.writeln('Файлу хватает пикселей: нейросеть не нужна, '
        'размер: $tw×$th px.');
    b.writeln('Если нужна чёткость без роста размера — раздел «Улучшить».');
  } else {
    b.writeln('Увеличение: в ${k.toStringAsFixed(2)} раза, '
        'проходов нейросети: $passes.');
    b.writeln('Итог: $tw×$th px (${(tw * th / 1e6).toStringAsFixed(0)} МП).');
  }
  if ((mw > 0 || mh > 0) && passes > 0 || k < 1) {
    final rw = tw / (dpi * 39.3701);
    final rh = th / (dpi * 39.3701);
    b.writeln('Это ${rw.toStringAsFixed(2)} × ${rh.toStringAsFixed(2)} м '
        'при $dpi dpi.');
    if (mw > 0 && rw - mw > 0.01) {
      b.writeln('Лишнее по ширине: ${(rw - mw).toStringAsFixed(2)} м — '
          'убери при печати (пропорции файла сохраняются).');
    }
    if (mh > 0 && rh - mh > 0.01) {
      b.writeln('Лишнее по высоте: ${(rh - mh).toStringAsFixed(2)} м — '
          'убери при печати (пропорции файла сохраняются).');
    }
    if (mw > 0 && mw - rw > 0.01) {
      b.writeln('⚠ Не хватает по ширине: ${(mw - rw).toStringAsFixed(2)} м '
          '(упёрся в предел увеличения ×16).');
    }
    if (mh > 0 && mh - rh > 0.01) {
      b.writeln('⚠ Не хватает по высоте: ${(mh - rh).toStringAsFixed(2)} м '
          '(упёрся в предел увеличения ×16).');
    }
  }
  if (tw * th > _bigPixels) {
    b.writeln('⚠ Итог очень большой: только в памяти около ${_gb(tw * th)} ГБ. '
        'Скорее всего не получится — уменьши dpi.');
  }
  return _Plan(
    enhance: false,
    targetW: tw,
    targetH: th,
    passes: passes,
    inputMp: inputMp,
    smallW: 0,
    smallH: 0,
    sourceMp: info.mp,
    text: b.toString().trimRight(),
  );
}

_Plan _planEnhance(ImgInfo info) {
  final sw = math.max(1, (info.w / 4).round());
  final sh = math.max(1, (info.h / 4).round());
  final tw = sw * 4;
  final th = sh * 4;
  final b = StringBuffer();
  b.writeln('Файл: ${info.describe()}');
  b.writeln('Как: уменьшу копию в 4 раза ($sw×$sh px), '
      'нейросеть вернёт ×4 — размер почти тот же.');
  b.writeln('Итог: $tw×$th px (размер не растёт, разница до 3 px).');
  b.writeln('Входных пикселей: ${(sw * sh / 1e6).toStringAsFixed(1)} МП '
      'вместо ${info.mp.toStringAsFixed(0)} МП.');
  b.writeln('Что станет с деталями — смотри на тесте ниже: '
      'небо может стать «пластиковым», текст и края — чётче.');
  if (tw * th > _bigPixels) {
    b.writeln('⚠ Итог большой: в памяти около ${_gb(tw * th)} ГБ.');
  }
  return _Plan(
    enhance: true,
    targetW: tw,
    targetH: th,
    passes: 1,
    inputMp: sw * sh / 1e6,
    smallW: sw,
    smallH: sh,
    sourceMp: info.mp,
    text: b.toString().trimRight(),
  );
}

class _Opts {
  _Opts(this.anime);
  bool anime;
}

class _TestResult {
  _TestResult(this.before, this.after, this.sec, this.fw, this.fh, this.anime);
  final String before;
  final String after;
  final double sec;
  final int fw;
  final int fh;
  final bool anime;
}

String _duration(double sec) {
  final s = sec.round();
  if (s < 90) return '$s с';
  final m = s ~/ 60;
  if (m < 90) return '≈ $m мин';
  final h = m / 60;
  return '≈ ${h.toStringAsFixed(1)} ч';
}

// ───────────────────────── запуск ─────────────────────────

/// «Увеличить». fast=false — «Бережно», fast=true — «Быстрее».
Future<void> runUpscale(
  BuildContext context,
  String widthText,
  String heightText,
  int dpi, {
  bool fast = false,
  bool anime = false,
}) async {
  final input = _selectedPath;
  if (input == null) {
    _message(context, 'Сначала перетащи картинку в окно или нажми на зону');
    return;
  }
  final ImgInfo info;
  try {
    info = await readImageInfo(input);
  } catch (e) {
    if (context.mounted) await _error(context, 'Не получилось прочитать файл');
    return;
  }
  if (!context.mounted) return;
  final plan = _planUpscale(info, widthText, heightText, dpi);
  await _start(context, input, plan, fast, anime, dpi);
}

/// «Улучшить»: размер почти не меняется
Future<void> runEnhance(
  BuildContext context, {
  bool fast = false,
  bool anime = false,
}) async {
  final input = _selectedPath;
  if (input == null) {
    _message(context, 'Сначала перетащи картинку в окно или нажми на зону');
    return;
  }
  final ImgInfo info;
  try {
    info = await readImageInfo(input);
  } catch (e) {
    if (context.mounted) await _error(context, 'Не получилось прочитать файл');
    return;
  }
  if (!context.mounted) return;
  await _start(context, input, _planEnhance(info), fast, anime, null);
}

Future<void> _start(BuildContext context, String input, _Plan plan, bool fast,
    bool anime, int? dpi) async {
  final temp = await Directory.systemTemp.createTemp('replay');
  try {
    final opts = _Opts(anime);
    final go = await _confirm(context, plan, input, temp, fast, opts);
    if (!go || !context.mounted) return;
    await _work(context, input, plan, temp, fast, opts.anime, dpi);
  } finally {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {}
  }
}

/// Окно «что будет» + необязательный мини-тест. true — запускаем.
Future<bool> _confirm(BuildContext context, _Plan plan, String input,
    Directory temp, bool fast, _Opts opts) async {
  _TestResult? test;
  while (true) {
    final shown = test;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: Text(plan.title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(plan.text),
                if (shown != null) ..._testWidgets(shown, plan),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop('cancel'),
            child: const Text('Отмена'),
          ),
          if (plan.passes > 0)
            TextButton(
              onPressed: () => Navigator.of(d).pop('test'),
              child: Text(shown == null
                  ? 'Тест 10 сек'
                  : 'Тест: ${opts.anime ? 'Фото' : 'Рисунок'}'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop('go'),
            child: Text(shown == null ? 'Запустить без теста' : 'Запустить'),
          ),
        ],
      ),
    );
    if (action == 'go') return true;
    if (action != 'test' || !context.mounted) return false;
    if (shown != null) opts.anime = !opts.anime; // другая модель
    test = await _runTest(context, plan, input, temp, fast, opts) ?? shown;
    if (!context.mounted) return false;
  }
}

List<Widget> _testWidgets(_TestResult t, _Plan plan) {
  final perMp = t.sec / (t.fw * t.fh / 1e6);
  final total = perMp * plan.inputMp;
  Widget pic(String path, String label, FilterQuality q) => Column(
        children: [
          Image.file(File(path),
              width: 200, height: 200, fit: BoxFit.contain, filterQuality: q),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      );
  return [
    const SizedBox(height: 16),
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        pic(t.before, 'До', FilterQuality.none),
        pic(t.after, 'После (${t.anime ? 'Рисунок' : 'Фото'})',
            FilterQuality.medium),
      ],
    ),
    const SizedBox(height: 12),
    Text(
      'Тест: ${t.sec.toStringAsFixed(1)} с на кусочке из центра '
      '${t.fw}×${t.fh} px.\n'
      'Вся работа ≈ ${_duration(total)} (грубо: в тест входит запуск '
      'движка, реальный проход может идти иначе).',
    ),
  ];
}

/// Кусочек из центра картинки (для «Улучшить» — из уменьшенной копии)
Future<(String, int, int)> _makeFragment(
    String input, String out, _Plan plan) async {
  final bytes = await File(input).readAsBytes();
  int? tw;
  int? th;
  if (plan.enhance) {
    tw = plan.smallW;
    th = plan.smallH;
  } else if (plan.sourceMp > 20) {
    // огромный файл целиком не разворачиваем: берём уменьшенный вид
    final d = await _decoderSize(input);
    final scale = 4096 / math.max(d.$1, d.$2);
    tw = math.max(1, (d.$1 * scale).round());
    th = math.max(1, (d.$2 * scale).round());
  }
  final codec = await ui.instantiateImageCodec(bytes,
      targetWidth: tw, targetHeight: th);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final cw = math.min(160, img.width);
  final ch = math.min(160, img.height);
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawImageRect(
    img,
    ui.Rect.fromLTWH((img.width - cw) / 2, (img.height - ch) / 2,
        cw.toDouble(), ch.toDouble()),
    ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
    ui.Paint(),
  );
  final crop = await rec.endRecording().toImage(cw, ch);
  final data = await crop.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  crop.dispose();
  if (data == null) throw Exception('Не получилось вырезать кусочек');
  await File(out).writeAsBytes(data.buffer.asUint8List());
  return (out, cw, ch);
}

Future<_TestResult?> _runTest(BuildContext context, _Plan plan, String input,
    Directory temp, bool fast, _Opts opts) async {
  _canceled = false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Тест на маленьком кусочке…')),
        ],
      ),
    ),
  );
  void close() {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  try {
    final frag = await _makeFragment(input, '${temp.path}/frag.png', plan);
    final tag = opts.anime ? 'anime' : 'photo';
    final after = '${temp.path}/frag_$tag.png';
    final sw = Stopwatch()..start();
    await _engineRun(frag.$1, after, ValueNotifier<String>(''), 1, 1, fast,
        opts.anime);
    sw.stop();
    close();
    return _TestResult(frag.$1, after, sw.elapsedMilliseconds / 1000,
        frag.$2, frag.$3, opts.anime);
  } catch (e) {
    close();
    if (!_canceled && context.mounted) {
      await _error(context, '$e'.replaceFirst('Exception: ', ''));
    }
    return null;
  }
}

/// Сама обработка
Future<void> _work(BuildContext context, String input, _Plan plan,
    Directory temp, bool fast, bool anime, int? dpi) async {
  final location =
      await getSaveLocation(suggestedName: '${_baseName(input)}_replay.png');
  if (location == null || !context.mounted) return;
  var output = location.path;
  if (!output.toLowerCase().endsWith('.png')) output = '$output.png';

  _canceled = false;
  final status = ValueNotifier<String>('Готовлю…');
  final started = DateTime.now();
  final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    status.value = status.value;
  });

  // окошко прогресса закрывается ровно один раз
  var dialogOpen = true;
  void closeDialog() {
    if (!dialogOpen) return;
    dialogOpen = false;
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
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
            closeDialog();
          },
          child: const Text('Отмена'),
        ),
      ],
    ),
  );

  try {
    _keepAwake(true);
    final tw = plan.targetW;
    final th = plan.targetH;
    var current = input;

    if (plan.enhance) {
      status.value = 'Уменьшаю копию в 4 раза…';
      current = await _resize(
          input, '${temp.path}/small.png', plan.smallW, plan.smallH);
      status.value = 'Улучшаю · нейросеть ×4';
      current = await _engineRun(
          current, '${temp.path}/p1.png', status, 1, 1, fast, anime);
    } else if (plan.passes == 2) {
      status.value = 'Проход 1 из 2 · нужен размер $tw×$th px';
      current = await _engineRun(
          current, '${temp.path}/p1.png', status, 1, 2, fast, anime);
      current = await _resize(
          current, '${temp.path}/p1_fit.png', (tw / 4).round(), (th / 4).round());
      status.value = 'Проход 2 из 2';
      current = await _engineRun(
          current, '${temp.path}/p2.png', status, 2, 2, fast, anime);
    } else if (plan.passes == 1) {
      status.value = 'Увеличиваю · нужен размер $tw×$th px';
      current = await _engineRun(
          current, '${temp.path}/p1.png', status, 1, 1, fast, anime);
    }

    status.value = 'Сохраняю';
    final now = await readImageInfo(current);
    if ((now.w - tw).abs() > 1 || (now.h - th).abs() > 1) {
      current = await _resize(current, output, tw, th);
    } else {
      await File(current).copy(output);
    }

    final seconds = DateTime.now().difference(started).inSeconds;
    closeDialog();
    if (!context.mounted) return;
    await _done(context, output, tw, th, dpi, seconds);
  } catch (e) {
    closeDialog();
    // недописанный файл не оставляем
    try {
      final f = File(output);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    if (_canceled || !context.mounted) return;
    await _error(context, '$e'.replaceFirst('Exception: ', ''));
  } finally {
    ticker.cancel();
    _keepAwake(false);
    _engine = null;
    closeDialog();
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
  if (need <= 0) return 4;
  if (need > 16) return 16;
  return need;
}

/// Ключи движка.
/// «Быстрее» — как в 0.3.5: куски по 64, потоки по умолчанию.
/// «Бережно» — куски по 32 (короче работа за раз) и по одному потоку
/// на загрузку, расчёт и сохранение.
/// anime — модель для рисунков, иначе модель для фото.
List<String> engineArgs(
  String input,
  String output,
  String modelsDir, {
  required bool fast,
  bool anime = false,
}) =>
    [
      '-i', input, '-o', output,
      '-n', anime ? 'realesrgan-x4plus-anime' : 'realesrgan-x4plus',
      '-s', '4', '-m', modelsDir,
      if (fast) ...['-t', '64'] else ...['-t', '32', '-j', '1:1:1'],
    ];

/// Windows: процесс движка работает с приоритетом «ниже обычного»,
/// чтобы уступать другим программам, если компьютер уже занят
void _lowerPriority(int pid) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openProcess = kernel32.lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)>('OpenProcess');
    final setPriorityClass = kernel32.lookupFunction<
        Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetPriorityClass');
    final closeHandle = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
    final handle = openProcess(0x0200, 0, pid); // PROCESS_SET_INFORMATION
    if (handle == 0) return;
    setPriorityClass(handle, 0x00004000); // BELOW_NORMAL_PRIORITY_CLASS
    closeHandle(handle);
  } catch (_) {
    // не вышло — работаем с обычным приоритетом
  }
}

/// Один прогон движка x4 с процентами
Future<String> _engineRun(
  String input,
  String output,
  ValueNotifier<String> status,
  int pass,
  int total,
  bool fast,
  bool anime,
) async {
  final dir = _engineDir();
  final exe = Platform.isWindows
      ? '$dir/realesrgan-ncnn-vulkan.exe'
      : '$dir/realesrgan-ncnn-vulkan';
  final args = engineArgs(input, output, '$dir/models', fast: fast, anime: anime);

  final Process process;
  if (!fast && Platform.isMacOS) {
    // Mac: «nice» запускает движок с пониженным приоритетом (тот же процесс)
    process = await Process.start('nice', ['-n', '10', exe, ...args]);
  } else {
    process = await Process.start(exe, args);
    if (!fast && Platform.isWindows) _lowerPriority(process.pid);
  }
  _engine = process;

  final log = StringBuffer();
  final percent = RegExp(r'(\d+[.,]?\d*)%');
  final reading = process.stderr
      .transform(const SystemEncoding().decoder)
      .forEach((chunk) {
    log.write(chunk);
    final match = percent.allMatches(chunk).lastOrNull;
    if (match != null) {
      status.value = 'Проход $pass из $total · ${match.group(1)}%';
    }
  });

  final code = await process.exitCode;
  await reading;
  _engine = null;
  if (_canceled) throw Exception('отменено');
  if (code != 0 || log.toString().toLowerCase().contains('failed')) {
    throw Exception(
        'Видеокарта не справилась, движок остановился (код $code). '
        'Попробуй размер поменьше.');
  }
  if (!await File(output).exists()) {
    throw Exception('Движок не создал файл (код $code)');
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
  if (data == null) throw Exception('Не получилось подогнать размер');
  await File(output).writeAsBytes(data.buffer.asUint8List());
  return output;
}

/// Окно «Готово» с кнопкой «Открыть папку»
Future<void> _done(
  BuildContext context,
  String path,
  int w,
  int h,
  int? dpi,
  int seconds,
) async {
  final m = seconds ~/ 60;
  final time = m > 0 ? '$m мин ${seconds % 60} с' : '$seconds с';
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Готово'),
      content: Text('$w×$h px${dpi != null ? ', $dpi dpi' : ''}\n'
          'Время: $time\n\nФайл: $path'),
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

/// Окно ошибки — не исчезает само
Future<void> _error(BuildContext context, String text) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Не получилось'),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Понятно'),
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
      setState(on ? 0x80000003 : 0x80000000);
    }
  } catch (_) {
    // не вышло — работаем дальше
  }
}
