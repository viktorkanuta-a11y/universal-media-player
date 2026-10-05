import 'package:flutter_test/flutter_test.dart';
import 'package:replay/upscale.dart';

void main() {
  test('«Быстрее»: ключи как в 0.3.5 (куски по 64, потоки по умолчанию)', () {
    final args = engineArgs('in.png', 'out.png', 'models', fast: true);
    expect(args, [
      '-i', 'in.png', '-o', 'out.png',
      '-n', 'realesrgan-x4plus', '-s', '4', '-m', 'models',
      '-t', '64',
    ]);
    expect(args.contains('-j'), isFalse);
  });

  test('«Бережно»: куски по 32 и по одному потоку', () {
    final args = engineArgs('in.png', 'out.png', 'models', fast: false);
    expect(args.sublist(args.length - 4), ['-t', '32', '-j', '1:1:1']);
    expect(args.contains('64'), isFalse);
  });

  test('Общие ключи одинаковы в обоих режимах', () {
    final fast = engineArgs('a', 'b', 'm', fast: true).sublist(0, 10);
    final gentle = engineArgs('a', 'b', 'm', fast: false).sublist(0, 10);
    expect(gentle, fast);
  });
}
