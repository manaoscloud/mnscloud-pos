import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/core/models.dart';
import 'package:mnscloud_pos/src/core/money.dart';
import 'package:mnscloud_pos/src/fiscal/fiscal_device.dart';
import 'package:mnscloud_pos/src/fiscal/nfce.dart';
import 'package:mnscloud_pos/src/offline/sqlite_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'nfce_test.dart' as nfce;

class MemorySecrets implements FiscalSecrets {
  final values = <String, String>{};
  @override
  Future<String?> readSecret(String name) async => values[name];
  @override
  Future<void> writeSecret(String name, String? value) async => value == null ? values.remove(name) : values[name] = value;
}

class FakeFiscal implements FiscalTransport {
  FakeFiscal(this.config);
  Map<String, dynamic> config;
  int credentialReleases = 0;
  int allocations = 0;
  @override
  Future<Map<String, dynamic>> fiscalConfig({bool credentials = false}) async {
    if (credentials) credentialReleases++;
    final public = Map<String, dynamic>.from(config)..remove('_credentials');
    return {...public, if (credentials) 'credentials': config['_credentials']};
  }

  @override
  Future<Map<String, dynamic>> allocateRange(String environment) async {
    allocations++;
    final items = [
      {'FnrUUID': 'range-1', 'FseModel': '65', 'FseSeries': 900, 'FseEnvironment': environment, 'FnrFromNumber': 1, 'FnrToNumber': 2, 'FnrStatus': 'active'},
    ];
    config = {...config, 'ranges': items};
    return {'items': items};
  }
}

void main() {
  test('contingency NFC-e: config, audited credentials, range numbers and the queued operation', () async {
    final key = nfce.testKey();
    final store = SqliteOfflineStore.open(':memory:');
    final secrets = MemorySecrets();
    final server = FakeFiscal({
      'enabled': true,
      'environment': 'homologation',
      'issuer': nfce.issuer,
      'rulePackage': {'uuid': 'pkg', 'version': 1},
      'rules': [nfce.rule({})],
      'ranges': [],
      'qrCodeUrl': 'http://homnfce.sefaz.am.gov.br/nfceweb/consultarNFCe.jsp',
      'consultationUrl': 'www.sefaz.am.gov.br/nfce/consulta',
      '_credentials': {'privateKeyPkcs8Base64': base64Encode(key.pkcs8), 'certificateBase64': 'CERT', 'cscId': '000001', 'csc': 'CSC'},
    });
    final fiscal = FiscalDevice(store, secrets, server);
    await fiscal.refresh();
    await fiscal.refresh();
    expect(server.credentialReleases, 1, reason: 'credentials are released once, then kept in the secure storage');
    expect(server.allocations, 1);
    expect(fiscal.enabled, isTrue);
    expect(store.meta('fiscal_config')!.contains('privateKey'), isFalse, reason: 'secrets never go to the database');

    final item = CatalogItem(uuid: 'p1', name: 'AGUA', price: Decimal.parse('3.00'), priceSource: 'base', code: 'SPR1', nature: 'goods',
        fiscal: {'ncm': '22021000', 'unit': 'UN', 'origin': 0});
    final cart = [CartLine(item: item, quantity: Decimal.parse('2', 6))];
    final payments = [PaymentEntry(method: PaymentMethod.cash, amount: Decimal.parse('10.00'))];
    Future<Map<String, dynamic>> emit(String saleUuid) => fiscal.emitContingency(
        sale: {'saleUUID': saleUuid}, cart: cart, payments: payments, change: '4.00', operatorUuid: 'op', saleOperationUuid: 'sale-op-$saleUuid');
    final first = await emit('sale-1');
    expect((first['number'], first['series']), (1, 900));
    expect(first['accessKey'].toString()[34], '9');
    expect(first['xml'].toString().contains('<tpEmis>9</tpEmis>'), isTrue);
    expect(store.fiscalDocument('sale-1')!['accessKey'], first['accessKey']);
    final queued = store.dueOperations(DateTime.now().millisecondsSinceEpoch).single;
    final op = jsonDecode(queued.operation) as Map;
    expect(op['kind'], 'pos.fiscal.offline');
    expect(op['dependsOn'], ['sale-op-sale-1']);
    expect((await emit('sale-2'))['number'], 2);
    await expectLater(emit('sale-3'), throwsA(isA<StateError>()), reason: 'range exhausted: connect for a new one');
    expect(cents('6.00'), 600);

    // A terminal disabled on the server wipes the local credentials.
    server.config = {'enabled': false};
    await fiscal.refresh();
    expect(fiscal.enabled, isFalse);
    expect(secrets.values, isEmpty);
    store.close();
  });

  test('schema v1 → v2 migration keeps pending operations and backs up the file first', () {
    final dir = Directory.systemTemp.createTempSync('pos-v1');
    final path = '${dir.path}/pos.db';
    final v1 = sqlite3.open(path);
    v1.execute('''
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
      CREATE TABLE outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_uuid TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
        operation TEXT NOT NULL, hash TEXT NOT NULL, operator_uuid TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL DEFAULT 0, result TEXT, error TEXT, created_at TEXT NOT NULL) STRICT;
      INSERT INTO outbox (operation_uuid, kind, operation, hash, operator_uuid, created_at) VALUES ('op-1', 'pos.sale.submit', '{}', 'h', 'o', 'now');
      PRAGMA user_version = 1;
    ''');
    v1.close();
    final store = SqliteOfflineStore.open(path);
    expect(File('$path.backup-v1').existsSync(), isTrue);
    expect(store.outboxCounts(), {'pending': 1});
    expect(store.fiscalDocument('none'), isNull, reason: 'v2 table exists');
    store.close();
    dir.deleteSync(recursive: true);
  });
}
