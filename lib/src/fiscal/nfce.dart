import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// NFC-e 4.00 written directly in Canonical XML form, identical to the API engine
/// (helpers/fiscal/nfeXml.ts, brazil.ts, taxEngine.ts): the same snapshot gives the same XML.
/// Used by installed devices to sign NFC-e in offline contingency (tpEmis = 9).

const nfeNamespace = 'http://www.portalfiscal.inf.br/nfe';
const homologationItemText = 'NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL';

const stateCodes = <String, String>{
  'RO': '11', 'AC': '12', 'AM': '13', 'RR': '14', 'PA': '15', 'AP': '16', 'TO': '17', 'MA': '21',
  'PI': '22', 'CE': '23', 'RN': '24', 'PB': '25', 'PE': '26', 'AL': '27', 'SE': '28', 'BA': '29',
  'MG': '31', 'ES': '32', 'RJ': '33', 'SP': '35', 'PR': '41', 'SC': '42', 'RS': '43', 'MS': '50',
  'MT': '51', 'GO': '52', 'DF': '53', //
};

String stateUtcOffset(String state) {
  if (state == 'AC') return '-05:00';
  if (const ['AM', 'RO', 'RR', 'MT', 'MS'].contains(state)) return '-04:00';
  return '-03:00';
}

/// `YYYY-MM-DDThh:mm:ss±hh:mm` in the issuer state time zone.
String fiscalDateTime(DateTime at, String state) {
  final offset = stateUtcOffset(state);
  final sign = offset.startsWith('-') ? -1 : 1;
  final parts = offset.substring(1).split(':').map(int.parse).toList();
  final local = at.toUtc().add(Duration(minutes: sign * (parts[0] * 60 + parts[1])));
  final iso = local.toIso8601String();
  return '${iso.substring(0, 19)}$offset';
}

/// CPF/CNPJ with uppercase letters and digits only: the CNPJ is alphanumeric since 2026-07-01.
String normalizeTaxId(Object? value) => '${value ?? ''}'.toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');

String accessKeyCheckDigit(String key43) {
  var sum = 0;
  var weight = 2;
  // ASCII - 48: digits keep their value, letters of an alphanumeric CNPJ count too (NT 2025.001).
  for (var i = key43.length - 1; i >= 0; i--) {
    sum += (key43.codeUnitAt(i) - 48) * weight;
    weight = weight == 9 ? 2 : weight + 1;
  }
  final remainder = sum % 11;
  return remainder < 2 ? '0' : '${11 - remainder}';
}

String buildAccessKey({
  required String state,
  required DateTime issuedAt,
  required String cnpj,
  required String model,
  required int series,
  required int number,
  required int emissionType,
  required String code,
}) {
  final cUF = stateCodes[state];
  if (cUF == null) throw ArgumentError('Unknown issuer state: $state');
  final digits = normalizeTaxId(cnpj);
  if (!RegExp(r'^[0-9A-Z]{12}[0-9]{2}$').hasMatch(digits)) throw ArgumentError('Issuer CNPJ must have 14 characters');
  final local = fiscalDateTime(issuedAt, state);
  final yymm = '${local.substring(2, 4)}${local.substring(5, 7)}';
  final key43 = '$cUF$yymm$digits${model.padLeft(2, '0')}${'$series'.padLeft(3, '0')}${'$number'.padLeft(9, '0')}'
      '$emissionType$code';
  if (key43.length != 43) throw ArgumentError('Invalid access key parts');
  return key43 + accessKeyCheckDigit(key43);
}

/// cNF derived from the sale identity (stable for a resend), never equal to the number.
String numericCode(String uuid, int number) {
  final digest = sha256.convert(utf8.encode(uuid.toLowerCase())).bytes;
  var value = 0;
  for (var i = 0; i < 4; i++) {
    value = (value * 256 + digest[i]) % 100000000;
  }
  var code = '$value'.padLeft(8, '0');
  final numberTail = '$number'.padLeft(8, '0');
  if (code == numberTail.substring(numberTail.length - 8)) code = '${(value + 1) % 100000000}'.padLeft(8, '0');
  return code;
}

