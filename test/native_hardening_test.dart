import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/core/canonical_json.dart';
import 'package:mnscloud_pos/src/core/models.dart';
import 'package:mnscloud_pos/src/core/money.dart';
import 'package:mnscloud_pos/src/offline/background_sync_io.dart';
import 'package:mnscloud_pos/src/offline/device_host.dart';
import 'package:mnscloud_pos/src/offline/p256.dart';
import 'package:mnscloud_pos/src/offline/session_vault.dart';
import 'package:mnscloud_pos/src/offline/sqlite_store.dart';
import 'package:mnscloud_pos/src/offline/sync_engine.dart';
import 'package:mnscloud_pos/src/security/operator_pin.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

const operatorUuid = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const terminalUuid = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const tenantUuid = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

String serverDate(DateTime at) => at.toUtc().toIso8601String().replaceFirst('T', ' ').replaceFirst('Z', '');

Map<String, dynamic> grantJson({String status = 'active'}) => {
      'SogUUID': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'SogStatus': status,
      'SogValidUntil': serverDate(DateTime.now().add(const Duration(days: 1))),
      'SogMaxSaleValue': '100.0000',
      'SogMaxTotalValue': '1000.0000',
      'SogMaxItems': 10,
      'SogMaxDiscountPercent': '5.0000',
      'SogOperators': [operatorUuid.replaceAll('-', '').toUpperCase()],
    };

Map<String, dynamic> catalogItem() => {
      'productUUID': 'p1', 'changedAt': 'x', 'deleted': false, 'id': 'SPR1', 'name': 'AGUA', 'barcode': '789',
      'basePrice': '3.00', 'barcodes': [], 'priceRules': [],
    };

