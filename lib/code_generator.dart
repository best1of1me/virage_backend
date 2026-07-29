import 'dart:math';

class CodeGenerator {
  static const _digits = '0123456789';
  static final _rnd = Random();

  static String generate({int length = 8}) {
    return String.fromCharCodes(
      Iterable.generate(
        length,
        (_) => _digits.codeUnitAt(_rnd.nextInt(_digits.length)),
      ),
    );
  }
}