String paymentCode(String method) => switch (method) {
      'cash' => '01',
      'card_credit' => '03',
      'card_debit' => '04',
      'voucher' => '10',
      'pix' => '17',
      _ => '99',
    };

String regimeCode(String? regime) => switch (regime) {
      'simples_nacional' => '1',
      'simples_excess' => '2',
      'mei' => '4',
      _ => '3',
    };

// ---------- Money in integer cents

int cents(Object? value) {
  final text = (value ?? '0').toString().trim();
  if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(text)) throw FormatException('Invalid amount: $text');
  final negative = text.startsWith('-');
  final parts = text.replaceFirst('-', '').split('.');
  final fraction = '${parts.length > 1 ? parts[1] : ''}000'.substring(0, 3);
  var result = int.parse(parts[0]) * 100 + int.parse(fraction.substring(0, 2));
  if (int.parse(fraction[2]) >= 5) result += 1;
  return negative ? -result : result;
}

String money(int value) {
  final sign = value < 0 ? '-' : '';
  final abs = value.abs();
  return '$sign${abs ~/ 100}.${'${abs % 100}'.padLeft(2, '0')}';
}

int applyRate(int baseCents, Object? rate) {
  final r = double.tryParse('${rate ?? 0}') ?? 0;
  if (r == 0) return 0;
  return (baseCents * r / 100 + 1e-9).round();
}

// ---------- Rules (rows of the server rule package)

class RuleContext {
  RuleContext({
    required this.model,
    required this.operation,
    required this.originState,
    required this.destinationState,
    required this.taxRegime,
    required this.nature,
    required this.ncm,
    required this.recipientType,
  });
  final String model, operation, originState, destinationState, taxRegime, nature, recipientType;
  final String? ncm;
}

Map<String, dynamic>? selectRule(List<Map<String, dynamic>> rules, RuleContext ctx) {
  bool empty(Object? v) => v == null || '$v'.isEmpty || '$v' == 'NULL';
  bool match(Object? selector, String value) => empty(selector) || '$selector' == value;
  final matches = rules.where((r) {
    return '${r['FruStatus']}' == '1' &&
        match(r['FruModel'], ctx.model) &&
        '${r['FruOperation']}' == ctx.operation &&
        match(r['FruOriginState'], ctx.originState) &&
        match(r['FruDestinationState'], ctx.destinationState) &&
        match(r['FruTaxRegime'], ctx.taxRegime) &&
        match(r['FruNature'], ctx.nature) &&
        (empty(r['FruNcmPrefix']) || (ctx.ncm ?? '').startsWith('${r['FruNcmPrefix']}')) &&
        match(r['FruRecipientType'], ctx.recipientType);
  }).toList();
  double specificity(Map<String, dynamic> r) {
    final keys = ['FruModel', 'FruOriginState', 'FruDestinationState', 'FruTaxRegime', 'FruNature', 'FruNcmPrefix', 'FruRecipientType'];
    return keys.where((k) => !empty(r[k])).length + (empty(r['FruNcmPrefix']) ? 0 : '${r['FruNcmPrefix']}'.length / 100);
  }

  matches.sort((a, b) {
    final p = (num.tryParse('${a['FruPriority']}') ?? 100).compareTo(num.tryParse('${b['FruPriority']}') ?? 100);
    if (p != 0) return p;
    final s = specificity(b).compareTo(specificity(a));
    if (s != 0) return s;
    return '${a['FruUUID']}'.compareTo('${b['FruUUID']}');
  });
  return matches.isEmpty ? null : matches.first;
}

