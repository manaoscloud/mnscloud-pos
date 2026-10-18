import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// XMLDSig enveloped signature (C14N 1.0, RSA-SHA1, SHA-1 digest) of an element already written in
/// canonical form — identical to the API (helpers/fiscal/xmlSignature.ts).

const _dsig = 'http://www.w3.org/2000/09/xmldsig#';
const _c14n = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315';

/// RSA private key from a PKCS#8 (PrivateKeyInfo) DER, as released by the API for offline NFC-e.
RSAPrivateKey rsaKeyFromPkcs8(Uint8List der) {
  final info = ASN1Parser(der).nextObject() as ASN1Sequence;
  final octets = info.elements![2] as ASN1OctetString;
  final rsa = ASN1Parser(octets.valueBytes!).nextObject() as ASN1Sequence;
  BigInt at(int i) => (rsa.elements![i] as ASN1Integer).integer!;
  return RSAPrivateKey(at(1), at(3), at(4), at(5));
}

String _signedInfoContent(String referenceId, String digestValue) =>
    '<CanonicalizationMethod Algorithm="$_c14n"></CanonicalizationMethod>'
    '<SignatureMethod Algorithm="${_dsig}rsa-sha1"></SignatureMethod>'
    '<Reference URI="#$referenceId"><Transforms>'
    '<Transform Algorithm="${_dsig}enveloped-signature"></Transform>'
    '<Transform Algorithm="$_c14n"></Transform></Transforms>'
    '<DigestMethod Algorithm="${_dsig}sha1"></DigestMethod>'
    '<DigestValue>$digestValue</DigestValue></Reference>';

class XmlSignature {
  XmlSignature(this.xml, this.digestValue);
  final String xml;
  final String digestValue;
}

XmlSignature signCanonicalElement(String canonicalElement, String referenceId, RSAPrivateKey key, String certificateBase64) {
  final digest = base64Encode(sha1.convert(utf8.encode(canonicalElement)).bytes);
  final content = _signedInfoContent(referenceId, digest);
  final canonicalSignedInfo = '<SignedInfo xmlns="$_dsig">$content</SignedInfo>';
  final signer = RSASigner(SHA1Digest(), '06052b0e03021a')..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  final signature = signer.generateSignature(Uint8List.fromList(utf8.encode(canonicalSignedInfo)));
  return XmlSignature(
    '<Signature xmlns="$_dsig"><SignedInfo>$content</SignedInfo>'
    '<SignatureValue>${base64Encode(signature.bytes)}</SignatureValue>'
    '<KeyInfo><X509Data><X509Certificate>$certificateBase64</X509Certificate></X509Data></KeyInfo></Signature>',
    digest,
  );
}
