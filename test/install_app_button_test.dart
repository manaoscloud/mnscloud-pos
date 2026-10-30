import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/ui/install_app_button.dart';

void main() {
  testWidgets('outside an installable browser the install button is hidden', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: InstallAppButton(labeled: true))));
    expect(find.byKey(const Key('installApp')), findsNothing);
  });
}
