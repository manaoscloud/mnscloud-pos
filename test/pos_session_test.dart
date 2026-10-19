import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

const tenantA = '0a0a0a0a-0000-4000-8000-00000000000a';
const tenantB = '0b0b0b0b-0000-4000-8000-00000000000b';
const terminal1 = '11111111-0000-4000-8000-000000000001';
const terminal2 = '22222222-0000-4000-8000-000000000002';

Map<String, dynamic> grant(String access, {String? refresh, String? environment, String? terminal}) => {
      'data': {
        'accessToken': access,
        'tokenType': 'Bearer',
        'expiresIn': 600,
        'refreshToken': refresh,
        'session': {
          'sessionUUID': 'session-1',
          'userUUID': 'user-1',
          'email': 'operador@example.invalid',
          'name': 'Operador',
          'idleExpiresIn': 43200,
          'expiresIn': 604800,
        },
        'environmentUUID': environment,
        'terminalUUID': terminal,
      },
    };

Map<String, dynamic> terminalRow(String uuid, String name) => {
      'PtmUUID': uuid,
      'PtmName': name,
      'CompanyName': 'Loja',
      'StockLocationName': 'Deposito',
      'PtmPaymentMethods': 'cash',
      'PtmMaxDiscountPercent': '0',
      'PtmOfflineEnabled': 0,
    };

/// Fake MNSCloud API: POS session routes, identity reads and terminals. Records every request.
class FakeApi {
  final requests = <http.Request>[];
  String validToken = 'access-1';
  int refreshes = 0;
  bool refreshAllowed = true;
  bool expireNextRead = false;
  int signOuts = 0;

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path.replaceFirst('/api/v1/', '');
    final body = request.body.isEmpty ? const {} : jsonDecode(request.body) as Map;
    switch (path) {
      case 'pos/auth/signin':
        if (body['password'] != 'secret') {
          return json({'error': 'Invalid email or password.', 'code': 'POS_INVALID_CREDENTIALS'}, 401);
        }
        validToken = 'access-1';
        return json(grant('access-1', refresh: 'refresh-1'));
      case 'pos/auth/refresh':
        refreshes++;
        if (!refreshAllowed) return json({'error': 'POS session is no longer valid.', 'code': 'POS_SESSION_INVALID'}, 401);
        validToken = 'access-${refreshes + 1}';
        return json(grant(validToken, refresh: 'refresh-${refreshes + 1}'));
      case 'pos/auth/exchange':
        if (body['code'] != 'app-code') {
          return json({'error': 'The sign-in link expired or was used.', 'code': 'POS_HANDOFF_INVALID'}, 401);
        }
        validToken = 'access-1';
        return json(grant('access-1', refresh: 'refresh-1', environment: tenantB.replaceAll('-', ''), terminal: terminal2));
      case 'pos/auth/signout':
        signOuts++;
        return json({'status': 'success', 'data': null});
    }
    if (request.headers['Authorization'] != 'Bearer $validToken' || expireNextRead) {
      expireNextRead = false;
      return json({'error': 'Invalid or expired token.', 'code': 'POS_SESSION_INVALID'}, 401);
    }
    if (path == 'user/access') {
      return json({
        'data': {
          'access': [
            {'EnvironmentUUID': tenantA, 'EnvironmentName': 'Loja A'},
            {'EnvironmentUUID': tenantB, 'EnvironmentName': 'Loja B'},
          ],
        },
      });
    }
    if (path == 'pos/terminals') {
      return json({
        'data': {
          'items': [terminalRow(terminal1, 'Caixa 1'), terminalRow(terminal2, 'Caixa 2')],
        },
      });
    }
    if (path == 'pos/terminals/$terminal2') return json({'data': terminalRow(terminal2, 'Caixa 2')});
    if (path == 'pos/sync/push') return json({'data': {'ok': true}});
    return json({'error': 'not found'}, 404);
  }
}

(FakeApi, PosController) controller() {
  final fake = FakeApi();
  final client = ApiClient(baseUrl: 'http://pos.test/api/v1', client: MockClient(fake.handle));
  return (fake, PosController(PosApi(client)));
}