class TaxLine {
  TaxLine(this.rule, int net)
      : cfop = '${rule['FruCfop']}',
        icmsCst = '${rule['FruIcmsCst']}',
        icmsRate = double.tryParse('${rule['FruIcmsRate']}') ?? 0,
        fcpRate = double.tryParse('${rule['FruFcpRate']}') ?? 0,
        pisCst = '${rule['FruPisCst']}',
        pisRate = double.tryParse('${rule['FruPisRate']}') ?? 0,
        cofinsCst = '${rule['FruCofinsCst']}',
        cofinsRate = double.tryParse('${rule['FruCofinsRate']}') ?? 0,
        legalText = rule['FruLegalText'] == null || '${rule['FruLegalText']}' == 'NULL' ? null : '${rule['FruLegalText']}' {
    final reduction = double.tryParse('${rule['FruIcmsBaseReduction']}') ?? 0;
    final base = (net * (1 - reduction / 100)).round();
    final taxed = icmsRate > 0;
    icmsBase = taxed ? base : 0;
    icmsValue = taxed ? applyRate(base, icmsRate) : 0;
    fcpValue = taxed ? applyRate(base, fcpRate) : 0;
    pisBase = pisRate > 0 ? net : 0;
    pisValue = applyRate(pisBase, pisRate);
    cofinsBase = cofinsRate > 0 ? net : 0;
    cofinsValue = applyRate(cofinsBase, cofinsRate);
  }

  final Map<String, dynamic> rule;
  final String cfop, icmsCst, pisCst, cofinsCst;
  final double icmsRate, fcpRate, pisRate, cofinsRate;
  final String? legalText;
  late final int icmsBase, icmsValue, fcpValue, pisBase, pisValue, cofinsBase, cofinsValue;
}

// ---------- XML

String xmlText(Object? value) =>
    '${value ?? ''}'.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\r', '&#xD;');

String xmlAttr(Object? value) => '${value ?? ''}'
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('"', '&quot;')
    .replaceAll('\t', '&#x9;')
    .replaceAll('\n', '&#xA;')
    .replaceAll('\r', '&#xD;');

String tag(String name, Object? content, {bool raw = false}) {
  if (content == null || '$content'.isEmpty) return '';
  return '<$name>${raw ? content : xmlText(content)}</$name>';
}

String fiscalText(Object? value, int max) {
  final text = '${value ?? ''}'.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > max ? text.substring(0, max) : text;
}

String _digits(Object? value) => '${value ?? ''}'.replaceAll(RegExp(r'\D'), '');

String quantity4(Object? value) {
  final text = '${value ?? '0'}'.trim();
  final parts = text.split('.');
  return '${int.parse(parts[0])}.${'${parts.length > 1 ? parts[1] : ''}0000'.substring(0, 4)}';
}

String _icmsGroup(String origin, TaxLine tax) {
  final cst = tax.icmsCst;
  if (cst.length == 3) {
    if (const ['102', '103', '300', '400'].contains(cst)) return '<ICMSSN102>${tag('orig', origin)}${tag('CSOSN', cst)}</ICMSSN102>';
    if (cst == '500') return '<ICMSSN500>${tag('orig', origin)}${tag('CSOSN', cst)}</ICMSSN500>';
    throw ArgumentError('ICMS group not supported for CSOSN $cst');
  }
  if (cst == '00') {
    return '<ICMS00>${tag('orig', origin)}${tag('CST', cst)}${tag('modBC', '3')}${tag('vBC', money(tax.icmsBase))}'
        '${tag('pICMS', tax.icmsRate.toStringAsFixed(4))}${tag('vICMS', money(tax.icmsValue))}'
        '${tax.fcpRate > 0 ? '${tag('pFCP', tax.fcpRate.toStringAsFixed(4))}${tag('vFCP', money(tax.fcpValue))}' : ''}</ICMS00>';
  }
  if (const ['40', '41', '50'].contains(cst)) return '<ICMS40>${tag('orig', origin)}${tag('CST', cst)}</ICMS40>';
  if (cst == '60') return '<ICMS60>${tag('orig', origin)}${tag('CST', cst)}</ICMS60>';
  throw ArgumentError('ICMS group not supported for CST $cst');
}

