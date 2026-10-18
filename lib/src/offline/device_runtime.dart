import 'dart:convert';

import '../core/canonical_json.dart';
import '../core/ids.dart';
import '../core/models.dart';
import '../core/money.dart';
import 'price_rules.dart';
import 'store.dart';
import 'sync_engine.dart';

/// Offline authorization as issued by the server (`SyncOfflineGrant`).
class OfflineGrant {
  OfflineGrant(this.json);

  final Map<String, dynamic> json;

  String get uuid => normalizeUuid(json['SogUUID'].toString());
  DateTime? get validUntil => _serverDate(json['SogValidUntil']);
  Decimal get maxSaleValue => Decimal.parse(json['SogMaxSaleValue']);
  Decimal get maxTotalValue => Decimal.parse(json['SogMaxTotalValue']);
  int get maxItems => int.tryParse(json['SogMaxItems']?.toString() ?? '') ?? 100;
  Decimal get maxDiscountPercent => Decimal.parse(json['SogMaxDiscountPercent']);
  bool get active => json['SogStatus']?.toString() == 'active';
  List<String> get operators =>
      [for (final o in (json['SogOperators'] as List? ?? const [])) normalizeUuid(o.toString())];

  bool validAt(DateTime at) => active && validUntil != null && at.isBefore(validUntil!);

  static DateTime? _serverDate(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    return DateTime.tryParse(text.contains('T') ? text : text.replaceFirst(' ', 'T'));
  }
}

