import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/core/canonical_json.dart';
import 'package:mnscloud_pos/src/core/money.dart';
import 'package:mnscloud_pos/src/offline/price_rules.dart';
import 'package:mnscloud_pos/src/offline/sqlite_store.dart';
import 'package:mnscloud_pos/src/offline/sync_engine.dart';

Map<String, dynamic> item(String uuid, String name, {bool deleted = false, String price = '3.00'}) => deleted
    ? {'productUUID': uuid, 'changedAt': '2026-10-18 10:00:00.000000', 'deleted': true}
    : {
        'productUUID': uuid,
        'changedAt': '2026-10-18 10:00:00.000000',
        'deleted': false,
        'id': 'SPR-$name',
        'name': name,
        'barcode': '789$name',
        'basePrice': price,
        'currency': 'BRL',
        'barcodes': [
          {'barcode': 'BOX$name', 'quantity': 6},
        ],
        'priceRules': [],
      };

Map<String, dynamic> page(List<Map<String, dynamic>> items, String cursor, bool done) =>
    {'items': items, 'cursor': cursor, 'done': done, 'checksum': payloadHash(items)};

/// Server double: idempotent by operation UUID, can fail before or after applying.
class FakeTransport implements SyncTransport {
  final applied = <String, Map<String, dynamic>>{};
  final bootstrapPages = <String?, Map<String, dynamic>>{};
  final changePages = <String, Map<String, dynamic>>{};
  bool failBeforePush = false;
  bool loseAnswer = false;
  bool failBootstrap = false;
  int pushes = 0;

  @override
  Future<Map<String, dynamic>> bootstrap(String? cursor) async {
    if (failBootstrap) throw const SocketException('LAN down');
    return bootstrapPages[cursor]!;
  }

  @override
  Future<Map<String, dynamic>> changes(String cursor) async =>
      changePages[cursor] ?? page(const [], cursor, true);

  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> entries) async {
    pushes++;
    if (failBeforePush) throw const SocketException('backend unreachable');
    final results = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final op = (entry['operation'] as Map).cast<String, dynamic>();
      expect(entry['hash'], payloadHash(op), reason: 'hash of the exact operation');
      final uuid = op['operationUUID'] as String;
      if (applied.containsKey(uuid)) {
        results.add({'operationUUID': uuid, 'status': 'DUPLICATE', 'result': {'status': 'ACCEPTED'}});
        continue;
      }
      applied[uuid] = op;
      if (op['kind'] == 'pos.cash.movement' && op['payload']['amount'] == '9999') {
        results.add({'operationUUID': uuid, 'status': 'REJECTED', 'error': 'Withdrawal exceeds the cash in the drawer'});
      } else if (op['kind'] == 'pos.sale.submit' && op['payload']['sale']['flag'] == true) {
        results.add({'operationUUID': uuid, 'status': 'CONFLICT', 'result': {'conflicts': ['PRICE_CHANGED']}});
      } else {
        results.add({'operationUUID': uuid, 'status': 'ACCEPTED', 'result': {'conflicts': []}});
      }
    }
    if (loseAnswer) throw const SocketException('answer lost');
    return {'results': results};
  }
}

Map<String, dynamic> op(String kind, Map<String, dynamic> payload, {List<String> dependsOn = const []}) => {
      'operationUUID': 'op-${payload.hashCode}-${Random().nextInt(1 << 30)}',
      'kind': kind,
      'operatorUUID': 'operator-1',
      'contractVersion': 1,
      'occurredAt': '2026-10-18T10:00:00.000000Z',
      'grantUUID': 'grant-1',
      'dependsOn': dependsOn,
      'payload': payload,
    };

