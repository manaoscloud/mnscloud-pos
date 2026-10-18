/// Exact decimal values for money (4 places) and quantities (6 places).
///
/// Values are kept as scaled integers so totals never suffer binary floating point errors. Rounding
/// is half-up at the scale of the value, the same as the database DECIMAL columns.
class Decimal implements Comparable<Decimal> {
  const Decimal._(this.units, this.scale);

  /// Scaled integer value (`units / 10^scale`).
  final BigInt units;
  final int scale;

  static final Map<int, BigInt> _pow = {};
  static BigInt _p(int scale) => _pow.putIfAbsent(scale, () => BigInt.from(10).pow(scale));

  factory Decimal.zero([int scale = 4]) => Decimal._(BigInt.zero, scale);

  factory Decimal.fromInt(int value, [int scale = 4]) => Decimal._(BigInt.from(value) * _p(scale), scale);

  /// Parses `"12.5"`, `"-0.0300"`, `"1,99"` (comma accepted) or a JSON number.
  factory Decimal.parse(Object? value, [int scale = 4]) {
    if (value == null) return Decimal.zero(scale);
    var text = value.toString().trim().replaceAll(',', '.');
    if (text.isEmpty) return Decimal.zero(scale);
    final negative = text.startsWith('-');
    if (negative || text.startsWith('+')) text = text.substring(1);
    final parts = text.split('.');
    if (parts.length > 2 || !RegExp(r'^\d*$').hasMatch(parts[0]) ||
        (parts.length == 2 && !RegExp(r'^\d*$').hasMatch(parts[1]))) {
      throw FormatException('Invalid decimal: $value');
    }
    final whole = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
    var fraction = parts.length == 2 ? parts[1] : '';
    var roundUp = false;
    if (fraction.length > scale) {
      roundUp = int.parse(fraction[scale]) >= 5;
      fraction = fraction.substring(0, scale);
    }
    var units = whole * _p(scale) + BigInt.parse(fraction.padRight(scale, '0').isEmpty ? '0' : fraction.padRight(scale, '0'));
    if (roundUp) units += BigInt.one;
    return Decimal._(negative ? -units : units, scale);
  }

  static Decimal? tryParse(Object? value, [int scale = 4]) {
    try {
      return Decimal.parse(value, scale);
    } on FormatException {
      return null;
    }
  }

  Decimal _align(Decimal other) => other.scale == scale ? other : other.rescale(scale);

  /// Changes the scale with half-up rounding.
  Decimal rescale(int newScale) {
    if (newScale == scale) return this;
    if (newScale > scale) return Decimal._(units * _p(newScale - scale), newScale);
    final divisor = _p(scale - newScale);
    final half = divisor ~/ BigInt.two;
    final adjusted = units.isNegative ? units - half : units + half;
    return Decimal._(adjusted ~/ divisor, newScale);
  }

  Decimal operator +(Decimal other) => Decimal._(units + _align(other).units, scale);
  Decimal operator -(Decimal other) => Decimal._(units - _align(other).units, scale);
  Decimal operator -() => Decimal._(-units, scale);

  /// Product rounded to this value's scale (price × quantity keeps the money scale).
  Decimal operator *(Decimal other) {
    final raw = units * other.units;
    return Decimal._(raw, scale + other.scale).rescale(scale);
  }

  /// Percentage of this value (`percent` given as 10 for 10 %), rounded to this scale.
  Decimal percent(Decimal percent) => (this * percent).divideByInt(100);

  Decimal divideByInt(int divisor) {
    final d = BigInt.from(divisor);
    final half = d ~/ BigInt.two;
    final adjusted = units.isNegative ? units - half : units + half;
    return Decimal._(adjusted ~/ d, scale);
  }

  bool get isZero => units == BigInt.zero;
  bool get isNegative => units.isNegative;
  bool get isPositive => units > BigInt.zero;

  @override
  int compareTo(Decimal other) => units.compareTo(_align(other).units);
  bool operator <(Decimal other) => compareTo(other) < 0;
  bool operator <=(Decimal other) => compareTo(other) <= 0;
  bool operator >(Decimal other) => compareTo(other) > 0;
  bool operator >=(Decimal other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) => other is Decimal && compareTo(other) == 0;

  @override
  int get hashCode => rescale(6).units.hashCode;

  Decimal min(Decimal other) => this <= other ? this : _align(other);
  Decimal max(Decimal other) => this >= other ? this : _align(other);

  /// Canonical text with exactly [scale] decimals (`"12.5000"`), as the API stores it.
  @override
  String toString() {
    final negative = units.isNegative;
    final digits = units.abs().toString().padLeft(scale + 1, '0');
    final whole = digits.substring(0, digits.length - scale);
    final fraction = digits.substring(digits.length - scale);
    return '${negative ? '-' : ''}$whole${scale > 0 ? '.$fraction' : ''}';
  }

  /// Display text with [places] decimals and the given separators (pt-BR: `,` and `.`).
  String format({int places = 2, String decimalSeparator = ',', String groupSeparator = '.'}) {
    final text = rescale(places).toString();
    final negative = text.startsWith('-');
    final body = negative ? text.substring(1) : text;
    final parts = body.split('.');
    final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => groupSeparator);
    return '${negative ? '-' : ''}$whole${places > 0 ? '$decimalSeparator${parts[1]}' : ''}';
  }
}

Decimal money(Object? value) => Decimal.parse(value, 4);
Decimal quantity(Object? value) => Decimal.parse(value, 6);
