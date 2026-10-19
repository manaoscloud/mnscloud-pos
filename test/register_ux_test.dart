import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/main.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/core/models.dart';
import 'package:mnscloud_pos/src/core/money.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';
import 'package:mnscloud_pos/src/ui/screens.dart';
import 'package:mnscloud_pos/src/ui/strings.dart';

Map<String, dynamic> sessionRow({String expected = '100.0000', String? counted}) => {
  'PcsUUID': '11111111-1111-1111-1111-111111111111',
  'PcsStatus': counted == null ? 'open' : 'closed',
  'PcsOpenedAt': '2026-10-18 12:00:00',
  'PcsOpeningAmount': '0.0000',
  'ExpectedCash': expected,
  'PcsCountedCash': counted,
  'SaleCount': 2,
  'SaleTotal': '12.4000',
  'PendingPayments': 0,
  'TotalsByMethod': {'cash': '8.9000', 'card_credit': '3.5000'},
  'SupplyTotal': '100.0000',
  'WithdrawalTotal': '0.0000',
  'CashSalesNet': '7.8000',
};

Map<String, dynamic> saleRow(String id, String state) => {
  'PsaUUID': '2222222$id-2222-2222-2222-222222222222',
  'PsaID': '0000000$id',
  'PsaTotal': '8.9000',
  'PsaCommercialState': state,
  'PsaPaymentState': state == 'canceled' ? 'reversed' : 'confirmed',
};

/// Fake API of an open register: refuses withdrawals above the drawer and records cancels.
class RegisterApi extends PosApi {
  RegisterApi() : super(ApiClient(baseUrl: 'http://invalid.local'));
  final canceled = <String>[];
  String? openedWith;

  @override
  Future<CashSession> session(String uuid) async => CashSession.fromJson(sessionRow());

  @override
  Future<CashSession> openSession(String terminalUuid, String openingAmount, String idempotencyKey) async {
    openedWith = openingAmount;
    return CashSession.fromJson(sessionRow());
  }

  @override
  Future<CashSession> cashMovement(String sessionUuid, String kind, String amount, String? notes, String key) async {
    if (kind == 'withdrawal') {
      throw ApiException(ApiFailureKind.rejected, 'Withdrawal exceeds the cash in the drawer', status: 400);
    }
    return CashSession.fromJson(sessionRow(expected: '200.0000'));
  }

  @override
  Future<List<PosSaleResult>> sessionSales(String sessionUuid) async => [
    PosSaleResult.fromJson(saleRow('2', 'confirmed')),
    PosSaleResult.fromJson(saleRow('1', 'confirmed')),
  ];

  @override
  Future<PosSaleResult> cancelSale(String uuid, String reason) async {
    canceled.add(uuid);
    return PosSaleResult.fromJson(saleRow('1', 'canceled'));
  }

  @override
  Future<CashSession> closeSession(String sessionUuid, String countedCash, String? notes) async =>
      CashSession.fromJson(sessionRow(expected: '107.8000', counted: countedCash));
}

PosTerminal terminal({bool pix = true}) => PosTerminal.fromJson({
  'PtmUUID': '33333333-3333-3333-3333-333333333333',
  'PtmName': 'CAIXA 1',
  'PtmPaymentMethods': 'cash,card_credit,pix',
  'PtmMaxDiscountPercent': '10',
  'PtmOfflineEnabled': 0,
  'PixAvailable': pix,
});

PosController selling(RegisterApi api, {PosStage stage = PosStage.selling, bool pix = true}) {
  final c = PosController(api);
  c.user = SignedInUser(uuid: 'u', name: 'Operador', email: 'op@example.com');
  c.tenant = TenantOption('env', 'Loja', null);
  c.terminal = terminal(pix: pix);
  if (stage == PosStage.selling) c.session = CashSession.fromJson(sessionRow());
  c.stage = stage;
  return c;
}

