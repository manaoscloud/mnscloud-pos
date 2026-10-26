import 'dart:convert';
import 'dart:math';

import '../core/canonical_json.dart';
import 'store.dart';

/// Device side of the sync contract (`/pos/sync/*`, contract version 1).
abstract class SyncTransport {
  Future<Map<String, dynamic>> bootstrap(String? cursor);
  Future<Map<String, dynamic>> changes(String cursor);

  /// `{operations: [{operation, hash}]}` → `{results: [...]}`.
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> entries);
}

/// The catalog page did not match its checksum: it is not applied.
class SyncChecksumException implements Exception {
  @override
  String toString() => 'Catalog page checksum mismatch.';
}

class SyncReport {
  SyncReport({this.applied = 0, this.retried = 0, this.rejected = 0, this.conflicts = 0, this.reachable = true});

  int applied;
  int retried;
  int rejected;
  int conflicts;
  bool reachable;
}

/// Local-first synchronization: the device sells from its store and pushes the outbox in order.
/// Delivery is at least once and effects exactly once (the API dedupes by operation UUID), so any
/// lost answer is simply resent. Requests are serialized (the request counter is monotonic).
class SyncEngine {
  SyncEngine(this.store, this.transport, {Random? random, DateTime Function()? clock})
      : _random = random ?? Random(),
        _clock = clock ?? DateTime.now;

  final OfflineStore store;
  final SyncTransport transport;
  final Random _random;
  final DateTime Function() _clock;
  Future<void>? _running;

  static const maxBackoff = Duration(minutes: 5);
  static const baseBackoff = Duration(seconds: 2);

  /// Exponential backoff with ±20 % jitter, capped at 5 minutes.
  Duration backoff(int attempts) {
    final exponent = min(attempts, 12);
    final raw = baseBackoff * pow(2, exponent).toInt();
    final capped = raw > maxBackoff ? maxBackoff : raw;
    final jitter = 0.8 + _random.nextDouble() * 0.4;
    return Duration(milliseconds: (capped.inMilliseconds * jitter).round());
  }

  /// Builds an outbox entry from an operation map: canonical JSON and its SHA-256.
  static OutboxEntry entry(Map<String, dynamic> operation) => OutboxEntry(
        operationUuid: operation['operationUUID'] as String,
        kind: operation['kind'] as String,
        operation: canonicalJson(operation),
        hash: payloadHash(operation),
        operatorUuid: operation['operatorUUID'] as String,
      );

  /// One full cycle (push first so sales leave the device as soon as possible, then catalog).
  /// Concurrent callers share the running cycle.
  Future<SyncReport> sync() async {
    final report = SyncReport();
    final previous = _running;
    if (previous != null) {
      await previous;
      return report;
    }
    final run = _cycle(report);
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
    return report;
  }

  Future<void> _cycle(SyncReport report) async {
    try {
      await pushOutbox(report);
      await pullCatalog();
    } on SyncUnreachable {
      report.reachable = false;
    }
  }

  Future<void> pushOutbox(SyncReport report) async {
    while (true) {
      final due = store.dueOperations(_clock().millisecondsSinceEpoch, limit: 50);
      if (due.isEmpty) return;
      final results = _resultsByKey(await _pushBatch(due, report));
      var progressed = false;
      for (final e in due) {
        if (_applyResult(e, results[_key(e.operationUuid)], report)) progressed = true;
      }
      if (!progressed) return;
    }
  }

  /// Pushes one batch; an unreachable API puts every operation of the batch back in retry.
  Future<Map<String, dynamic>> _pushBatch(List<OutboxEntry> due, SyncReport report) async {
    try {
      return await transport.push([
        for (final e in due) {'operation': jsonDecode(e.operation), 'hash': e.hash},
      ]);
    } catch (error) {
      for (final e in due) {
        store.markOperation(e.operationUuid, 'retry', error: error.toString(), retryAtMs: _retryAt(e.attempts));
      }
      report.retried += due.length;
      throw SyncUnreachable(error);
    }
  }

