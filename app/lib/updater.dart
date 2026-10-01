import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'upscale.dart';

/// Номер версии вшивается при сборке: --dart-define=APP_VERSION=x.y.z
/// Источник номера один — app/pubspec.yaml, сборщик читает его оттуда.
const String appVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

const String _latestUrl =
    'https://api.github.com/repos/viktorkanuta-a11y/universal-media-player/releases/latest';

bool _checked = false;

/// Проверка при запуске. Любая ошибка (нет сети, лимит GitHub) — молча дальше.
Future<void> checkForUpdate(BuildContext context) async {
  if (_checked) return;
  _checked = true;
  if (appVersion == '0.0.0') return; // сборка без номера — не обновляем
  if (!Platform.isWindows && !Platform.isMacOS) return;

  try {
    final release = await _getJson(_latestUrl)
        .timeout(const Duration(seconds: 10));
    final tag = (release['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (!_isNewer(tag, appVersion)) return;

    final suffix = Platform.isWindows ? '-windows.zip' : '-macos.zip';
    final assets = (release['assets'] as List? ?? const []);
    Map? asset;
    for (final a in assets) {
      if (a is Map && '${a['name']}'.endsWith(suffix)) asset = a;
    }
    if (asset == null) return; // файла под эту систему в релизе нет
    final url = '${asset['browser_download_url']}';
    final name = '${asset['name']}';

    if (!context.mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Есть новая версия'),
        content: Text('Сейчас $appVersion, вышла $tag.\nОбновить?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Позже'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    await _downloadAndInstall(context, url, name);
  } catch (_) {
    // проверка не удалась — программа работает как обычно
  }
}

/// x.y.z новее текущей?
bool _isNewer(String latest, String current) {
  List<int> parse(String v) => v
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final a = parse(latest), b = parse(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

Future<Map<String, dynamic>> _getJson(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'RePlay/$appVersion');
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    if (res.statusCode != 200) throw Exception('GitHub ${res.statusCode}');
    final body = await res.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<void> _downloadAndInstall(
  BuildContext context,
  String url,
  String name,
) async {
  final status = ValueNotifier<String>('Скачиваю…');
  var open = true;
  void close() {
    if (!open) return;
    open = false;
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  final client = HttpClient();
  var canceled = false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: ValueListenableBuilder<String>(
        valueListenable: status,
        builder: (_, text, __) => Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(text)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            canceled = true;
            client.close(force: true);
            close();
          },
          child: const Text('Отмена'),
        ),
      ],
    ),
  );

  try {
    final temp = await Directory.systemTemp.createTemp('replay_update');
    final zip = File('${temp.path}${Platform.pathSeparator}$name');

    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'RePlay/$appVersion');
    final res = await req.close();
    if (res.statusCode != 200) throw Exception('скачивание: код ${res.statusCode}');
    final total = res.contentLength;
    var got = 0;
    final sink = zip.openWrite();
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      final mb = (got / 1048576).toStringAsFixed(1);
      status.value = total > 0
          ? 'Скачиваю · ${(got * 100 / total).round()}% ($mb МБ)'
          : 'Скачиваю · $mb МБ';
    }
    await sink.close();
    if (canceled) return;
    if (total > 0 && got != total) throw Exception('файл скачался не целиком');

    status.value = 'Закрываюсь и ставлю новую версию…';
    stopUpscale();
    await _startHelper(zip.path, temp.path);
    exit(0);
  } catch (e) {
    close();
    if (canceled || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Обновить не получилось'),
        content: Text('$e\n\nПрограмма работает в прежней версии.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  } finally {
    client.close();
  }
}

/// Помощник живёт отдельно от программы: ждёт её закрытия,
/// ставит новую версию рядом, запускает её. Не запустилась — возвращает старую.
Future<void> _startHelper(String zip, String temp) async {
  final exe = File(Platform.resolvedExecutable);

  if (Platform.isWindows) {
    final appDir = exe.parent.path; // ...\RePlay-0.3.0-windows
    final script = File('$temp\\update.ps1');
    // BOM — чтобы PowerShell 5 правильно прочитал русские пути
    await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_windowsScript)]);
    final psArgs = [
      'powershell.exe',
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', script.path,
      '-AppPid', '$pid',
      '-Zip', zip,
      '-AppDir', appDir,
      '-Temp', temp,
    ];
    // Запись «программа дошла до запуска» — по ней видно, что было, если
    // update.log не появится: запуск не случился или PowerShell упал сразу.
    await File('$temp\\launch.log').writeAsString(
      '${DateTime.now()} cmd /c start /min ${psArgs.join(' ')}\n',
    );
    // Через cmd /c start: Windows сам отвязывает PowerShell от программы,
    // и он не умирает вместе с ней. Заголовок «RePlay Update» нужен start.
    await Process.start(
      'cmd.exe',
      ['/c', 'start', 'RePlay Update', '/min', ...psArgs],
      mode: ProcessStartMode.detached,
      // Не папка программы: рабочая папка процесса не даёт её переименовать
      workingDirectory: temp,
    );
  } else {
    final app = exe.parent.parent.parent.path; // .../RePlay.app
    final script = File('$temp/update.sh');
    await script.writeAsString(_macScript);
    await Process.run('chmod', ['+x', script.path]);
    await Process.start(
      '/bin/bash',
      [script.path, '$pid', zip, app, temp],
      mode: ProcessStartMode.detached,
    );
  }
}