Future<void> phone(WidgetTester tester) async {
  tester.platformDispatcher.localesTestValue = [const Locale('pt', 'BR')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  tester.view.physicalSize = const Size(430, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  test('amounts accept pt-BR and plain formats and reject typos instead of becoming zero', () {
    expect(parseAmount('0,00100,00'), isNull);
    expect(parseAmount('abc'), isNull);
    expect(parseAmount(''), isNull);
    expect(parseAmount('1.234,56').toString(), '1234.5600');
    expect(parseAmount('100,00').toString(), '100.0000');
    expect(parseAmount('12.5').toString(), '12.5000');
  });

  test('server messages are shown in the operator language', () {
    expect(S('pt').message('Withdrawal exceeds the cash in the drawer'), 'A sangria é maior que o dinheiro no caixa.');
    expect(S('es').message('No item uses this code.'), 'Ningún artículo usa este código.');
    expect(
      S('pt').message('Signed out on this screen, but the server session could not be ended: offline'),
      'Você saiu nesta tela, mas não foi possível encerrar a sessão no servidor: offline',
    );
    expect(S('pt').message('Something new'), 'Something new');
    expect(S('en').message('Withdrawal exceeds the cash in the drawer'), 'Withdrawal exceeds the cash in the drawer');
  });

  test('terminal Pix availability and drawer breakdown are read from the API', () {
    expect(terminal(pix: false).pixAvailable, isFalse);
    expect(PosTerminal.fromJson({'PtmUUID': '33333333-3333-3333-3333-333333333333'}).pixAvailable, isTrue);
    final session = CashSession.fromJson(sessionRow());
    expect(session.supplyTotal.toString(), '100.0000');
    expect(session.cashSalesNet.toString(), '7.8000');
    expect(CashSession.fromJson({'PcsUUID': '11111111-1111-1111-1111-111111111111'}).supplyTotal, isNull);
  });

  testWidgets('an invalid opening amount is shown and nothing is opened', (tester) async {
    await phone(tester);
    final api = RegisterApi();
    final c = selling(api, stage: PosStage.openSession);
    await tester.pumpWidget(PosApp(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '0,00100,00');
    await tester.tap(find.widgetWithText(FilledButton, 'Abrir caixa'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Valor inválido'), findsOneWidget);
    expect(api.openedWith, isNull);
    await tester.enterText(find.byType(TextField).first, '1.234,56');
    await tester.tap(find.widgetWithText(FilledButton, 'Abrir caixa'));
    await tester.pumpAndSettle();
    expect(api.openedWith, '1234.5600');
  });

  testWidgets('Pix is hidden when the company has no payment gateway', (tester) async {
    await phone(tester);
    final c = selling(RegisterApi(), pix: false);
    c.addItem(CatalogItem(uuid: 'i', name: 'AGUA', price: money('3.5'), priceSource: 'product'));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('pt', 'BR'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('pt', 'BR')],
        home: Scaffold(body: PaymentDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pix'), findsNothing);
    expect(find.textContaining('Pix indisponível'), findsOneWidget);
  });

  testWidgets('register: breakdown, refused withdrawal keeps the amount, cancel any sale, closing summary', (
    tester,
  ) async {
    await phone(tester);
    final api = RegisterApi();
    final c = selling(api);
    await tester.pumpWidget(PosApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.point_of_sale));
    await tester.pumpAndSettle();

    expect(find.text('Suprimentos'), findsOneWidget);
    expect(find.text('Dinheiro das vendas (líquido de troco)'), findsOneWidget);
    expect(find.text('Venda nº 00000001 · 8,90'), findsOneWidget);

    final amount = find.widgetWithText(TextField, 'Valor');
    await tester.enterText(amount, '500,00');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sangria'));
    await tester.pumpAndSettle();
    expect(find.text('A sangria é maior que o dinheiro no caixa.'), findsWidgets);
    expect(find.text('500,00'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancelar venda').last);
    await tester.pumpAndSettle();
    expect(find.text('Informe o motivo do cancelamento.'), findsOneWidget);
    expect(api.canceled, isEmpty);
    await tester.enterText(find.widgetWithText(TextField, 'Motivo'), 'cliente desistiu');
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar venda').last);
    await tester.pumpAndSettle();
    expect(api.canceled, ['22222221-2222-2222-2222-222222222222']);

    await tester.enterText(amount, '100,00');
    await tester.tap(find.textContaining('Fechar caixa'));
    await tester.pumpAndSettle();
    expect(find.text('Caixa fechado'), findsOneWidget);
    expect(find.text('-7,80'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a discount above the limit says the maximum and leaves the line unchanged', (tester) async {
    await phone(tester);
    final c = selling(RegisterApi());
    final item = CatalogItem(uuid: 'r', name: 'REFRI', price: money('6'), priceSource: 'product');
    c.addItem(item);
    c.addItem(item);
    await tester.pumpWidget(PosApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();
    expect(find.text('Desconto máximo deste item: 1,20'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Desconto'), '2,00');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
    await tester.pumpAndSettle();
    expect(find.text('Desconto acima do limite do caixa. Desconto máximo deste item: 1,20'), findsOneWidget);
    expect(c.cart.single.discount.isZero, isTrue);
    await tester.enterText(find.widgetWithText(TextField, 'Desconto'), '1,00');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
    await tester.pumpAndSettle();
    expect(c.cart.single.discount.toString(), '1.0000');
  });

  testWidgets('without a camera scanner (desktop test host) the search keeps the reader icon only', (tester) async {
    await phone(tester);
    await tester.pumpWidget(PosApp(controller: selling(RegisterApi())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cameraScan')), findsNothing);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
  });
}
