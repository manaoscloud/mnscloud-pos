import 'dart:convert';

import 'store.dart';

/// POS session of an installed app, kept in the encrypted store (never on the web, whose refresh
/// token is an HttpOnly cookie): the rotating refresh token, the signed-in operator, the tenant,
/// the customer shop and the API address. Reopening the app (online or not) resumes from it after the operator PIN.
///
/// The app and the background sync are two connections to the same store. Device requests carry a
/// monotonic counter and a refresh token is valid once, so they never run at the same time: both
/// take the [acquire] lease (an atomic compare-and-set in the store) for a whole sync, and the
/// refresh token is read from the store, never from a stale copy, right before it is used.
class SessionVault {
  SessionVault(this.store, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final OfflineStore store;
  final DateTime Function() _clock;

  static const _refresh = 'session.refresh';
  static const _user = 'session.user';
  static const _tenant = 'session.tenant';
  static const _account = 'session.account';
  static const _api = 'session.api';
  static const _lease = 'sync.lease';
  static const _foreground = 'app.foreground_at';

  String? get refreshToken => store.meta(_refresh);

  /// The rotated token replaces the previous one; null ends the stored session.
  void saveRefreshToken(String? token) => store.setMeta(_refresh, token);

  bool get hasSession => refreshToken != null && user != null;

  Map<String, dynamic>? get user => _json(_user);
  Map<String, dynamic>? get tenant => _json(_tenant);

  /// Customer shop (commerce account) the operator sells for; null for the internal operation.
  String? get account => store.meta(_account);
  String? get apiBase => store.meta(_api);

  void saveUser({required String uuid, required String name, required String email}) =>
      store.setMeta(_user, jsonEncode({'uuid': uuid, 'name': name, 'email': email}));

  void saveTenant({required String uuid, required String name, String? code}) =>
      store.setMeta(_tenant, jsonEncode({'uuid': uuid, 'name': name, 'code': code}));

  void saveAccount(String? uuid) => store.setMeta(_account, uuid);

  void saveApiBase(String base) => store.setMeta(_api, base);

  /// Sign-out, a refused refresh or too many wrong PINs: the stored session goes; pending sales,
  /// the device key and its grant stay for the next operator.
  void clear() {
    for (final key in [_refresh, _user, _tenant, _account]) {
      store.setMeta(key, null);
    }
  }

  // ---------- One sync at a time across the app and the background task

  /// Takes the lease for [ttl] unless another holder has an unexpired one. A crashed holder
  /// blocks nobody for longer than its [ttl].
  bool acquire(String owner, {Duration ttl = const Duration(minutes: 2)}) {
    final current = store.meta(_lease);
    final now = _clock().millisecondsSinceEpoch;
    if (current != null) {
      final parts = current.split('|');
      final expires = parts.length == 2 ? int.tryParse(parts[1]) ?? 0 : 0;
      if (parts.first != owner && expires > now) return false;
    }
    return store.compareAndSetMeta(_lease, current, '$owner|${now + ttl.inMilliseconds}');
  }

  void release(String owner) {
    final current = store.meta(_lease);
    if (current != null && current.split('|').first == owner) store.compareAndSetMeta(_lease, current, null);
  }

  /// Runs [work] under the lease; null without running it when another holder has it.
  Future<T?> withLease<T>(String owner, Future<T> Function() work, {Duration ttl = const Duration(minutes: 2)}) async {
    if (!acquire(owner, ttl: ttl)) return null;
    try {
      return await work();
    } finally {
      release(owner);
    }
  }

  /// The app is in the foreground (written by its sync timer): the background task stays out.
  void markForeground() => store.setMeta(_foreground, '${_clock().millisecondsSinceEpoch}');

  void markBackground() => store.setMeta(_foreground, null);

  bool foregroundWithin(Duration window) {
    final at = int.tryParse(store.meta(_foreground) ?? '');
    return at != null && _clock().millisecondsSinceEpoch - at < window.inMilliseconds;
  }

  Map<String, dynamic>? _json(String key) {
    final raw = store.meta(key);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map ? value.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}
