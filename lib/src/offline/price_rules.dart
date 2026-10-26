import '../core/money.dart';

/// Price of an item on the device, resolved like the server (ProcPosCatalogList /
/// ProcSalePriceResolve): among the price rules valid at [at] with a minimum quantity up to the
/// sold quantity, the lowest priority wins, then the highest tier; otherwise the base price.
class ResolvedPrice {
  const ResolvedPrice(this.price, this.source);

  final Decimal price;

  /// `price_list` or `base`.
  final String source;
}

ResolvedPrice resolvePrice({
  required Decimal basePrice,
  required List<dynamic> rules,
  required Decimal quantity,
  required DateTime at,
}) {
  Map<String, dynamic>? best;
  for (final raw in rules) {
    if (raw is! Map) continue;
    final rule = raw.cast<String, dynamic>();
    if (!_applies(rule, quantity, at)) continue;
    if (best == null || _beats(rule, best)) best = rule;
  }
  if (best == null) return ResolvedPrice(basePrice, 'base');
  return ResolvedPrice(Decimal.parse(best['price']), 'price_list');
}

/// The rule is valid at [at] and its minimum quantity is reached.
bool _applies(Map<String, dynamic> rule, Decimal quantity, DateTime at) {
  final from = _date(rule['validFrom']);
  final until = _date(rule['validUntil']);
  if (from != null && from.isAfter(at)) return false;
  if (until != null && !until.isAfter(at)) return false;
  return !(_minQuantity(rule) > quantity);
}

/// Lower priority wins; on a tie, the higher quantity tier wins.
bool _beats(Map<String, dynamic> rule, Map<String, dynamic> best) {
  final priority = _int(rule['priority']);
  final bestPriority = _int(best['priority']);
  return priority < bestPriority || (priority == bestPriority && _minQuantity(rule) > _minQuantity(best));
}

Decimal _minQuantity(Map<String, dynamic> rule) => Decimal.parse(rule['minQuantity'] ?? 1, 6);

int _int(Object? value) => value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;

/// Server DATETIME text (`2026-10-18 12:00:00.000000`, server time) or ISO-8601.
DateTime? _date(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty || text == 'null') return null;
  return DateTime.tryParse(text.contains('T') ? text : text.replaceFirst(' ', 'T'));
}
