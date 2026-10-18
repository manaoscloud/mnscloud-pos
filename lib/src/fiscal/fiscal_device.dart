import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/canonical_json.dart';
import '../core/ids.dart';
import '../core/models.dart';
import '../offline/store.dart';
import '../offline/sync_engine.dart';
import 'nfce.dart';
import 'xml_signature.dart';

/// OS secure storage of the device (A1 key and CSC).
abstract class FiscalSecrets {
  Future<String?> readSecret(String name);
  Future<void> writeSecret(String name, String? value);
}

/// Signed fiscal endpoints of the device (`/pos/sync/fiscal`).
abstract class FiscalTransport {
  Future<Map<String, dynamic>> fiscalConfig({bool credentials = false});
  Future<Map<String, dynamic>> allocateRange(String environment);
}

/// NFC-e in offline contingency on an installed device (decision D4): only for terminals the
/// manager enabled, with the device number range and the A1 key and CSC kept in the OS secure
/// storage. The signed NFC-e goes to the server as the sync operation `pos.fiscal.offline`.
class FiscalDevice {
  FiscalDevice(this.store, this.host, this.transport);

  final OfflineStore store;
  final FiscalSecrets host;
  final FiscalTransport transport;

  Map<String, dynamic>? get config {
    final raw = store.meta('fiscal_config');
    return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  bool get enabled => config?['enabled'] == true;

  /// Refreshes the configuration; credentials are requested only when missing (each release is
  /// audited on the server). A disabled terminal wipes the local credentials.
  Future<void> refresh() async {
    final hasCredentials = await host.readSecret('fiscal_key') != null;
    final data = await transport.fiscalConfig(credentials: !hasCredentials);
    if (data['enabled'] != true) {
      store.setMeta('fiscal_config', jsonEncode({'enabled': false}));
      await host.writeSecret('fiscal_key', null);
      await host.writeSecret('fiscal_csc', null);
      return;
    }
    final credentials = data['credentials'];
    if (credentials is Map) {
      await host.writeSecret('fiscal_key', jsonEncode({
        'pkcs8': credentials['privateKeyPkcs8Base64'],
        'certificate': credentials['certificateBase64'],
        'validUntil': credentials['validUntil'],
      }));
      await host.writeSecret('fiscal_csc', jsonEncode({'id': credentials['cscId'], 'csc': credentials['csc']}));
    }
    var ranges = (data['ranges'] as List? ?? const []).cast<Map>();
    if (_activeRange(ranges) == null) {
      final allocated = await transport.allocateRange('${data['environment']}');
      ranges = (allocated['items'] as List? ?? const []).cast<Map>();
    }
    final stored = Map<String, dynamic>.from(data)..remove('credentials');
    stored['ranges'] = ranges;
    store.setMeta('fiscal_config', jsonEncode(stored));
  }

  Map? _activeRange(List<Map> ranges) {
    for (final r in ranges) {
      if ('${r['FnrStatus']}' != 'active') continue;
      final to = int.parse('${r['FnrToNumber']}');
      final next = int.tryParse(store.meta('fiscal_next:${r['FnrUUID']}') ?? '') ?? int.parse('${r['FnrFromNumber']}');
      if (next <= to) return r;
    }
    return null;
  }

  /// Signs the NFC-e of a sale stored on the device and queues it after the sale operation.
  Future<Map<String, dynamic>> emitContingency({
    required Map<String, dynamic> sale,
    required List<CartLine> cart,
    required List<PaymentEntry> payments,
    required String change,
    required String operatorUuid,
    required String saleOperationUuid,
    String? grantUuid,
    String reason = 'SEM CONEXAO COM A SEFAZ',
  }) async {
    final cfg = config;
    if (cfg == null || cfg['enabled'] != true) throw StateError('Offline NFC-e is not enabled for this device');
    final keyJson = await host.readSecret('fiscal_key');
    final cscJson = await host.readSecret('fiscal_csc');
    if (keyJson == null || cscJson == null) throw StateError('Fiscal credentials are not on this device');
    final keyData = (jsonDecode(keyJson) as Map).cast<String, dynamic>();
    final cscData = (jsonDecode(cscJson) as Map).cast<String, dynamic>();
    final range = _activeRange((cfg['ranges'] as List? ?? const []).cast<Map>());
    if (range == null) throw StateError('No offline fiscal number range left; connect to get a new one');
    final issuer = (cfg['issuer'] as Map).cast<String, dynamic>();
    final state = '${issuer['state']}';
    final production = '${cfg['environment']}' == 'production';
    final rules = [for (final r in (cfg['rules'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];
    final items = <NfceItem>[];
    for (final line in cart) {
      final fiscal = line.item.fiscal ?? const {};
      final rule = selectRule(
        rules,
        RuleContext(
          model: '65',
          operation: 'sale',
          originState: state,
          destinationState: state,
          taxRegime: '${issuer['taxRegime']}',
          nature: line.item.nature ?? 'goods',
          ncm: fiscal['ncm']?.toString(),
          recipientType: 'consumer',
        ),
      );
      if (rule == null) throw StateError('No fiscal rule applies to ${line.item.name}');
      final net = cents(line.total.toString());
      items.add(NfceItem(
        code: line.item.code,
        barcode: line.item.barcode,
        description: line.item.name,
        ncm: fiscal['ncm']?.toString(),
        cest: fiscal['cest']?.toString(),
        origin: fiscal['origin']?.toString(),
        unit: fiscal['unit']?.toString(),
        quantity: line.quantity.toString(),
        unitPrice: line.item.price.toString(),
        discount: line.discount.toString(),
        taxes: TaxLine(rule, net),
      ));
    }
    final series = int.parse('${range['FseSeries']}');
    final number = store.nextFiscalNumber('${range['FnrUUID']}', int.parse('${range['FnrFromNumber']}'), int.parse('${range['FnrToNumber']}'));
    final now = DateTime.now().toUtc();
    final saleUuid = '${sale['saleUUID']}';
    final key = buildAccessKey(
      state: state,
      issuedAt: now,
      cnpj: '${issuer['document']}',
      model: '65',
      series: series,
      number: number,
      emissionType: 9,
      code: numericCode(saleUuid, number),
    );
    final built = buildInfNFe(NfceInput(
      accessKey: key,
      series: series,
      number: number,
      issuedAt: now,
      production: production,
      issuer: issuer,
      items: items,
      payments: [for (final p in payments) (method: p.method.code, amount: p.amount.toString())],
      change: change,
      contingencyAt: now,
      contingencyReason: reason,
    ));
    final signature = signCanonicalElement(
      built.canonicalInfNFe,
      built.id,
      rsaKeyFromPkcs8(Uint8List.fromList(base64Decode('${keyData['pkcs8']}'))),
      '${keyData['certificate']}',
    );
    final qr = nfceQrCodeOffline(
      baseUrl: '${cfg['qrCodeUrl']}',
      accessKey: key,
      production: production,
      issuedAt: now,
      state: state,
      total: built.total,
      digestValueBase64: signature.digestValue,
      cscId: '${cscData['id']}',
      csc: '${cscData['csc']}',
    );
    final xml = assembleNfe(built.infNFe, signature.xml, nfceSupplement(qr, '${cfg['consultationUrl']}'));
    final document = {
      'saleUUID': saleUuid,
      'model': '65',
      'environment': cfg['environment'],
      'series': series,
      'number': number,
      'accessKey': key,
      'xml': xml,
      'xmlSha256': sha256.convert(utf8.encode(xml)).toString(),
      'qrCode': qr,
      'contingencyAt': now.toIso8601String(),
      'contingencyReason': reason,
      'rulePackage': cfg['rulePackage'],
    };
    final operation = {
      'operationUUID': uuidV4(),
      'kind': 'pos.fiscal.offline',
      'operatorUUID': operatorUuid,
      'correlationId': saleUuid,
      'contractVersion': 1,
      'occurredAt': now.toIso8601String(),
      'grantUUID': grantUuid,
      'dependsOn': [saleOperationUuid],
      'payload': document,
    };
    store.recordFiscalDocument(saleUuid, document, SyncEngine.entry(operation));
    assert(payloadHash(operation).length == 64);
    return document;
  }
}
