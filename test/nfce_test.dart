import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/fiscal/nfce.dart';
import 'package:mnscloud_pos/src/fiscal/xml_signature.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// Test-only RSA key (generated at run time, never stored) and its PKCS#8 / SPKI encodings.
({RSAPrivateKey private, RSAPublicKey public, Uint8List pkcs8, String spkiPem}) testKey() {
  final random = FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), random));
  final pair = generator.generateKeyPair();
  final private = pair.privateKey;
  final public = pair.publicKey;
  final rsa = ASN1Sequence(elements: [
    ASN1Integer(BigInt.zero),
    ASN1Integer(private.modulus),
    ASN1Integer(public.exponent),
    ASN1Integer(private.privateExponent),
    ASN1Integer(private.p),
    ASN1Integer(private.q),
    ASN1Integer(private.privateExponent! % (private.p! - BigInt.one)),
    ASN1Integer(private.privateExponent! % (private.q! - BigInt.one)),
    ASN1Integer(private.q!.modInverse(private.p!)),
  ]);
  final algorithm = ASN1Sequence(elements: [ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'), ASN1Null()]);
  final pkcs8 = ASN1Sequence(elements: [ASN1Integer(BigInt.zero), algorithm, ASN1OctetString(octets: rsa.encode())]).encode();
  final spki = ASN1Sequence(elements: [
    algorithm,
    ASN1BitString(stringValues: ASN1Sequence(elements: [ASN1Integer(public.modulus), ASN1Integer(public.exponent)]).encode()),
  ]).encode();
  final b64 = base64Encode(spki);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return (private: private, public: public, pkcs8: pkcs8, spkiPem: '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n');
}

Map<String, dynamic> rule(Map<String, dynamic> over) => {
      'FruUUID': 'R' * 32,
      'FruName': 'VENDA',
      'FruPriority': 100,
      'FruModel': null,
      'FruOperation': 'sale',
      'FruOriginState': null,
      'FruDestinationState': null,
      'FruTaxRegime': null,
      'FruNature': null,
      'FruNcmPrefix': null,
      'FruRecipientType': null,
      'FruCfop': '5102',
      'FruIcmsCst': '102',
      'FruIcmsRate': '0.0000',
      'FruIcmsBaseReduction': '0.0000',
      'FruFcpRate': '0.0000',
      'FruPisCst': '49',
      'FruPisRate': '0.0000',
      'FruCofinsCst': '49',
      'FruCofinsRate': '0.0000',
      'FruLegalText': null,
      'FruStatus': 1,
      ...over,
    };

final issuer = <String, dynamic>{
  'document': '11222333000181',
  'legalName': 'LOJA TESTE & CIA <LTDA>',
  'name': 'LOJA TESTE',
  'stateRegistration': '041234567',
  'taxRegime': 'simples_nacional',
  'street': 'RUA A',
  'number': '10',
  'district': 'CENTRO',
  'city': 'MANAUS',
  'state': 'AM',
  'zip': '69000-000',
  'municipalityCode': '1302603',
};

NfceInput sample({bool contingency = false}) => NfceInput(
      accessKey: '13261011222333000181650020000005001123456780',
      series: 2,
      number: 500,
      issuedAt: DateTime.utc(2026, 10, 18, 15),
      production: false,
      issuer: issuer,
      items: [
        NfceItem(
          code: 'SPR1',
          barcode: '7891000100103',
          description: 'AGUA 500ML',
          ncm: '22021000',
          unit: 'UN',
          quantity: '2',
          unitPrice: '3.00',
          discount: '0',
          taxes: TaxLine(rule({}), cents('6.00')),
        ),
      ],
      payments: [(method: 'cash', amount: '10.00')],
      change: '4.00',
      contingencyAt: contingency ? DateTime.utc(2026, 10, 18, 14, 50) : null,
      contingencyReason: contingency ? 'SEM CONEXAO COM A SEFAZ' : null,
      applicationVersion: 'mnscloud-test',
    );

void main() {
  test('access key, time zone and numeric code match the API engine', () {
    final key = buildAccessKey(
        state: 'AM', issuedAt: DateTime.utc(2026, 10, 18, 15), cnpj: '11.222.333/0001-81', model: '65', series: 2, number: 500,
        emissionType: 9, code: '12345678');
    expect(key.length, 44);
    expect(key.substring(0, 6), '132610');
    expect(key[34], '9', reason: 'tpEmis in the key');
    expect(accessKeyCheckDigit(key.substring(0, 43)), key[43]);
    expect(fiscalDateTime(DateTime.utc(2026, 10, 18, 15), 'AM'), '2026-10-18T11:00:00-04:00');
    expect(numericCode('2B0C9C3A4F6C4D649F151E27AD2F6A1B', 500), numericCode('2b0c9c3a4f6c4d649f151e27ad2f6a1b', 500));
    expect(cents('7.505'), 751);
  });

  test('rule selection and taxes follow the server rules', () {
    final general = rule({'FruUUID': 'A' * 32});
    final ncm = rule({'FruUUID': 'C' * 32, 'FruTaxRegime': 'normal', 'FruNcmPrefix': '2202', 'FruIcmsCst': '00', 'FruIcmsRate': '25', 'FruFcpRate': '2'});
    final ctx = RuleContext(
        model: '65', operation: 'sale', originState: 'AM', destinationState: 'AM', taxRegime: 'normal', nature: 'goods', ncm: '22021000',
        recipientType: 'consumer');
    expect(selectRule([general, ncm], ctx)!['FruUUID'], ncm['FruUUID']);
    final taxes = TaxLine(ncm, cents('10.00'));
    expect([taxes.icmsBase, taxes.icmsValue, taxes.fcpValue], [1000, 250, 20]);
  });

  test('contingency NFC-e: tpEmis 9 with dhCont/xJust, signature and offline QR Code', () {
    final built = buildInfNFe(sample(contingency: true));
    expect(built.infNFe.contains('<tpEmis>9</tpEmis>'), isTrue);
    expect(built.infNFe.contains('<dhCont>2026-10-18T10:50:00-04:00</dhCont><xJust>SEM CONEXAO COM A SEFAZ</xJust></ide>'), isTrue);
    expect(built.infNFe.contains('<xNome>LOJA TESTE &amp; CIA &lt;LTDA&gt;</xNome>'), isTrue);
    expect(built.total, 600);
    final key = testKey();
    final signature = signCanonicalElement(built.canonicalInfNFe, built.id, rsaKeyFromPkcs8(key.pkcs8), 'CERT');
    // The signature verifies with the public key over the canonical SignedInfo.
    final signedInfo = RegExp(r'<SignedInfo>(.*)</SignedInfo>').firstMatch(signature.xml)!.group(1)!;
    final value = RegExp(r'<SignatureValue>([^<]+)</SignatureValue>').firstMatch(signature.xml)!.group(1)!;
    final verifier = RSASigner(SHA1Digest(), '06052b0e03021a')..init(false, PublicKeyParameter<RSAPublicKey>(key.public));
    expect(
        verifier.verifySignature(utf8Bytes('<SignedInfo xmlns="http://www.w3.org/2000/09/xmldsig#">$signedInfo</SignedInfo>'),
            RSASignature(base64Decode(value))),
        isTrue);
    final qr = nfceQrCodeOffline(
        baseUrl: 'http://homnfce.sefaz.am.gov.br/nfceweb/consultarNFCe.jsp', accessKey: built.id.substring(3), production: false,
        issuedAt: DateTime.utc(2026, 10, 18, 15), state: 'AM', total: built.total, digestValueBase64: signature.digestValue,
        cscId: '000001', csc: 'CSC');
    final parts = qr.split('?p=')[1].split('|');
    expect(parts.length, 8);
    expect([parts[1], parts[2], parts[3], parts[4], parts[6]], ['2', '2', '18', '6.00', '1']);
    expect(parts[5].length, 40, reason: 'SHA-1 digest in hex');
    // Optional interop output, verified against the API (xml-crypto) by the release checklist.
    final out = Platform.environment['NFCE_INTEROP_OUT'];
    if (out != null) {
      final xml = assembleNfe(built.infNFe, signature.xml, nfceSupplement(qr, 'www.sefaz.am.gov.br/nfce/consulta'));
      File(out).writeAsStringSync(jsonEncode({'xml': xml, 'publicKeyPem': key.spkiPem, 'canonical': buildInfNFe(sample()).infNFe}));
    }
  });

  test('payments must cover the total and unsupported tax groups are refused', () {
    final input = sample();
    expect(
        () => buildInfNFe(NfceInput(
            accessKey: input.accessKey, series: 2, number: 500, issuedAt: input.issuedAt, production: false, issuer: issuer,
            items: input.items, payments: [(method: 'cash', amount: '1.00')], change: '0')),
        throwsArgumentError);
    expect(() => buildInfNFe(NfceInput(
        accessKey: input.accessKey, series: 2, number: 500, issuedAt: input.issuedAt, production: false, issuer: issuer,
        items: [NfceItem(description: 'X', quantity: '1', unitPrice: '1.00', discount: '0', taxes: TaxLine(rule({'FruIcmsCst': '201'}), 100))],
        payments: [(method: 'cash', amount: '1.00')], change: '0')), throwsArgumentError);
  });
}
