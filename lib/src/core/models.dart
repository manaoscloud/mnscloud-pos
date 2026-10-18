import 'ids.dart';
import 'money.dart';

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty || text == 'NULL' ? null : text;
}

/// POS terminal (cash register) as configured by the tenant management.
class PosTerminal {
  PosTerminal({
    required this.uuid,
    required this.name,
    required this.companyName,
    required this.locationName,
    required this.currency,
    required this.paymentMethods,
    required this.maxDiscountPercent,
    required this.offlineEnabled,
    this.priceListUuid,
    this.openSessionUuid,
  });

  factory PosTerminal.fromJson(Map<String, dynamic> json) => PosTerminal(
        uuid: normalizeUuid(json['PtmUUID'].toString()),
        name: json['PtmName']?.toString() ?? '',
        companyName: json['CompanyName']?.toString() ?? '',
        locationName: json['StockLocationName']?.toString() ?? '',
        currency: _text(json['Currency']) ?? 'BRL',
        paymentMethods: (json['PtmPaymentMethods']?.toString() ?? 'cash')
            .split(',')
            .map((m) => m.trim())
            .where((m) => m.isNotEmpty)
            .toList(),
        maxDiscountPercent: money(json['PtmMaxDiscountPercent']),
        offlineEnabled: json['PtmOfflineEnabled'].toString() == '1',
        priceListUuid: _text(json['SalePriceListSplUUID']),
        openSessionUuid: _text(json['OpenSessionUUID']) == null
            ? null
            : normalizeUuid(json['OpenSessionUUID'].toString()),
      );

  final String uuid;
  final String name;
  final String companyName;
  final String locationName;
  final String currency;
  final List<String> paymentMethods;
  final Decimal maxDiscountPercent;
  final bool offlineEnabled;
  final String? priceListUuid;
  final String? openSessionUuid;
}

/// Operational cash session of a terminal.
class CashSession {
  CashSession({
    required this.uuid,
    required this.status,
    required this.openedAt,
    required this.openingAmount,
    required this.expectedCash,
    required this.saleCount,
    required this.saleTotal,
    required this.pendingPayments,
    required this.totalsByMethod,
    this.countedCash,
    this.operatorName,
  });

  factory CashSession.fromJson(Map<String, dynamic> json) {
    final totals = <String, Decimal>{};
    final raw = json['TotalsByMethod'];
    if (raw is Map) {
      raw.forEach((key, value) => totals[key.toString()] = money(value));
    }
    return CashSession(
      uuid: normalizeUuid(json['PcsUUID'].toString()),
      status: json['PcsStatus']?.toString() ?? 'open',
      openedAt: DateTime.tryParse(json['PcsOpenedAt']?.toString() ?? '') ?? DateTime.now(),
      openingAmount: money(json['PcsOpeningAmount']),
      expectedCash: money(json['ExpectedCash']),
      countedCash: _text(json['PcsCountedCash']) == null ? null : money(json['PcsCountedCash']),
      saleCount: int.tryParse(json['SaleCount']?.toString() ?? '') ?? 0,
      saleTotal: money(json['SaleTotal']),
      pendingPayments: int.tryParse(json['PendingPayments']?.toString() ?? '') ?? 0,
      totalsByMethod: totals,
      operatorName: _text(json['OperatorName']),
    );
  }

  final String uuid;
  final String status;
  final DateTime openedAt;
  final Decimal openingAmount;
  final Decimal expectedCash;
  final Decimal? countedCash;
  final int saleCount;
  final Decimal saleTotal;
  final int pendingPayments;
  final Map<String, Decimal> totalsByMethod;
  final String? operatorName;

  bool get isOpen => status == 'open';
}

/// Catalog item with the price resolved for the terminal at the moment it was read.
class CatalogItem {
  CatalogItem({
    required this.uuid,
    required this.name,
    required this.price,
    required this.priceSource,
    this.code,
    this.barcode,
    this.nature,
    this.available,
    this.fiscal,
  });

  final String uuid;
  final String name;
  final Decimal price;
  final String priceSource;
  final String? code;
  final String? barcode;
  final String? nature;
  final Decimal? available;

  /// Offline catalog only: ncm, cest, origin and unit for NFC-e issued on the device.
  final Map<String, dynamic>? fiscal;