String _contribution(String kind, String cst, int base, double rate, int value) {
  final rateTag = kind == 'PIS' ? 'pPIS' : 'pCOFINS';
  final valueTag = kind == 'PIS' ? 'vPIS' : 'vCOFINS';
  if (const ['01', '02'].contains(cst)) {
    return '<${kind}Aliq>${tag('CST', cst)}${tag('vBC', money(base))}${tag(rateTag, rate.toStringAsFixed(4))}${tag(valueTag, money(value))}</${kind}Aliq>';
  }
  if (const ['04', '05', '06', '07', '08', '09'].contains(cst)) return '<${kind}NT>${tag('CST', cst)}</${kind}NT>';
  return '<${kind}Outr>${tag('CST', cst)}${tag('vBC', money(base))}${tag(rateTag, rate.toStringAsFixed(4))}${tag(valueTag, money(value))}</${kind}Outr>';
}

class NfceItem {
  NfceItem({
    required this.description,
    required this.quantity,
    required this.unitPrice,
    required this.discount,
    required this.taxes,
    this.code,
    this.barcode,
    this.ncm,
    this.cest,
    this.origin,
    this.unit,
  });
  final String description;
  final String quantity, unitPrice, discount;
  final TaxLine taxes;
  final String? code, barcode, ncm, cest, origin, unit;
}

class NfceInput {
  NfceInput({
    required this.accessKey,
    required this.series,
    required this.number,
    required this.issuedAt,
    required this.production,
    required this.issuer,
    required this.items,
    required this.payments,
    required this.change,
    this.contingencyAt,
    this.contingencyReason,
    this.applicationVersion = 'mnscloud-pos',
  });
  final String accessKey;
  final int series, number;
  final DateTime issuedAt;
  final bool production;
  final Map<String, dynamic> issuer;
  final List<NfceItem> items;
  final List<({String method, String amount})> payments;
  final String change;
  final DateTime? contingencyAt;
  final String? contingencyReason;
  final String applicationVersion;
}

class BuiltNfce {
  BuiltNfce(this.id, this.infNFe, this.canonicalInfNFe, this.total);
  final String id, infNFe, canonicalInfNFe;
  final int total;
}

BuiltNfce buildInfNFe(NfceInput input) {
  final state = '${input.issuer['state']}';
  final cUF = stateCodes[state];
  if (cUF == null) throw ArgumentError('Unknown issuer state: $state');
  if (input.items.isEmpty) throw ArgumentError('A fiscal document needs items');
  final totals = _NfceTotals();
  final details = StringBuffer();
  for (var index = 0; index < input.items.length; index++) {
    details.write(_itemDetail(input, index, totals));
  }
  final total = totals.products - totals.discount;
  // Same order as the document: identification, issuer and totals before the payment check.
  final ide = _ideGroup(input, cUF, state);
  final emit = _emitGroup(input.issuer, state);
  final icmsTotal = _icmsTotalGroup(totals, total);
  final pag = _paymentGroup(input, total);
  final info = fiscalText({for (final i in input.items) if (i.taxes.legalText != null) i.taxes.legalText!}.join(' '), 5000);
  final inner = '<ide>$ide</ide><emit>$emit</emit>$details<total><ICMSTot>$icmsTotal</ICMSTot></total>'
      '<transp>${tag('modFrete', '9')}</transp>$pag${info.isEmpty ? '' : '<infAdic>${tag('infCpl', info)}</infAdic>'}';
  final id = 'NFe${input.accessKey}';
  return BuiltNfce(
    id,
    '<infNFe Id="${xmlAttr(id)}" versao="4.00">$inner</infNFe>',
    '<infNFe xmlns="$nfeNamespace" Id="${xmlAttr(id)}" versao="4.00">$inner</infNFe>',
    total,
  );
}

/// Running document totals, in cents.
class _NfceTotals {
  int products = 0, discount = 0, icms = 0, pis = 0, cofins = 0, icmsBase = 0, fcp = 0;
}