/// A store provisioned for the register, with a stored session of the operator and a PIN.
SqliteOfflineStore provisioned({bool withSession = true}) {
  final store = SqliteOfflineStore.open(':memory:');
  store.setMeta('device', jsonEncode({'SdvUUID': 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE', 'PosTerminalPtmUUID': terminalUuid}));
  store.setMeta('terminal', jsonEncode({
    'PtmUUID': terminalUuid, 'PtmName': 'Caixa 1', 'PtmOfflineEnabled': '1', 'PtmPaymentMethods': 'cash',
    'PtmMaxDiscountPercent': '5',
  }));
  store.setMeta('grant', jsonEncode(grantJson()));
  store.beginBootstrap();
  store.stageCatalog([catalogItem()]);
  store.finishBootstrap('c0');
  if (withSession) {
    final vault = SessionVault(store);
    vault.saveRefreshToken('r1');
    vault.saveUser(uuid: operatorUuid, name: 'Operadora', email: 'op@example.invalid');
    vault.saveTenant(uuid: tenantUuid, name: 'Loja');
    vault.saveApiBase('https://dev.example/api/v1');
    OperatorPin(store, iterations: 1000).set(operatorUuid, '2468');
  }
  return store;
}

/// API double: the refresh answers with [refresh] or fails as unreachable.
class RefreshApi extends PosApi {
  RefreshApi({this.refreshAnswer})
      : super(ApiClient(
          baseUrl: 'https://dev.example/api/v1',
          // Offline: every other request fails like a missing network.
          client: MockClient((_) async => throw const SocketException('offline')),
        ));
  PosSessionGrant? refreshAnswer;
  final presented = <String?>[];

  @override
  Future<PosSessionGrant> refresh() async {
    presented.add(client.refreshToken);
    final answer = refreshAnswer;
    if (answer == null) throw ApiException(ApiFailureKind.unreachable, 'The server cannot be reached.');
    client.bearerToken = answer.accessToken;
    if (answer.refreshToken != null) client.refreshToken = answer.refreshToken;
    return answer;
  }

  @override
  Future<List<TenantOption>> tenants() async => [TenantOption(tenantUuid, 'Loja', null)];

  @override
  Future<List<PosTerminal>> terminals() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = P256Key.generate();
  setUp(() => FlutterSecureStorage.setMockInitialValues({'mnscloud_pos_device_key': key.privateBase64}));

  test('the bundled SQLite encrypts, and a clear store of an older release is encrypted in place', () {
    expect(SqliteOfflineStore.encryptionAvailable, isTrue, reason: 'hooks.user_defines.sqlite3.source: sqlite3mc');
    final dir = Directory.systemTemp.createTempSync('pos-enc');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/mnscloud-pos.db';
    final plain = SqliteOfflineStore.open(path);
    plain.setMeta('marker', 'VENDA-EM-CLARO-123');
    plain.close();
    File('$path.backup-v1').writeAsBytesSync(File(path).readAsBytesSync());
    expect(latin1.decode(File(path).readAsBytesSync()), contains('VENDA-EM-CLARO-123'));

    final keyHex = 'ab' * 32;
    final encrypted = SqliteOfflineStore.open(path, key: keyHex);
    expect(encrypted.meta('marker'), 'VENDA-EM-CLARO-123');
    encrypted.close();

    final bytes = File(path).readAsBytesSync();
    expect(latin1.decode(bytes), isNot(contains('VENDA-EM-CLARO-123')));
    expect(latin1.decode(bytes.sublist(0, 15)), isNot('SQLite format 3'));
    expect(SqliteOfflineStore.isPlain(path), isFalse);
    expect(File('$path.backup-v1').existsSync(), isFalse, reason: 'clear backups of older releases go too');
    expect(File('$path.encrypting').existsSync(), isFalse);
    expect(() => SqliteOfflineStore.open(path, key: 'cd' * 32), throwsA(anything));
    final reopened = SqliteOfflineStore.open(path, key: keyHex);
    expect(reopened.meta('marker'), 'VENDA-EM-CLARO-123');
    reopened.close();
  });

  test('one sync lease across the app and the background task, and an expired one is taken over', () {
    var now = DateTime.utc(2026, 11, 1, 12);
    final store = SqliteOfflineStore.open(':memory:');
    final vault = SessionVault(store, clock: () => now);
    expect(vault.acquire('app'), isTrue);
    expect(vault.acquire('background'), isFalse);
    vault.release('background');
    expect(vault.acquire('background'), isFalse, reason: 'only the holder releases');
    now = now.add(const Duration(minutes: 3));
    expect(vault.acquire('background'), isTrue, reason: 'a crashed holder blocks for at most the ttl');
    vault.release('background');
    expect(vault.acquire('app'), isTrue);
  });

  test('the PIN is a salted hash of its operator and wrong PINs are counted', () {
    final store = SqliteOfflineStore.open(':memory:');
    final pin = OperatorPin(store, iterations: 1000);
    expect(OperatorPin.valid('123'), isFalse);
    pin.set(operatorUuid, '2468');
    expect(store.meta('pin.hash'), startsWith(r'pbkdf2-sha256$1000$'));
    expect(store.meta('pin.hash'), isNot(contains('2468')));
    expect(pin.isSetFor(operatorUuid), isTrue);
    expect(pin.isSetFor('someone-else'), isFalse);
    expect(pin.verify('1111'), OperatorPin.maxFailures - 1);
    expect(pin.verify('2468'), isNull);
    expect(pin.verify('1111'), OperatorPin.maxFailures - 1, reason: 'a right PIN resets the count');
  });

  test('closed and reopened offline: PIN, then the provisioned register sells within the grant', () async {
    final store = provisioned();
    final api = RefreshApi();
    final controller = PosController(api, host: DeviceHost.over(store), pinIterations: 1000);
    await controller.restore();
    expect(controller.locked, isTrue);
    expect(controller.stage, PosStage.signIn);

    expect(await controller.unlock('0000'), OperatorPin.maxFailures - 1);
    expect(controller.locked, isTrue);
    expect(await controller.unlock('2468'), isNull);
    expect(api.presented, ['r1'], reason: 'the stored refresh token is tried first');
    expect(controller.locked, isFalse);
    expect(controller.connection, ConnectionStatus.unreachable);
    expect(controller.deviceMode, isTrue);
    expect(controller.terminal!.uuid, terminalUuid);
    expect(controller.user!.uuid, operatorUuid);
    expect(controller.stage, PosStage.openSession);

    await controller.openSession(Decimal.parse('50'));
    expect(controller.stage, PosStage.selling);
    expect(await controller.scan('789'), isTrue);
    controller.addPayment(PaymentEntry(method: PaymentMethod.cash, amount: Decimal.parse('3')));
    final sale = await controller.finish();
    expect(sale, isNotNull, reason: controller.error);
    expect(store.outboxCounts()['pending'], 2, reason: 'cash open and sale wait for the sync');
    controller.dispose();
  });

  test('five wrong PINs end the stored session and keep the pending sales', () async {
    final store = provisioned();
    store.setMeta('marker', 'pending');
    final controller = PosController(RefreshApi(), host: DeviceHost.over(store), pinIterations: 1000);
    await controller.restore();
    for (var i = 1; i < OperatorPin.maxFailures; i++) {
      expect(await controller.unlock('0000'), OperatorPin.maxFailures - i);
    }
    expect(await controller.unlock('0000'), 0);
    expect(controller.locked, isFalse);
    expect(controller.stage, PosStage.signIn);
    expect(SessionVault(store).refreshToken, isNull);
    expect(OperatorPin(store).isSetFor(operatorUuid), isFalse);
    expect(store.meta('device'), isNotNull, reason: 'the device stays provisioned');
    expect(store.meta('grant'), isNotNull);
  });

  test('reopened online: the rotated refresh token is stored at once', () async {
    final store = provisioned();
    final api = RefreshApi(
      refreshAnswer: PosSessionGrant(
        user: SignedInUser(uuid: operatorUuid, name: 'Operadora', email: 'op@example.invalid'),
        accessToken: 'a2',
        expiresIn: 900,
        refreshToken: 'r2',
      ),
    );
    final controller = PosController(api, host: DeviceHost.over(store), pinIterations: 1000);
    await controller.restore();
    await controller.unlock('2468');
    expect(api.presented, ['r1']);
    expect(SessionVault(store).refreshToken, 'r2');
    expect(controller.connection, ConnectionStatus.online);
    expect(controller.tenant!.uuid, tenantUuid);
    controller.dispose();
  });

  test('a stored session without the PIN of its operator is never resumed', () async {
    final store = provisioned();
    OperatorPin(store).clear();
    final controller = PosController(RefreshApi(), host: DeviceHost.over(store), pinIterations: 1000);
    await controller.restore();
    expect(controller.locked, isFalse);
    expect(controller.stage, PosStage.signIn);
    expect(SessionVault(store).refreshToken, isNull);
  });

  test('a grant revoked on the server reaches the device on the next change page', () async {
    final store = provisioned();
    final transport = _ChangesTransport({'items': [], 'cursor': 'c1', 'done': true, 'checksum': payloadHash([]), 'grant': null,
      'device': {'SdvUUID': 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE', 'PosTerminalPtmUUID': terminalUuid, 'SdvStatus': 'active'}});
    await SyncEngine(store, transport).sync();
    expect(store.meta('grant'), isNull);
    final controller = PosController(RefreshApi(), host: DeviceHost.over(store), pinIterations: 1000);
    await controller.restore();
    await controller.unlock('2468');
    await controller.openSession(Decimal.parse('10'));
    expect(controller.stage, PosStage.selling);
    await controller.scan('789');
    controller.addPayment(PaymentEntry(method: PaymentMethod.cash, amount: Decimal.parse('3')));
    expect(await controller.finish(), isNull);
    expect(controller.error, contains('no valid offline authorization'));
    controller.dispose();
  });

  group('background sync', () {
    test('renews the session under the lease, stores the new token and pushes the pending sale', () async {
      final store = provisioned();
      final runtimeController = PosController(RefreshApi(), host: DeviceHost.over(store), pinIterations: 1000);
      await runtimeController.restore();
      await runtimeController.unlock('2468');
      await runtimeController.openSession(Decimal.parse('10'));
      runtimeController.dispose();
      await pumpEventQueue(); // the app's own sync attempt (offline) ends and releases the lease
      SessionVault(store).markBackground();
      // The next background run comes after the retry time the offline attempt set.
      for (final e in store.dueOperations(DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch)) {
        store.markOperation(e.operationUuid, 'retry', retryAtMs: 0);
      }

      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/pos/auth/refresh')) {
          expect(jsonDecode(request.body), {'refreshToken': 'r1'});
          return http.Response(jsonEncode({'data': {'accessToken': 'a9', 'refreshToken': 'r9', 'expiresIn': 900,
            'session': {'userUUID': operatorUuid, 'email': 'op@example.invalid'}}}), 200);
        }
        expect(request.headers['authorization'], 'Bearer a9');
        expect(request.headers['x-device-signature'], isNotNull);
        if (request.url.path.endsWith('/pos/sync/push')) {
          final entries = (jsonDecode(request.body)['entries'] as List);
          return http.Response(jsonEncode({'data': {'results': [
            for (final e in entries) {'operationUUID': e['operation']['operationUUID'], 'status': 'ACCEPTED'},
          ]}}), 200);
        }
        return http.Response(jsonEncode({'data': {'items': [], 'cursor': 'c1', 'done': true, 'checksum': payloadHash([])}}), 200);
      });
      expect(await backgroundSyncOnce(store, key, httpClient: client), isNull);
      expect(calls.first, 'POST /api/v1/pos/auth/refresh');
      expect(calls, contains('POST /api/v1/pos/sync/push'));
      expect(SessionVault(store).refreshToken, 'r9');
      expect(store.outboxCounts()['pending'], isNull);
      expect(store.meta('sync.lease'), isNull, reason: 'released');
    });

    test('stays out while the app is in front or holds the lease', () async {
      final store = provisioned();
      store.setMeta('marker', 'x');
      final controller = PosController(RefreshApi(), host: DeviceHost.over(store), pinIterations: 1000);
      await controller.restore();
      await controller.unlock('2468');
      await controller.openSession(Decimal.parse('10'));
      controller.dispose();
      await pumpEventQueue();
      final never = MockClient((request) async => fail('no request: ${request.url}'));
      final vault = SessionVault(store);
      vault.markForeground();
      expect(await backgroundSyncOnce(store, key, httpClient: never), BackgroundSkip.appInForeground);
      vault.markBackground();
      expect(vault.acquire('app'), isTrue);
      expect(await backgroundSyncOnce(store, key, httpClient: never), BackgroundSkip.busy);
      vault.release('app');
      final empty = provisioned();
      expect(await backgroundSyncOnce(empty, key, httpClient: never), BackgroundSkip.nothingPending);
    });
  });
}

class _ChangesTransport implements SyncTransport {
  _ChangesTransport(this.page);
  final Map<String, dynamic> page;

  @override
  Future<Map<String, dynamic>> bootstrap(String? cursor) async => page;

  @override
  Future<Map<String, dynamic>> changes(String cursor) async => page;

  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> entries) async => {'results': []};
}
