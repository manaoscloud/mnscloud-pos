import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/core/canonical_json.dart';
import 'package:mnscloud_pos/src/core/money.dart';

void main() {
  test('decimals are exact and round half up at their scale', () {
    expect((money('0.1') + money('0.2')).toString(), '0.3000');
    expect(money('1,99').toString(), '1.9900');
    expect((money('10.00') * quantity('3')).toString(), '30.0000');
    expect((money('9.99') * quantity('0.333')).toString(), '3.3267');
    expect(money('2.00005').toString(), '2.0001');
    expect(money('-2.00005').toString(), '-2.0001');
    expect(money('100').percent(money('10')).toString(), '10.0000');
    expect(money('1234567.5').format(), '1.234.567,50');
    expect(money('-0.5').format(), '-0,50');
    expect(money('3') > money('2.9999'), isTrue);
    expect(() => money('1.2.3'), throwsFormatException);
  });

  test('canonical JSON gives the same hash for the same sale', () {
    final a = {'b': 1, 'a': [{'y': '2', 'x': '1'}]};
    final b = {'a': [{'x': '1', 'y': '2'}], 'b': 1};
    expect(canonicalJson(a), canonicalJson(b));
    expect(payloadHash(a), payloadHash(b));
    expect(payloadHash(a), hasLength(64));
  });
}