/// `<det>` of the item at [index]; adds its amounts to [totals].
String _itemDetail(NfceInput input, int index, _NfceTotals totals) {
  final item = input.items[index];
  final t = item.taxes;
  final gross = (double.parse(quantity4(item.quantity)) * cents(item.unitPrice)).round();
  final itemDiscount = cents(item.discount);
  totals
    ..products += gross
    ..discount += itemDiscount
    ..icms += t.icmsValue
    ..icmsBase += t.icmsBase
    ..fcp += t.fcpValue
    ..pis += t.pisValue
    ..cofins += t.cofinsValue;
  final origin = item.origin == null || item.origin!.isEmpty || item.origin == 'NULL' ? '0' : item.origin!;
  return '<det nItem="${index + 1}"><prod>${_productGroup(input, index, gross, itemDiscount)}</prod><imposto><ICMS>${_icmsGroup(origin, t)}</ICMS>'
      '<PIS>${_contribution('PIS', t.pisCst, t.pisBase, t.pisRate, t.pisValue)}</PIS>'
      '<COFINS>${_contribution('COFINS', t.cofinsCst, t.cofinsBase, t.cofinsRate, t.cofinsValue)}</COFINS></imposto></det>';
}

String _productGroup(NfceInput input, int index, int gross, int itemDiscount) {
  final item = input.items[index];
  final description = !input.production && index == 0 ? homologationItemText : fiscalText(item.description, 120);
  final gtin = RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(item.barcode ?? '') ? item.barcode! : 'SEM GTIN';
  final unit = fiscalText(item.unit == null || item.unit!.isEmpty ? 'UN' : item.unit, 6);
  final ncm = _digits(item.ncm);
  final cest = _digits(item.cest);
  return [
    tag('cProd', fiscalText(item.code ?? '${index + 1}', 60)),
    tag('cEAN', gtin),
    tag('xProd', description),
    tag('NCM', ncm.isEmpty ? '00000000' : ncm),
    tag('CEST', cest.isEmpty ? null : cest),
    tag('CFOP', item.taxes.cfop),
    tag('uCom', unit),
    tag('qCom', quantity4(item.quantity)),
    tag('vUnCom', money(cents(item.unitPrice))),
    tag('vProd', money(gross)),
    tag('cEANTrib', gtin),
    tag('uTrib', unit),
    tag('qTrib', quantity4(item.quantity)),
    tag('vUnTrib', money(cents(item.unitPrice))),
    itemDiscount > 0 ? tag('vDesc', money(itemDiscount)) : '',
    tag('indTot', '1'),
  ].join();
}

String _ideGroup(NfceInput input, String cUF, String state) {
  final contingency = input.contingencyAt != null;
  return [
    tag('cUF', cUF),
    tag('cNF', input.accessKey.substring(35, 43)),
    tag('natOp', 'VENDA'),
    tag('mod', '65'),
    tag('serie', '${input.series}'),
    tag('nNF', '${input.number}'),
    tag('dhEmi', fiscalDateTime(input.issuedAt, state)),
    tag('tpNF', '1'),
    tag('idDest', '1'),
    tag('cMunFG', _digits(input.issuer['municipalityCode'])),
    tag('tpImp', '4'),
    tag('tpEmis', contingency ? '9' : '1'),
    tag('cDV', input.accessKey.substring(43)),
    tag('tpAmb', input.production ? '1' : '2'),
    tag('finNFe', '1'),
    tag('indFinal', '1'),
    tag('indPres', '1'),
    tag('procEmi', '0'),
    tag('verProc', fiscalText(input.applicationVersion, 20)),
    if (contingency) tag('dhCont', fiscalDateTime(input.contingencyAt!, state)),
    if (contingency) tag('xJust', fiscalText(input.contingencyReason ?? 'SEM CONEXAO COM A SEFAZ', 256)),
  ].join();
}

/// Optional tag: omitted when the normalized value is empty.
String _optionalTag(String name, String value) => tag(name, value.isEmpty ? null : value);

