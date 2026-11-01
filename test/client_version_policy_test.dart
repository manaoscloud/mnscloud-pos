import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_pos/src/api/api_client.dart';
import 'package:mnscloud_pos/src/api/pos_api.dart';
import 'package:mnscloud_pos/src/version/app_build_info.dart';
import 'package:mnscloud_pos/src/version/app_update_controller.dart';
import 'package:mnscloud_pos/src/version/app_update_overlay.dart';
import 'package:mnscloud_pos/src/version/client_identity.dart';
import 'package:mnscloud_pos/src/version/runtime_version.dart';

ClientVersionPolicy policy(Map<String, String?> minimum) =>
    ClientVersionPolicy.fromJson({'app': 'pos', 'product': 'mnscloud-pos', 'latest': '1.0.29', 'minimum': minimum})!;

AppUpdateController installed(Future<ClientVersionPolicy?> Function() reader, {String platform = 'android'}) =>
    AppUpdateController(policyReader: reader, runningVersion: '1.0.18', platformName: platform, web: false);

void main() {
  group('installed apps', () {
    test('critical only below the minimum of their own platform', () async {
      final android = installed(() async => policy({'android': '1.0.20', 'windows': null}));
      await android.check(force: true);
      expect(android.critical, isTrue);
      expect(android.noticeVisible, isTrue);

      final windows = installed(() async => policy({'android': '1.0.20', 'windows': null}), platform: 'windows');
      await windows.check(force: true);
      expect(windows.critical, isFalse);
      expect(windows.noticeVisible, isFalse);

      final ios = installed(() async => policy({'ios': '1.0.18'}), platform: 'ios');
      await ios.check(force: true);
      expect(ios.noticeVisible, isFalse);
      android.dispose();
      windows.dispose();
      ios.dispose();
    });

    test('never shows the plain "new version" notice', () async {
      final update = installed(() async => policy({}));
      await update.check(force: true);
      update.observe(const RuntimeReleaseInfo(version: '1.0.29'), DateTime(2026));
      expect(update.updateAvailable, isFalse);
      expect(update.noticeVisible, isFalse);
      update.dispose();
    });

    test('fails open when the policy cannot be read', () async {
      final update = installed(() async => throw ApiException(ApiFailureKind.unreachable, 'offline'));
      await update.check(force: true);
      expect(update.noticeVisible, isFalse);
      update.dispose();
    });

    test('a 426 CLIENT_VERSION_UNSUPPORTED answer makes the notice critical', () async {
      final update = installed(() async => null);
      addTearDown(() => ApiClient.onClientVersionUnsupported = null);
      ApiClient.onClientVersionUnsupported = update.markUnsupported;
      final client = ApiClient(
        baseUrl: 'http://pos.test/api/v1',
        client: MockClient((_) async => http.Response(
            jsonEncode({'status': 'error', 'code': 'CLIENT_VERSION_UNSUPPORTED', 'error': 'Update the app.'}), 426)),
      );
      await expectLater(client.get('pos/terminals'), throwsA(isA<ApiException>()));
      expect(update.critical, isTrue);
      expect(update.noticeVisible, isTrue);
      update.dispose();
    });

    test('skips the policy read while no API base is known', () async {
      var calls = 0;
      final api = PosApi(ApiClient(baseUrl: '', client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      })));
      expect(await api.clientVersionPolicy(), isNull);
      expect(calls, 0);
    });

    testWidgets('mandatory notice without buttons, in the operator language', (tester) async {
      final update = installed(() async => policy({'android': '1.0.20'}));
      await update.check(force: true);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => AppUpdateOverlay(controller: update, busy: () => false, child: child!),
        home: const Scaffold(body: Text('register')),
      ));
      expect(find.textContaining('This app version is no longer supported'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      expect(find.text('Later'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('register'), findsOneWidget);
      // Stops the 6-hour poll and the lifecycle listener started by the overlay.
      await tester.pumpWidget(const SizedBox.shrink());
      update.dispose();
    });
  });

  test('the web path ignores the client policy and API refusals', () async {
    var reads = 0;
    final update = AppUpdateController(
      reader: () async => null,
      policyReader: () async {
        reads++;
        return policy({'android': '9.9.9'});
      },
      runningVersion: '1.0.18',
      platformName: 'web',
      web: true,
    );
    await update.check(force: true);
    update.markUnsupported();
    expect(reads, 0);
    expect(update.critical, isFalse);
    expect(update.noticeVisible, isFalse);
    update.dispose();
  });

  test('every API call carries the client identity headers', () async {
    final seen = <http.BaseRequest>[];
    final client = ApiClient(
      baseUrl: 'http://pos.test/api/v1',
      client: MockClient((request) async {
        seen.add(request);
        return http.Response(jsonEncode({'data': {}}), 200);
      }),
    );
    await client.get('pos/terminals');
    await client.post('pos/sales', const {});
    await client.signed('POST', 'pos/sync/push', body: const {}, headers: (_, _) => const {'X-Device': 'd'});
    expect(seen, hasLength(3));
    for (final request in seen) {
      expect(request.headers['X-Mns-Client'], 'mnscloud-pos/${appBuildInfo.version}');
      expect(request.headers['X-Mns-Client-Platform'], clientPlatform());
      expect(request.headers.containsKey('X-Client-Name'), isFalse);
    }
    expect(clientPlatform(), 'android'); // flutter_test's default target platform.
  });
}