/// Why an offline sale cannot be recorded (shown to the operator; nothing is stored).
class OfflineLimitException implements Exception {
  OfflineLimitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Local-first operation of a provisioned installation: cash events and sales are written to the
/// local store with their outbox operation, then pushed by the [SyncEngine]. The same path runs
/// online and offline, so losing the network (or only the LAN to the backend) changes nothing for
/// the operator.
class DeviceRuntime {
  DeviceRuntime({
    required this.store,
    required this.engine,
    required this.deviceUuid,
    required this.terminalUuid,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final OfflineStore store;
  final SyncEngine engine;
  final String deviceUuid;
  final String terminalUuid;
  final DateTime Function() _clock;

  OfflineGrant? get grant {
    final raw = store.meta('grant');
    if (raw == null) return null;
    final json = jsonDecode(raw);
    return json is Map ? OfflineGrant(json.cast<String, dynamic>()) : null;
  }

  Map<String, dynamic>? get terminalJson {
    final raw = store.meta('terminal');
    return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  bool get catalogReady => store.meta('catalog_cursor') != null;

  String _now() => _clock().toUtc().toIso8601String();

  Map<String, dynamic> _operation(String kind, String operator, Map<String, dynamic> payload,
          {List<String> dependsOn = const []}) =>
      {
        'operationUUID': uuidV4(),
        'kind': kind,
        'operatorUUID': operator,
        'correlationId': deviceUuid,
        'contractVersion': 1,
        'occurredAt': _now(),
        'grantUUID': grant?.uuid,
        'dependsOn': dependsOn,
        'payload': payload,
      };

  // ---------- Cash session

  CashSession? localSession() {
    final row = store.openLocalSession(terminalUuid);
    if (row == null) return null;
    final uuid = row['session_uuid'] as String;
    return CashSession(
      uuid: uuid,
      status: 'open',
      openedAt: DateTime.tryParse(row['opened_at'] as String) ?? _clock(),
      openingAmount: Decimal.parse(row['opening_amount']),
      expectedCash: Decimal.parse(store.localExpectedCash(uuid)),
      saleCount: 0,
      saleTotal: Decimal.zero(),
      pendingPayments: 0,
      totalsByMethod: const {},
    );
  }

  CashSession openSession(String operator, Decimal openingAmount) {
    final session = uuidV4();
    final at = _now();
    final operation = _operation('pos.cash.open', operator,
        {'terminalUUID': terminalUuid, 'sessionUUID': session, 'openingAmount': openingAmount.toString()});
    store.openSession(
      {'sessionUUID': session, 'terminalUUID': terminalUuid, 'openedAt': at, 'openingAmount': openingAmount.toString()},
      SyncEngine.entry(operation),
    );
    return localSession()!;
  }

  String _openOperation(String sessionUuid) =>
      store.openLocalSession(terminalUuid)?['open_operation_uuid'] as String? ?? '';

  CashSession cashMovement(String operator, String sessionUuid, String kind, Decimal amount, String? notes) {
    if (kind == 'withdrawal' && amount > Decimal.parse(store.localExpectedCash(sessionUuid))) {
      throw OfflineLimitException('Withdrawal exceeds the cash in the drawer.');
    }
    final operation = _operation(
      'pos.cash.movement',
      operator,
      {'sessionUUID': sessionUuid, 'kind': kind, 'amount': amount.toString(), 'notes': notes},
      dependsOn: [_openOperation(sessionUuid)],
    );
    store.recordCash(sessionUuid, kind, amount.toString(), operation['occurredAt'] as String, SyncEngine.entry(operation));
    return localSession()!;
  }

  void closeSession(String operator, String sessionUuid, Decimal counted, String? notes) {
    final operation = _operation(
      'pos.cash.close',
      operator,
      {'sessionUUID': sessionUuid, 'countedCash': counted.toString(), 'notes': notes},
      dependsOn: [_openOperation(sessionUuid)],
    );
    store.closeSession(sessionUuid, counted.toString(), operation['occurredAt'] as String, SyncEngine.entry(operation));
  }

  // ---------- Catalog

  CatalogItem _catalogItem(Map<String, dynamic> item, [Decimal? quantity]) {
    final resolved = resolvePrice(
      basePrice: Decimal.parse(item['basePrice']),
      rules: item['priceRules'] as List? ?? const [],
      quantity: quantity ?? Decimal.fromInt(1, 6),
      at: _clock(),
    );
    return CatalogItem(
      uuid: normalizeUuid(item['productUUID'].toString()),
      name: item['name']?.toString() ?? '',
      price: resolved.price,
      priceSource: resolved.source,
      code: item['id']?.toString(),
      barcode: item['barcode']?.toString(),
      nature: item['fiscalNature']?.toString(),
    );
  }

  List<CatalogItem> search(String text) => [for (final i in store.searchCatalog(text)) _catalogItem(i)];

  ({CatalogItem item, Decimal quantity})? scan(String code) {
    final found = store.catalogByBarcode(code);
    if (found == null) return null;
    final quantity = Decimal.parse(found.quantity, 6);
    return (item: _catalogItem(found.item, quantity), quantity: quantity);
  }

  // ---------- Sales

  /// Validates the offline limits; the server checks again when the sale arrives.
  void checkLimits(Map<String, dynamic> sale, Decimal total, List<CartLine> cart) {
    final g = grant;
    final now = _clock();
    if (g == null || !g.validAt(now)) {
      throw OfflineLimitException('This device has no valid offline authorization. Connect to sync it.');
    }
    if (total > g.maxSaleValue) {
      throw OfflineLimitException('The sale is above the offline limit of this device.');
    }
    if (cart.length > g.maxItems) throw OfflineLimitException('Too many items for an offline sale.');
    for (final line in cart) {
      if (line.discount > line.gross.percent(g.maxDiscountPercent)) {
        throw OfflineLimitException('Discount above the offline limit.');
      }
    }
  }

  /// Records the sale with its outbox operation in one transaction (throws, storing nothing, on
  /// any write failure). Returns the stored sale payload.
  Map<String, dynamic> recordSale(String operator, Map<String, dynamic> base, Decimal total, Decimal cashNet,
      List<CartLine> cart) {
    final sale = {...base, 'origin': 'device'};
    checkLimits(sale, total, cart);
    final sessionUuid = sale['sessionUUID'] as String;
    final operation = _operation(
      'pos.sale.submit',
      operator,
      {'sale': sale, 'saleHash': payloadHash(sale)},
      dependsOn: [_openOperation(sessionUuid)],
    );
    store.recordSale({...sale, 'total': total.toString()}, cashNet.toString(), SyncEngine.entry(operation));
    return sale;
  }

  Map<String, int> get outbox => store.outboxCounts();
  int get pendingOperations => (outbox['pending'] ?? 0) + (outbox['retry'] ?? 0);
  int get problemCount => (outbox['rejected'] ?? 0) + (outbox['conflict'] ?? 0);
  String? get lastCatalogSync => store.meta('catalog_synced_at');
}