String _emitGroup(Map<String, dynamic> issuer, String state) {
  final stateRegistration = _digits(issuer['stateRegistration']);
  final address = [
    tag('xLgr', fiscalText(issuer['street'], 60)),
    tag('nro', fiscalText(issuer['number'] ?? 'S/N', 60)),
    _optionalTag('xCpl', fiscalText(issuer['complement'], 60)),
    tag('xBairro', fiscalText(issuer['district'], 60)),
    tag('cMun', _digits(issuer['municipalityCode'])),
    tag('xMun', fiscalText(issuer['city'], 60)),
    tag('UF', state),
    tag('CEP', _digits(issuer['zip'])),
    tag('cPais', '1058'),
    tag('xPais', 'BRASIL'),
    _optionalTag('fone', _digits(issuer['phone'])),
  ].join();
  return [
    tag('CNPJ', normalizeTaxId(issuer['document'])),
    tag('xNome', fiscalText(issuer['legalName'] ?? issuer['name'], 60)),
    _optionalTag('xFant', fiscalText(issuer['name'], 60)),
    '<enderEmit>$address</enderEmit>',
    tag('IE', stateRegistration.isEmpty ? 'ISENTO' : stateRegistration),
    tag('CRT', regimeCode(issuer['taxRegime'] as String?)),
  ].join();
}

String _icmsTotalGroup(_NfceTotals t, int total) => [
      tag('vBC', money(t.icmsBase)), tag('vICMS', money(t.icms)), tag('vICMSDeson', '0.00'), tag('vFCP', money(t.fcp)),
      tag('vBCST', '0.00'), tag('vST', '0.00'), tag('vFCPST', '0.00'), tag('vFCPSTRet', '0.00'), tag('vProd', money(t.products)),
      tag('vFrete', '0.00'), tag('vSeg', '0.00'), tag('vDesc', money(t.discount)), tag('vII', '0.00'), tag('vIPI', '0.00'),
      tag('vIPIDevol', '0.00'), tag('vPIS', money(t.pis)), tag('vCOFINS', money(t.cofins)), tag('vOutro', '0.00'),
      tag('vNF', money(total)),
    ].join();

/// `<pag>`: payments minus change must equal the document total.
String _paymentGroup(NfceInput input, int total) {
  final paid = input.payments.fold<int>(0, (sum, p) => sum + cents(p.amount));
  final change = cents(input.change);
  if (paid - change != total) throw ArgumentError('Payments minus change must equal the document total');
  final pays = input.payments.map((p) {
    final code = paymentCode(p.method);
    final card = const ['03', '04', '17'].contains(code) ? '<card>${tag('tpIntegra', '2')}</card>' : '';
    final description = code == '99' ? tag('xPag', 'OUTROS') : '';
    return '<detPag>${tag('tPag', code)}$description${tag('vPag', money(cents(p.amount)))}$card</detPag>';
  }).join();
  return '<pag>$pays${change > 0 ? tag('vTroco', money(change)) : ''}</pag>';
}

String assembleNfe(String infNFe, String signature, String supplement) =>
    '<NFe xmlns="$nfeNamespace">$infNFe$supplement$signature</NFe>';

String nfceSupplement(String qrCode, String consultationUrl) =>
    '<infNFeSupl><qrCode><![CDATA[$qrCode]]></qrCode>${tag('urlChave', consultationUrl)}</infNFeSupl>';

/// Offline (contingency) QR Code v2: `p=<chave>|2|<tpAmb>|<dia>|<vNF>|<digVal hex>|<cIdToken>|<hash>`.
String nfceQrCodeOffline({
  required String baseUrl,
  required String accessKey,
  required bool production,
  required DateTime issuedAt,
  required String state,
  required int total,
  required String digestValueBase64,
  required String cscId,
  required String csc,
}) {
  final day = fiscalDateTime(issuedAt, state).substring(8, 10);
  final digest = base64Decode(digestValueBase64).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final token = '${int.parse(cscId)}';
  final payload = '$accessKey|2|${production ? '1' : '2'}|$day|${money(total)}|$digest|$token';
  final hash = sha1.convert(utf8.encode('$payload$csc')).toString().toUpperCase();
  return '$baseUrl?p=$payload|$hash';
}

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));