const String _windowsScript = r'''
param([int]$AppPid, [string]$Zip, [string]$AppDir, [string]$Temp)
$ErrorActionPreference = 'Stop'
$log = Join-Path $Temp 'update.log'
function Log($t) { Add-Content -Path $log -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $t) }
# Свою рабочую папку уводим из папки программы: из неё её не переименовать
Set-Location -Path $Temp
$old = "$AppDir-old"
$newDir = $null
function Held() {
  try {
    $n = Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path -like "$AppDir\*" } |
      ForEach-Object { "$($_.ProcessName) ($($_.Id))" }
    if ($n) { return ($n -join ', ') } else { return 'нет' }
  } catch { return 'не удалось узнать' }
}
function Rename-Retry($path, $newName) {
  for ($i = 1; $i -le 15; $i++) {
    try { Rename-Item -Path $path -NewName $newName -ErrorAction Stop; return }
    catch {
      Log "переименование, попытка $i из 15: $_ | процессы из папки: $(Held)"
      Start-Sleep -Seconds 2
    }
  }
  throw 'папка занята после 15 попыток (30 с)'
}
try {
  Wait-Process -Id $AppPid -Timeout 60 -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  $parent = Split-Path $AppDir -Parent
  $unz = Join-Path $Temp 'new'
  Expand-Archive -Path $Zip -DestinationPath $unz -Force
  $newSrc = Get-ChildItem -Path $unz -Directory | Select-Object -First 1
  if (-not $newSrc) { throw 'в архиве нет папки программы' }
  $newDir = Join-Path $parent $newSrc.Name
  if (Test-Path $old) { Remove-Item $old -Recurse -Force }
  Rename-Retry $AppDir (Split-Path $old -Leaf)
  Log "старая -> $old"
  if (Test-Path $newDir) { Remove-Item $newDir -Recurse -Force }
  Move-Item -Path $newSrc.FullName -Destination $newDir
  Log "новая -> $newDir"
  $p = Start-Process -FilePath (Join-Path $newDir 'RePlay.exe') -WorkingDirectory $newDir -PassThru
  Start-Sleep -Seconds 8
  if ($p.HasExited) { throw "новая версия закрылась сразу, код $($p.ExitCode)" }
  Remove-Item $old -Recurse -Force
  Log 'готово, старая удалена'
} catch {
  Log "ошибка: $_"
  if ((Test-Path $old) -and -not (Test-Path $AppDir)) {
    if ($newDir -and (Test-Path $newDir) -and ($newDir -ne $AppDir)) { Remove-Item $newDir -Recurse -Force }
    Rename-Item -Path $old -NewName (Split-Path $AppDir -Leaf)
    Log 'вернул старую'
  }
  Start-Process -FilePath (Join-Path $AppDir 'RePlay.exe') -WorkingDirectory $AppDir
}
''';

const String _macScript = r'''#!/bin/bash
APP_PID="$1"; ZIP="$2"; APP="$3"; TMP="$4"
LOG="$TMP/update.log"
log() { echo "$(date +%H:%M:%S) $1" >> "$LOG"; }
for i in $(seq 1 60); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
sleep 1
PARENT="$(dirname "$APP")"
NEW="$PARENT/RePlay.app"
OLD="$PARENT/RePlay-old.app"
rm -rf "$TMP/new" "$OLD"
if ! ditto -x -k "$ZIP" "$TMP/new"; then log "не распаковал"; open "$APP"; exit 1; fi
SRC="$(find "$TMP/new" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$SRC" ]; then log "в архиве нет .app"; open "$APP"; exit 1; fi
mv "$APP" "$OLD" && log "старая -> $OLD"
mv "$SRC" "$NEW" && log "новая -> $NEW"
xattr -cr "$NEW" 2>/dev/null
open -n "$NEW"
sleep 8
if pgrep -x RePlay >/dev/null; then
  rm -rf "$OLD"; log "готово, старая удалена"
else
  log "новая не запустилась, возвращаю старую"
  rm -rf "$NEW"; mv "$OLD" "$APP"; open "$APP"
fi
''';