  factory CatalogItem.fromJson(Map<String, dynamic> json) => CatalogItem(
        uuid: normalizeUuid(json['SaleProductSprUUID'].toString()),
        name: json['SaleProductName']?.toString() ?? '',
        code: _text(json['SaleProductID']),
        barcode: _text(json['SprBarcode']),
        price: money(json['Price']),
        priceSource: json['PriceSource']?.toString() ?? 'base',
        nature: _text(json['FicNature']),
        available: _text(json['Available']) == null ? null : quantity(json['Available']),
      );
}

class CartLine {
  CartLine({required this.item, required this.quantity, Decimal? discount})
      : discount = discount ?? Decimal.zero();

  final CatalogItem item;
  Decimal quantity;
  Decimal discount;

  Decimal get gross => item.price * quantity;
  Decimal get total => gross - discount;
}

enum PaymentMethod { cash, pix, cardCredit, cardDebit, voucher, other }

extension PaymentMethodCode on PaymentMethod {
  String get code => switch (this) {
        PaymentMethod.cash => 'cash',
        PaymentMethod.pix => 'pix',
        PaymentMethod.cardCredit => 'card_credit',
        PaymentMethod.cardDebit => 'card_debit',
        PaymentMethod.voucher => 'voucher',
        PaymentMethod.other => 'other',
      };

  static PaymentMethod fromCode(String code) =>
      PaymentMethod.values.firstWhere((m) => m.code == code, orElse: () => PaymentMethod.other);
}

/// Payment as entered at the POS. States follow the server: cash is confirmed by the operator,
/// cards are authorized only with the terminal NSU, Pix is confirmed only by the gateway.
class PaymentEntry {
  PaymentEntry({
    required this.method,
    required this.amount,
    String? uuid,
    this.providerReference,
    this.authorizationCode,
    this.cardBrand,
    this.cardLast4,
  }) : uuid = uuid ?? uuidV4();

  final String uuid;
  final PaymentMethod method;
  final Decimal amount;
  final String? providerReference;
  final String? authorizationCode;
  final String? cardBrand;
  final String? cardLast4;

  String get declaredState => switch (method) {
        PaymentMethod.cash => 'confirmed',
        PaymentMethod.pix => 'pending',
        PaymentMethod.cardCredit || PaymentMethod.cardDebit =>
          providerReference == null ? 'unknown' : 'authorized',
        _ => 'informed',
      };

  Map<String, dynamic> toJson() => {
        'paymentUUID': uuid,
        'method': method.code,
        'amount': amount.toString(),
        'state': declaredState,
        if (providerReference != null) 'providerReference': providerReference,
        if (authorizationCode != null) 'authorizationCode': authorizationCode,
        if (cardBrand != null) 'cardBrand': cardBrand,
        if (cardLast4 != null) 'cardLast4': cardLast4,
      };
}

/// Sale as accepted by the server.
class PosSaleResult {
  PosSaleResult({
    required this.uuid,
    required this.number,
    required this.total,
    required this.change,
    required this.commercialState,
    required this.paymentState,
    required this.fiscalState,
    required this.syncState,
    required this.payments,
    this.conflictNotes,
  });

  factory PosSaleResult.fromJson(Map<String, dynamic> json) {
    final payments = <Map<String, dynamic>>[];
    final raw = json['PaymentsJson'];
    if (raw is List) {
      for (final p in raw) {
        if (p is Map) payments.add(p.cast<String, dynamic>());
      }
    }
    return PosSaleResult(
      uuid: normalizeUuid(json['PsaUUID'].toString()),
      number: json['PsaID']?.toString() ?? '',
      total: money(json['PsaTotal']),
      change: money(json['PsaChange']),
      commercialState: json['PsaCommercialState']?.toString() ?? '',
      paymentState: json['PsaPaymentState']?.toString() ?? '',
      fiscalState: json['PsaFiscalState']?.toString() ?? 'none',
      syncState: json['PsaSyncState']?.toString() ?? 'accepted',
      conflictNotes: _text(json['PsaConflictNotes']),
      payments: payments,
    );
  }

  final String uuid;
  final String number;
  final Decimal total;
  final Decimal change;
  final String commercialState;
  final String paymentState;
  final String fiscalState;
  final String syncState;
  final String? conflictNotes;
  final List<Map<String, dynamic>> payments;
}