  static Map<String, Map<String, dynamic>> _resultsByKey(Map<String, dynamic> response) => {
        for (final r in (response['results'] as List? ?? const []))
          if (r is Map && r['operationUUID'] != null) _key(r['operationUUID'].toString()): r.cast<String, dynamic>(),
      };

  /// Records the server answer for one operation; true when the operation left the queue.
  bool _applyResult(OutboxEntry e, Map<String, dynamic>? r, SyncReport report) {
    final status = r?['status']?.toString() ?? 'RETRY';
    final result = r?['result'] == null ? null : jsonEncode(r!['result']);
    final error = r?['error']?.toString();
    switch (status) {
      case 'ACCEPTED':
        store.markOperation(e.operationUuid, 'done', result: result);
        report.applied++;
      case 'CONFLICT':
        store.markOperation(e.operationUuid, 'conflict', result: result);
        report.conflicts++;
      case 'DUPLICATE':
        store.markOperation(e.operationUuid, _duplicateState(r), result: result, error: error);
      case 'REJECTED':
        store.markOperation(e.operationUuid, 'rejected', result: result, error: error);
        report.rejected++;
      default:
        store.markOperation(e.operationUuid, 'retry', error: error, retryAtMs: _retryAt(e.attempts));
        report.retried++;
        return false;
    }
    return true;
  }

  /// A duplicate keeps the state the server recorded for the original operation.
  static String _duplicateState(Map<String, dynamic>? r) {
    final original = (r?['result'] as Map?)?['status']?.toString().toLowerCase();
    if (original == 'rejected' || original == 'conflict') return original!;
    return 'done';
  }

  int _retryAt(int attempts) => _clock().add(backoff(attempts)).millisecondsSinceEpoch;

  static String _key(String uuid) => uuid.replaceAll('-', '').toLowerCase();

  /// Catalog: bootstrap into staging (an interrupted bootstrap keeps the previous catalog and
  /// resumes from its cursor), then follow the change feed.
  Future<void> pullCatalog() async {
    var cursor = store.meta('catalog_cursor');
    if (cursor == null) {
      var bootstrapCursor = store.meta('bootstrap_cursor');
      if (bootstrapCursor == null) store.beginBootstrap();
      while (true) {
        final page = await _call(() => transport.bootstrap(bootstrapCursor));
        final items = _items(page);
        store.stageCatalog(items);
        final next = page['cursor'] as String;
        if (page['done'] == true) {
          store.finishBootstrap(next);
          store.setMeta('bootstrap_cursor', null);
          _rememberBootstrapContext(page);
          cursor = next;
          break;
        }
        bootstrapCursor = next;
        store.setMeta('bootstrap_cursor', next);
      }
    }
    while (cursor != null) {
      final page = await _call(() => transport.changes(cursor!));
      final items = _items(page);
      final next = page['cursor'] as String;
      store.applyCatalogChanges(items, next);
      if (page['done'] == true || next == cursor) break;
      cursor = next;
    }
  }

  void _rememberBootstrapContext(Map<String, dynamic> page) {
    for (final key in ['terminal', 'grant', 'device']) {
      if (page.containsKey(key)) store.setMeta(key, page[key] == null ? null : jsonEncode(page[key]));
    }
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> page) {
    final items = [for (final i in (page['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
    if (page['checksum'] != payloadHash(items)) throw SyncChecksumException();
    return items;
  }

  Future<Map<String, dynamic>> _call(Future<Map<String, dynamic>> Function() request) async {
    try {
      return await request();
    } on SyncChecksumException {
      rethrow;
    } catch (error) {
      throw SyncUnreachable(error);
    }
  }
}

/// The API could not be reached (or answered with a transient failure): the device keeps selling
/// from its store and retries later.
class SyncUnreachable implements Exception {
  SyncUnreachable(this.cause);

  final Object cause;

  @override
  String toString() => 'Sync unreachable: $cause';
}
