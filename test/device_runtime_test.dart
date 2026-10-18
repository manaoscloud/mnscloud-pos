import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/core/canonical_json.dart';
import 'package:mnscloud_pos/src/core/models.dart';
import 'package:mnscloud_pos/src/core/money.dart';
import 'package:mnscloud_pos/src/offline/device_runtime.dart';
import 'package:mnscloud_pos/src/offline/sqlite_store.dart';
import 'package:mnscloud_pos/src/offline/sync_engine.dart';

class NoServer implements SyncTransport {
  @override
  Future<Map<String, dynamic>> bootstrap(String? cursor) => throw StateError('offline');
  @override
  Future<Map<String, dynamic>> changes(String cursor) => throw StateError('offline');
  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> entries) => throw StateError('offline');
}

void main() {
  final now = DateTime.utc(2026, 10, 18, 12);
  late SqliteOfflineStore store;
  late DeviceRuntime device;

  setUp(() {
    store = SqliteOfflineStore.open(':memory:');
    device = DeviceRuntime(
      store: store,
      engine: SyncEngine(store, NoServer(), clock: () => now),
      deviceUuid: 'device-1',
      terminalUuid: 'terminal-1',
      clock: () => now,
    );
    store.setMeta('grant', jsonEncode({
      'SogUUID': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'SogStatus': 'active',
      'SogValidUntil': '2026-10-19 12:00:00.000000',
      'SogMaxSaleValue': '100.0000',
      'SogMaxTotalValue': '1000.0000',
      'SogMaxItems': 3,
      'SogMaxDiscountPercent': '5.0000',
      'SogOperators': ['BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'],
    }));
    store.beginBootstrap();
    store.stageCatalog([
      {
        'productUUID': 'p1', 'changedAt': 'x', 'deleted': false, 'id': 'SPR1', 'name': 'AGUA', 'barcode': '789',
        'basePrice': '3.00', 'barcodes': [{'barcode': 'CX6', 'quantity': 6}],
        'priceRules': [{'priority': 1, 'price': 2.5, 'minQuantity': 6, 'validFrom': null, 'validUntil': null}],
      },
    ]);
    store.finishBootstrap('c0');
  });
  tearDown(() => store.close());

  CartLine line(CatalogItem item, String qty, [String discount = '0']) =>
      CartLine(item: item, quantity: Decimal.parse(qty, 6))..discount = Decimal.parse(discount);

  test('offline shift: open, sell within limits, withdraw, close; every step queued in order', () async {
    final session = device.openSession('operator', Decimal.parse('50'));
    expect(device.localSession()!.uuid, session.uuid);
    final box = device.scan('cx6')!;
    expect((box.quantity, box.item.price), (Decimal.parse('6', 6), Decimal.parse('2.5')), reason: 'tier price for the box');
    final cart = [line(box.item, '6')];
    final base = {
      'saleUUID': 'sale-1', 'terminalUUID': 'terminal-1', 'sessionUUID': session.uuid, 'contractVersion': 1,
      'occurredAt': now.toIso8601String(), 'items': [], 'payments': [], 'change': '0',
    };
    final sale = device.recordSale('operator', base, Decimal.parse('15'), Decimal.parse('15'), cart);
    expect(sale['origin'], 'device');
    expect(device.localSession()!.expectedCash, Decimal.parse('65'));
    device.cashMovement('operator', session.uuid, 'withdrawal', Decimal.parse('20'), 'bank');
    expect(() => device.cashMovement('operator', session.uuid, 'withdrawal', Decimal.parse('999'), null),
        throwsA(isA<OfflineLimitException>()));
    device.closeSession('operator', session.uuid, Decimal.parse('45'), null);
    expect(device.localSession(), isNull);

    final queued = store.dueOperations(now.millisecondsSinceEpoch);
    expect(queued.map((e) => e.kind), ['pos.cash.open', 'pos.sale.submit', 'pos.cash.movement', 'pos.cash.close']);
    final open = jsonDecode(queued.first.operation) as Map;
    final submit = jsonDecode(queued[1].operation) as Map;
    expect(submit['dependsOn'], [open['operationUUID']]);
    expect(submit['grantUUID'], 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    expect(submit['payload']['saleHash'], payloadHash(submit['payload']['sale']));
    expect(queued[1].hash, payloadHash(submit));
    expect(device.pendingOperations, 4);

    // No backend at all: the sync fails, nothing is lost.
    final report = await device.engine.sync();
    expect(report.reachable, isFalse);
    expect(device.pendingOperations, 4);
  });

  test('offline limits refuse the sale before anything is stored', () {
    final session = device.openSession('operator', Decimal.zero());
    final item = device.search('agua').single;
    final base = {'saleUUID': 's', 'sessionUUID': session.uuid, 'occurredAt': 'x'};
    expect(() => device.recordSale('operator', base, Decimal.parse('150'), Decimal.zero(), [line(item, '50')]),
        throwsA(isA<OfflineLimitException>()));
    expect(() => device.recordSale('operator', base, Decimal.parse('3'), Decimal.zero(), [line(item, '1', '1.00')]),
        throwsA(isA<OfflineLimitException>()), reason: 'discount above the offline limit');
    store.setMeta('grant', null);
    expect(() => device.recordSale('operator', base, Decimal.parse('3'), Decimal.zero(), [line(item, '1')]),
        throwsA(isA<OfflineLimitException>()), reason: 'no grant, no offline sale');
    expect(device.pendingOperations, 1, reason: 'only the cash open');
  });
}
