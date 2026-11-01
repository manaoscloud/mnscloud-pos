import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

import '../api/api_client.dart';
import '../api/pos_api.dart';
import '../core/ids.dart';
import '../version/app_build_info.dart';
import 'device_host.dart';
import 'device_sync_api.dart';
import 'p256.dart';
import 'session_vault.dart';
import 'store.dart';
import 'sync_engine.dart';

const backgroundSyncTask = 'cloud.manaos.mnscloud.pos.sync';

/// Pending sales leave the device while the app is closed (Android WorkManager, iOS BGTask; both
/// decide the exact time, at least 15 minutes apart, only with network). Desktop apps have no OS
/// task here: they sync while open.
Future<void> scheduleBackgroundSync() async {
  if (!(Platform.isAndroid || Platform.isIOS)) return;
  try {
    await Workmanager().initialize(posBackgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundSyncTask,
      backgroundSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {
    // No scheduler on this device: the app still syncs while open.
  }
}

@pragma('vm:entry-point')
void posBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final host = await openDeviceHost();
      if (host == null) return true;
      try {
        await backgroundSyncOnce(host.store, await host.loadKey());
      } finally {
        host.store.close();
      }
    } catch (_) {
      // A failed run is retried at the next period; never a retry storm.
    }
    return true;
  });
}

/// Why a background run did nothing (tests and diagnostics).
enum BackgroundSkip { notProvisioned, noSession, nothingPending, appInForeground, busy }

/// One background run: renews the POS session from the stored refresh token and pushes the
/// pending operations (then follows the catalog, which also brings a revoked grant). It runs
/// under the same lease as the app, and not at all while the app is in the foreground. Returns
/// null when it synced, or why it did not.
Future<BackgroundSkip?> backgroundSyncOnce(OfflineStore store, P256Key? key,
    {http.Client? httpClient, String owner = 'background'}) async {
  final vault = SessionVault(store);
  final device = store.meta('device');
  if (key == null || device == null) return BackgroundSkip.notProvisioned;
  final tenant = vault.tenant;
  if (vault.refreshToken == null || tenant == null) return BackgroundSkip.noSession;
  final counts = store.outboxCounts();
  if ((counts['pending'] ?? 0) + (counts['retry'] ?? 0) == 0) return BackgroundSkip.nothingPending;
  if (vault.foregroundWithin(const Duration(minutes: 2))) return BackgroundSkip.appInForeground;
  final synced = await vault.withLease(owner, () async {
    final client = ApiClient(baseUrl: vault.apiBase, client: httpClient)..environmentUuid = tenant['uuid'] as String?;
    // Read inside the lease: the app may have rotated it a moment ago.
    client.refreshToken = vault.refreshToken;
    final api = PosApi(client);
    final grant = await api.refresh();
    vault.saveRefreshToken(grant.refreshToken ?? client.refreshToken);
    final deviceUuid = normalizeUuid(((jsonDecode(device) as Map)['SdvUUID'] ?? '').toString());
    final transport = DeviceSyncApi(client, store, key, deviceUuid, appVersion: appBuildInfo.version);
    await SyncEngine(store, transport).sync();
    return true;
  });
  return synced == true ? null : BackgroundSkip.busy;
}
