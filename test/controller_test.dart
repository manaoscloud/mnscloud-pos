import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/core/models.dart';
import 'package:mnscloud_pos/src/core/money.dart';
import 'package:mnscloud_pos/src/state/pos_controller.dart';

/// Fake API: the first submit is stored but its answer is lost (timeout); the check by UUID then
/// finds it. Counts how many distinct sales reached the "server".
class LostAnswerApi extends PosApi {
  LostAnswerApi() : super(ApiClient(baseUrl: 'http://invalid.local'));
  final Map<String, Map<String, dynamic>> stored = {};
  int submits = 0;
  bool loseNextAnswer = true;
  bool serverDown = false;

  Map<String, dynamic> _row(String uuid) => {
        'PsaUUID': uuid,
        'PsaID': '00000001',
        'PsaTotal': '25.0000',
        'PsaChange': '5.0000',
        'PsaCommercialState': 'confirmed',
        'PsaPaymentState': 'confirmed',
        'PaymentsJson': [],
      };

  @override
  Future<SubmitOutcome> submitSale(Map<String, dynamic> payload) async {
    submits++;
    if (serverDown) return SubmitOutcome.unknown();
    final uuid = payload['saleUUID'] as String;
    stored.putIfAbsent(uuid, () => payload);
    if (loseNextAnswer) {
      loseNextAnswer = false;
      return SubmitOutcome.unknown();
    }
    return SubmitOutcome.saved(PosSaleResult.fromJson(_row(uuid)));
  }

  @override
  Future<PosSaleResult?> sale(String uuid) async => stored.containsKey(uuid) ? PosSaleResult.fromJson(_row(uuid)) : null;

  @override
  Future<CashSession> session(String uuid) async => CashSession.fromJson({
        'PcsUUID': uuid,
        'PcsStatus': 'open',
        'PcsOpenedAt': '2026-10-17 10:00:00',
        'PcsOpeningAmount': '0',
        'ExpectedCash': '0',
        'SaleCount': stored.length,
        'SaleTotal': '0',
        'PendingPayments': 0,
      });
}

PosController _ready(LostAnswerApi api) {
  final c = PosController(api);
  c.terminal = PosTerminal.fromJson({
    'PtmUUID': '11111111111141118111111111111111',
    'PtmName': 'CAIXA 1',
    'CompanyName': 'LOJA',
    'StockLocationName': 'LOJA',
    'Currency': 'BRL',
    'PtmPaymentMethods': 'cash,pix',
    'PtmMaxDiscountPercent': '10',
    'PtmOfflineEnabled': '0',
  });
  c.session = CashSession.fromJson({'PcsUUID': '22222222222242228222222222222222', 'PcsStatus': 'open', 'PcsOpenedAt': '2026-10-17 10:00:00'});
  c.stage = PosStage.selling;
  c.addItem(CatalogItem(uuid: '33333333-3333-4333-8333-333333333333', name: 'ITEM', price: money('12.50'), priceSource: 'base'),
      quantity('2'));
  c.addPayment(PaymentEntry(method: PaymentMethod.cash, amount: money('30')));
  return c;
}

void main() {
  test('a lost answer never becomes a second sale and success is shown only when stored', () async {
    final api = LostAnswerApi();
    final c = _ready(api);
    expect(c.change.toString(), '5.0000');
    expect(await c.finish(), isNull);
    expect(c.saleInDoubt, isTrue);
    final firstUuid = c.pendingSale!['saleUUID'];
    // Editing the cart is blocked while the outcome is unknown.
    c.addItem(CatalogItem(uuid: 'x', name: 'X', price: money('1'), priceSource: 'base'));
    expect(c.cart.length, 1);
    final sale = await c.finish();
    expect(sale, isNotNull);
    expect(api.submits, 2);
    expect(api.stored.length, 1);
    expect(api.stored.keys.single, firstUuid);
    expect(c.cart, isEmpty);
  });

  test('server down keeps the cart and the same sale identity', () async {
    final api = LostAnswerApi()..serverDown = true;
    final c = _ready(api);
    expect(await c.finish(), isNull);
    final uuid = c.pendingSale!['saleUUID'];
    expect(await c.finish(), isNull);
    expect(c.pendingSale!['saleUUID'], uuid);
    expect(c.cart, isNotEmpty);
    expect(api.stored, isEmpty);
  });

  test('discount above the terminal limit is refused locally', () {
    final c = _ready(LostAnswerApi());
    expect(c.setDiscount(c.cart.first, money('3')), isNotNull);
    expect(c.setDiscount(c.cart.first, money('2.50')), isNull);
  });
}