void main() {
  test('signs in with its own POS session and never sends the App cookie or CSRF token', () async {
    final (fake, c) = controller();
    await c.signIn('operador@example.invalid', 'secret');
    expect(c.user?.email, 'operador@example.invalid');
    expect(c.stage, PosStage.tenant);
    final signIn = fake.requests.first;
    expect(signIn.url.path, '/api/v1/pos/auth/signin');
    expect(jsonDecode(signIn.body), {'email': 'operador@example.invalid', 'password': 'secret', 'clientKind': 'native'});
    final access = fake.requests.last;
    expect(access.url.path, '/api/v1/user/access');
    expect(access.headers['Authorization'], 'Bearer access-1');
    expect(access.headers.containsKey('X-CSRF-Token'), isFalse);
    // Installed apps keep the refresh token in memory only.
    expect(c.api.client.refreshToken, 'refresh-1');
  });

  test('a wrong password shows the error and keeps the sign-in card', () async {
    final (_, c) = controller();
    await c.signIn('operador@example.invalid', 'wrong');
    expect(c.user, isNull);
    expect(c.stage, PosStage.signIn);
    expect(c.error, 'Invalid email or password.');
  });

  test('an expired access token is renewed once and the request repeated', () async {
    final (fake, c) = controller();
    await c.signIn('operador@example.invalid', 'secret');
    fake.expireNextRead = true;
    final list = await c.api.terminals();
    expect(list.map((t) => t.name), ['Caixa 1', 'Caixa 2']);
    expect(fake.refreshes, 1);
    final refresh = fake.requests.firstWhere((r) => r.url.path.endsWith('pos/auth/refresh'));
    expect(jsonDecode(refresh.body), {'refreshToken': 'refresh-1'});
    expect(c.api.client.bearerToken, 'access-2');
    expect(c.api.client.refreshToken, 'refresh-2');
  });

  test('device-signed requests are never repeated (their counter must not be reused)', () async {
    final (fake, c) = controller();
    await c.signIn('operador@example.invalid', 'secret');
    fake.expireNextRead = true;
    await expectLater(
      c.api.client.signed('POST', 'pos/sync/push', body: const {'operations': []}, headers: (_, _) => const {}),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
    expect(fake.requests.where((r) => r.url.path.endsWith('pos/sync/push')).length, 1);
    expect(fake.refreshes, 0);
  });

  test('an ended POS session returns to the sign-in card with a message', () async {
    final (fake, c) = controller();
    await c.signIn('operador@example.invalid', 'secret');
    fake.refreshAllowed = false;
    fake.expireNextRead = true;
    await expectLater(c.api.terminals(), throwsA(isA<ApiException>()));
    expect(c.stage, PosStage.signIn);
    expect(c.user, isNull);
    expect(c.api.client.bearerToken, isNull);
    expect(c.api.client.refreshToken, isNull);
    expect(c.error, contains('POS session ended'));
  });

  test('sign out ends only the POS session and forgets its tokens', () async {
    final (fake, c) = controller();
    await c.signIn('operador@example.invalid', 'secret');
    expect(await c.signOut(), isTrue);
    expect(fake.signOuts, 1);
    expect(fake.requests.last.url.path, '/api/v1/pos/auth/signout');
    expect(fake.requests.last.headers['Authorization'], 'Bearer access-1');
    expect(c.api.client.bearerToken, isNull);
    expect(c.api.client.refreshToken, isNull);
    expect(c.stage, PosStage.signIn);
  });

  test('installed apps start on the sign-in card without calling the API', () async {
    final (fake, c) = controller();
    await c.restore();
    expect(c.stage, PosStage.signIn);
    expect(c.error, isNull);
    expect(fake.requests, isEmpty);
  });

  test('a session opened from the App goes straight to its tenant and register', () async {
    final (fake, c) = controller();
    await c.openFromApp('app-code');
    expect(fake.requests.first.url.path, '/api/v1/pos/auth/exchange');
    expect(c.tenant?.uuid, tenantB);
    expect(c.api.client.environmentUuid, tenantB);
    expect(c.terminal?.uuid, terminal2);
    expect(c.stage, PosStage.openSession);
  });

  test('a used or expired App code shows the sign-in card', () async {
    final (_, c) = controller();
    await c.openFromApp('old-code');
    expect(c.stage, PosStage.signIn);
    expect(c.user, isNull);
    expect(c.error, 'The sign-in link expired or was used.');
  });
}