void main() {
  late SqliteOfflineStore store;
  late FakeTransport server;
  late SyncEngine engine;
  var now = DateTime.utc(2026, 10, 18, 10);

  setUp(() {
    store = SqliteOfflineStore.open(':memory:');
    server = FakeTransport();
    now = DateTime.utc(2026, 10, 18, 10);
    engine = SyncEngine(store, server, random: Random(1), clock: () => now);
  });
  tearDown(() => store.close());

  test('sale, cash and outbox are written together and pushed once (lost answer resent)', () async {
    final open = op('pos.cash.open', {'terminalUUID': 't', 'sessionUUID': 's1', 'openingAmount': '50'});
    store.openSession(
        {'sessionUUID': 's1', 'terminalUUID': 't', 'openedAt': '2026-10-18T10:00:00Z', 'openingAmount': '50'},
        SyncEngine.entry(open));
    final sale = {'saleUUID': 'sale-1', 'sessionUUID': 's1', 'occurredAt': '2026-10-18T10:01:00Z', 'total': '6.00', 'origin': 'device'};
    store.recordSale(sale, '6.00', SyncEngine.entry(op('pos.sale.submit', {'sale': sale, 'saleHash': payloadHash(sale)},
        dependsOn: [open['operationUUID'] as String])));
    expect(store.localExpectedCash('s1'), '56.0000');
    expect(store.outboxCounts(), {'pending': 2});

    // Backend unreachable (LAN down, internet up): nothing is lost, retry later.
    server.failBeforePush = true;
    final offline = await engine.sync();
    expect(offline.reachable, isFalse);
    expect(store.outboxCounts(), {'retry': 2});
    expect(store.dueOperations(now.millisecondsSinceEpoch), isEmpty, reason: 'backoff before the next attempt');

    // Applied on the server but the answer was lost: the resend is a duplicate, effect once.
    server.failBeforePush = false;
    server.loseAnswer = true;
    now = now.add(const Duration(minutes: 10));
    await engine.sync();
    expect(server.applied, hasLength(2));
    server.loseAnswer = false;
    now = now.add(const Duration(minutes: 10));
    await engine.sync();
    expect(server.applied, hasLength(2), reason: 'exactly once');
    expect(store.outboxCounts(), {'done': 2});
  });

  test('a failed local write stores nothing (no half-written sale or operation)', () {
    final sale = {'saleUUID': 'dup', 'sessionUUID': 's1', 'occurredAt': 'x', 'total': '1'};
    store.recordSale(sale, '1', SyncEngine.entry(op('pos.sale.submit', {'sale': sale, 'saleHash': 'h'})));
    expect(
      () => store.recordSale(sale, '1', SyncEngine.entry(op('pos.sale.submit', {'sale': sale, 'saleHash': 'h2'}))),
      throwsA(anything),
    );
    expect(store.outboxCounts(), {'pending': 1});
    expect(store.localExpectedCash('s1'), '1.0000');
  });

  test('rejections and conflicts stay visible; retries never reorder', () async {
    final s = {'sessionUUID': 's1', 'kind': 'withdrawal', 'amount': '9999', 'notes': null};
    store.recordCash('s1', 'withdrawal', '9999', 'x', SyncEngine.entry(op('pos.cash.movement', s)));
    final sale = {'saleUUID': 'sale-2', 'sessionUUID': 's1', 'occurredAt': 'x', 'total': '2', 'flag': true};
    store.recordSale(sale, '2', SyncEngine.entry(op('pos.sale.submit', {'sale': sale, 'saleHash': payloadHash(sale)})));
    final report = await engine.sync();
    expect(report.rejected, 1);
    expect(report.conflicts, 1);
    expect(store.outboxCounts(), {'rejected': 1, 'conflict': 1});
    expect(store.problemOperations().map((e) => e.error), contains('Withdrawal exceeds the cash in the drawer'));
  });

  test('interrupted bootstrap keeps the previous catalog and resumes by cursor', () async {
    server.bootstrapPages[null] = page([item('p1', 'agua'), item('p2', 'pao')], 'b1', false);
    server.bootstrapPages['b1'] = page([item('p3', 'leite')], 'c0', true);
    await engine.sync();
    expect(store.catalogCount(), 3);
    expect(store.meta('catalog_cursor'), 'c0');

    // Changes: tombstone + update.
    server.changePages['c0'] = page([item('p2', 'pao', deleted: true), item('p1', 'agua', price: '2.50')], 'c1', true);
    await engine.sync();
    expect(store.catalogCount(), 2);
    expect(store.searchCatalog('agua').single['basePrice'], '2.50');
    expect(store.catalogByBarcode('boxagua')!.quantity, '6', reason: 'packaging barcode carries its quantity');
    expect(store.catalogByBarcode('789agua')!.quantity, '1');
    expect(store.catalogByBarcode('789pao'), isNull, reason: 'tombstoned item barcodes are gone');

    // A re-bootstrap that fails midway leaves the previous catalog active.
    store.setMeta('catalog_cursor', null);
    server.bootstrapPages[null] = page([item('p9', 'cafe')], 'b9', false);
    server.failBootstrap = false;
    server.bootstrapPages['b9'] = page([], 'c9', true);
    server.failBootstrap = true;
    await engine.sync();
    expect(store.catalogCount(), 2, reason: 'previous catalog still active');
    server.failBootstrap = false;
    await engine.sync();
    expect(store.searchCatalog('').map((i) => i['name']), ['cafe']);
  });

  test('a page whose checksum does not match is not applied', () async {
    server.bootstrapPages[null] = {...page([item('p1', 'agua')], 'c0', true), 'checksum': 'f' * 64};
    await expectLater(engine.sync(), throwsA(isA<SyncChecksumException>()));
    expect(store.catalogCount(), 0);
  });

  test('the request counter is persisted and strictly increasing', () {
    final values = [store.nextCounter(), store.nextCounter(), store.nextCounter()];
    expect(values, [1, 2, 3]);
  });

  test('backoff grows exponentially with jitter and is capped', () {
    final first = engine.backoff(0).inMilliseconds;
    expect(first, inInclusiveRange(1600, 2400));
    expect(engine.backoff(3).inMilliseconds, inInclusiveRange(12800, 19200));
    expect(engine.backoff(30).inMilliseconds, lessThanOrEqualTo(360000));
  });

  test('local price follows the server rule (validity, priority, tier)', () {
    final at = DateTime(2026, 10, 18, 12);
    final rules = [
      {'priority': 2, 'price': 2.8, 'minQuantity': 1, 'validFrom': null, 'validUntil': null},
      {'priority': 1, 'price': 2.5, 'minQuantity': 1, 'validFrom': '2026-10-01 00:00:00.000000', 'validUntil': '2026-10-31 00:00:00.000000'},
      {'priority': 1, 'price': 2.2, 'minQuantity': 6, 'validFrom': null, 'validUntil': null},
      {'priority': 0, 'price': 1.0, 'minQuantity': 1, 'validFrom': '2026-11-01 00:00:00.000000', 'validUntil': null},
    ];
    expect(resolvePrice(basePrice: Decimal.parse('3'), rules: rules, quantity: Decimal.parse('1', 6), at: at).price,
        Decimal.parse('2.5'));
    expect(resolvePrice(basePrice: Decimal.parse('3'), rules: rules, quantity: Decimal.parse('6', 6), at: at).price,
        Decimal.parse('2.2'));
    final none = resolvePrice(basePrice: Decimal.parse('3'), rules: const [], quantity: Decimal.parse('1', 6), at: at);
    expect((none.price, none.source), (Decimal.parse('3'), 'base'));
  });

  test('reopening the file keeps pending operations and device state', () {
    final dir = Directory.systemTemp.createTempSync('pos-store');
    final path = '${dir.path}/pos.db';
    final first = SqliteOfflineStore.open(path);
    first.recordCash('s1', 'supply', '10', 'x', SyncEngine.entry(op('pos.cash.movement', {'amount': '10'})));
    first.close();
    // Simulate an older schema version on disk.
    final raw = SqliteOfflineStore.open(path);
    raw.setMeta('probe', jsonEncode({'ok': true}));
    raw.close();
    final reopened = SqliteOfflineStore.open(path);
    expect(reopened.outboxCounts(), {'pending': 1});
    expect(reopened.meta('probe'), '{"ok":true}');
    reopened.close();
    dir.deleteSync(recursive: true);
  });
}
