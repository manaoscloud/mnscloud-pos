import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/main.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

/// Fake API: counts sign-out calls and can fail them.
class SignOutApi extends PosApi {
  SignOutApi({this.failure}) : super(ApiClient(baseUrl: 'http://invalid.local'));
  final ApiException? failure;
  int signOuts = 0;

  @override
  Future<void> signOut() async {
    signOuts++;
    if (failure != null) throw failure!;
  }
}

PosController signedIn(SignOutApi api) {
  final c = PosController(api);
  c.user = SignedInUser(uuid: 'u', name: 'Operador', email: 'op@example.com');
  c.tenant = TenantOption('env', 'Loja', null);
  c.tenants = [c.tenant!];
  c.stage = PosStage.terminal;
  api.client.bearerToken = 'token';
  api.client.refreshToken = 'refresh';
  api.client.environmentUuid = 'env';
  return c;
}

void main() {
  test('sign out ends the POS session and drops everything kept in memory', () async {
    final api = SignOutApi();
    final c = signedIn(api);
    expect(await c.signOut(), isTrue);
    expect(api.signOuts, 1);
    expect(c.stage, PosStage.signIn);
    expect(c.user, isNull);
    expect(c.tenant, isNull);
    expect(c.tenants, isEmpty);
    expect(c.terminal, isNull);
    expect(c.session, isNull);
    expect(c.cart, isEmpty);
    expect(api.client.bearerToken, isNull);
    expect(api.client.refreshToken, isNull);
    expect(api.client.environmentUuid, isNull);
    expect(c.error, isNull);
  });

  test('sign out is refused while a sale submit is in doubt', () async {
    final api = SignOutApi();
    final c = signedIn(api);
    c.pendingSale = {'saleUUID': 'pending'};
    expect(await c.signOut(), isFalse);
    expect(api.signOuts, 0);
    expect(c.user, isNotNull);
    expect(c.pendingSale, isNotNull);
  });

  test('an expired session counts as signed out', () async {
    final api = SignOutApi(failure: ApiException(ApiFailureKind.unauthorized, 'expired', status: 401));
    final c = signedIn(api);
    expect(await c.signOut(), isTrue);
    expect(c.stage, PosStage.signIn);
    expect(c.error, isNull);
  });

  test('an unreachable server still clears the screen and says the server session may remain', () async {
    final api = SignOutApi(failure: ApiException(ApiFailureKind.unreachable, 'offline'));
    final c = signedIn(api);
    expect(await c.signOut(), isTrue);
    expect(c.stage, PosStage.signIn);
    expect(c.user, isNull);
    expect(c.error, contains('server session could not be ended'));
  });

  testWidgets('the sign-out button asks first and returns to the sign-in card', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('pt', 'BR')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = SignOutApi();
    final c = signedIn(api);
    await tester.pumpWidget(PosApp(controller: c));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('signOut')));
    await tester.pumpAndSettle();
    expect(find.text('Sair do PDV?'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(api.signOuts, 0);
    expect(c.stage, PosStage.terminal);

    await tester.tap(find.byKey(const Key('signOut')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmSignOut')));
    await tester.pumpAndSettle();
    expect(api.signOuts, 1);
    expect(c.stage, PosStage.signIn);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Entrar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
