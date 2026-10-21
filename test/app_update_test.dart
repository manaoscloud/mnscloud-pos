import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/version/app_update_controller.dart';
import 'package:mnscloud_pos/src/version/app_update_overlay.dart';
import 'package:mnscloud_pos/src/version/runtime_version.dart';

void main() {
  final t0 = DateTime(2026, 10, 21, 12);
  late DateTime now;

  AppUpdateController controller() =>
      AppUpdateController(reader: () async => null, runningVersion: '1.0.11', clock: () => now);

  void announce(AppUpdateController update, RuntimeReleaseInfo build) {
    update.observe(build, t0);
    update.observe(build, t0.add(AppUpdateController.confirmDelay));
  }

  // Mounted like lib/main.dart: MaterialApp.builder, above the Navigator.
  Widget app(AppUpdateController update, {bool Function()? busy, Listenable? listenable}) => MaterialApp(
        builder: (context, child) => AppUpdateOverlay(
          controller: update,
          busy: busy ?? () => false,
          listenable: listenable,
          child: child!,
        ),
        home: const Scaffold(body: Text('register')),
      );

  setUp(() => now = t0);

  test('announces a new release only after two reads agree 45 s apart', () {
    final update = controller();
    update.observe(const RuntimeReleaseInfo(version: '1.0.12'), t0);
    expect(update.updateAvailable, isFalse);
    update.observe(const RuntimeReleaseInfo(version: '1.0.12'), t0.add(AppUpdateController.confirmDelay));
    expect(update.noticeVisible, isTrue);
    update.postpone();
    expect(update.noticeVisible, isFalse);
    now = t0.add(AppUpdateController.snoozeDuration + const Duration(minutes: 1));
    expect(update.noticeVisible, isTrue);
    update.dispose();
  });

  test('stays quiet on the running version', () {
    final update = controller();
    update.observe(const RuntimeReleaseInfo(version: 'v1.0.11'), t0);
    expect(update.updateAvailable, isFalse);
    update.dispose();
  });

  testWidgets('shows the notice over the register and hides it on "Later"', (tester) async {
    final update = controller();
    addTearDown(update.dispose);
    await tester.pumpWidget(app(update));
    expect(find.text('Update now'), findsNothing);

    announce(update, const RuntimeReleaseInfo(version: '1.0.12'));
    await tester.pump();
    expect(find.textContaining('New version available'), findsOneWidget);
    expect(find.textContaining('between sales'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Later'));
    await tester.pump();
    expect(find.textContaining('New version available'), findsNothing);
    expect(find.text('register'), findsOneWidget);
  });

  testWidgets('waits for the sale in progress to end', (tester) async {
    final update = controller();
    addTearDown(update.dispose);
    final sale = ValueNotifier<bool>(true);
    addTearDown(sale.dispose);
    await tester.pumpWidget(app(update, busy: () => sale.value, listenable: sale));

    announce(update, const RuntimeReleaseInfo(version: '1.0.12', minimumVersion: '1.0.12'));
    await tester.pump();
    expect(find.text('Update now'), findsNothing);

    sale.value = false;
    await tester.pump();
    expect(find.textContaining('Important update'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
  });

  testWidgets('hovering the close button shows its tooltip instead of an error box', (tester) async {
    final update = controller();
    addTearDown(update.dispose);
    await tester.pumpWidget(app(update));
    announce(update, const RuntimeReleaseInfo(version: '1.0.12'));
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.close)));
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
    expect(find.byType(Tooltip), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);
  });

  testWidgets('speaks the operator language', (tester) async {
    final update = controller();
    addTearDown(update.dispose);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => AppUpdateOverlay(controller: update, busy: () => false, child: child!),
      home: const Scaffold(body: Text('register')),
    ));
    announce(update, const RuntimeReleaseInfo(version: '1.0.12'));
    await tester.pump();
    expect(find.textContaining('Nova versão disponível'), findsOneWidget);
    expect(find.text('Atualizar agora'), findsOneWidget);
  });
}
